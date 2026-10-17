import SwiftSyntax
import SwiftSyntaxBuilder
import RP2xxxPIOCore

/// Label handles are not host-evaluated objects. For constant assembly, replace
/// lexical labels with private symbols, then bind only captured handles afterward.
/// The original closure remains authoritative whenever assembly must be dynamic.
final class PIOLabelLowering {
    struct Symbol {
        let key: UInt64
        let name: String
        let capture: String?
        var expression: ExprSyntax {
            ExprSyntax(stringLiteral: "RP2xxxPIOCore.PIOLabelHandle._symbol(\(key))")
        }
    }

    private final class Binding {
        let id: SyntaxIdentifier
        let initializer: ExprSyntax?
        let environment: [String: Binding]
        var symbol: Symbol?

        init(id: SyntaxIdentifier, initializer: ExprSyntax?, environment: [String: Binding], symbol: Symbol? = nil) {
            self.id = id; self.initializer = initializer; self.environment = environment; self.symbol = symbol
        }
    }

    private var bindings: [SyntaxIdentifier: Binding] = [:]
    private var wrappers: Set<SyntaxIdentifier> = []
    private var replacements: [SyntaxIdentifier: ExprSyntax] = [:]
    private var references: [(DeclReferenceExprSyntax, Binding?)] = []
    private var allowed: Set<SyntaxIdentifier> = []
    private var captured: [String: Symbol] = [:]
    private var symbols: [Symbol] = []
    private(set) var failureReason: String?

    var captures: [Symbol] { captured.values.sorted { $0.key < $1.key } }
    var hasLabels: Bool { !wrappers.isEmpty || !captured.isEmpty || bindings.values.contains { $0.symbol != nil } }

    // Recover diagnostic names from the already-evaluated source only after
    // the authoritative assembler reports an error. No names or formatting
    // routines need to be carried in the device's label representation.
    func undefinedLabel(in source: PIOProgramSource) -> Symbol? {
        let declared = Set(source.statements.compactMap { statement -> PIOLabelHandle? in
            if case .label(let handle) = statement { return handle }
            return nil
        })
        for case .instruction(let instruction) in source.statements {
            if case .jmp(_, .label(let handle)) = instruction.operation, !declared.contains(handle) {
                return symbols.first { $0.key == handle.symbolicID }
            }
        }
        return nil
    }

    func duplicateName(in source: PIOProgramSource) -> String? {
        var handles: Set<PIOLabelHandle> = []
        var names: Set<String> = []
        for statement in source.statements {
            switch statement {
            case .label(let handle):
                if !handles.insert(handle).inserted {
                    return symbols.first { $0.key == handle.symbolicID }?.name
                }
            case .symbol(let name, _, _):
                if !names.insert(name).inserted { return name }
            default: break
            }
        }
        return nil
    }

    func lower(_ closure: ClosureExprSyntax) -> ClosureExprSyntax {
        scanBlock(closure.statements, environment: [:])
        for (reference, binding) in references {
            let isLabel = binding?.symbol != nil || (binding == nil && captured[name(reference.baseName)] != nil)
            if isLabel && !allowed.contains(reference.id) {
                failureReason = "constant labels may only be used by Label, Jmp, or immutable local aliases"
            }
        }
        return Rewrite(bindings: bindings, wrappers: wrappers, replacements: replacements)
            .rewrite(closure).cast(ClosureExprSyntax.self)
    }

    private func scanBlock(_ statements: CodeBlockItemListSyntax, environment initial: [String: Binding]) {
        var environment = initial
        for item in statements {
            if let variable = item.item.as(VariableDeclSyntax.self) {
                let isWrapper = variable.attributes.contains { attribute in
                    attribute.as(AttributeSyntax.self)?.attributeName.trimmedDescription.split(separator: ".").last == "PIOLabel"
                }
                if isWrapper {
                    guard variable.attributes.count == 1, variable.modifiers.isEmpty,
                          variable.bindingSpecifier.tokenKind == .keyword(.var), variable.bindings.count == 1,
                          let binding = variable.bindings.first, binding.initializer == nil, binding.accessorBlock == nil,
                          let identifier = binding.pattern.as(IdentifierPatternSyntax.self)
                    else { failureReason = "use an uninitialized @PIOLabel var declaration"; continue }
                    let symbol = makeSymbol(name: name(identifier.identifier), capture: nil)
                    let entry = Binding(id: binding.id, initializer: nil, environment: environment, symbol: symbol)
                    bindings[binding.id] = entry; environment[name(identifier.identifier)] = entry
                    wrappers.insert(variable.id)
                } else {
                    for binding in variable.bindings {
                        if let value = binding.initializer?.value { scan(Syntax(value), environment: environment) }
                        guard let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                        let canAlias = variable.bindingSpecifier.tokenKind == .keyword(.let)
                            && variable.attributes.isEmpty && binding.accessorBlock == nil
                        let entry = Binding(id: binding.id, initializer: canAlias ? binding.initializer?.value : nil,
                                            environment: environment)
                        bindings[binding.id] = entry; environment[name(identifier.identifier)] = entry
                    }
                }
            } else { scan(Syntax(item), environment: environment) }
        }
    }

    private func scan(_ syntax: Syntax, environment: [String: Binding]) {
        if let block = syntax.as(CodeBlockSyntax.self) { scanBlock(block.statements, environment: environment); return }
        if syntax.is(ClosureExprSyntax.self) { failureReason = "nested closures cannot be constant-assembled"; return }
        if let reference = syntax.as(DeclReferenceExprSyntax.self) {
            references.append((reference, environment[name(reference.baseName)]))
        }
        if let call = syntax.as(FunctionCallExprSyntax.self), let function = functionName(call.calledExpression, environment: environment) {
            let operand: ExprSyntax?
            switch function {
            case "Label": operand = call.arguments.count == 1 ? call.arguments.first?.expression : nil
            case "Jmp": operand = call.arguments.first { $0.label?.text == "to" }?.expression
            default: operand = nil
            }
            if let operand, let symbol = resolve(operand, environment: environment) {
                replacements[operand.id] = symbol.expression
            }
        }
        for child in syntax.children(viewMode: .sourceAccurate) { scan(child, environment: environment) }
    }

    private func resolve(_ expression: ExprSyntax, environment: [String: Binding]) -> Symbol? {
        if let tuple = expression.as(TupleExprSyntax.self), tuple.elements.count == 1,
           let element = tuple.elements.first, element.label == nil, element.trailingComma == nil {
            return resolve(element.expression, environment: environment)
        }
        guard let reference = expression.as(DeclReferenceExprSyntax.self) else { return nil }
        let identifier = name(reference.baseName)
        let symbol: Symbol
        if let binding = environment[identifier] {
            if let existing = binding.symbol { symbol = existing }
            else if let initializer = binding.initializer, let resolved = resolve(initializer, environment: binding.environment) {
                binding.symbol = resolved; symbol = resolved
            } else { return nil }
        } else {
            symbol = captured[identifier] ?? makeSymbol(name: identifier, capture: reference.trimmedDescription)
            captured[identifier] = symbol
        }
        allowed.insert(reference.id)
        return symbol
    }

    private func makeSymbol(name: String, capture: String?) -> Symbol {
        // All local and captured symbols share this one allocation sequence.
        // UInt64 represents every possible host collection index exactly.
        let symbol = Symbol(key: UInt64(symbols.count), name: name, capture: capture)
        symbols.append(symbol)
        return symbol
    }

    private func functionName(_ expression: ExprSyntax, environment: [String: Binding]) -> String? {
        if let reference = expression.as(DeclReferenceExprSyntax.self), environment[name(reference.baseName)] == nil {
            return name(reference.baseName)
        }
        if let member = expression.as(MemberAccessExprSyntax.self), let base = member.base?.as(DeclReferenceExprSyntax.self),
           ["RP2xxxPIO", "RP2xxxPIOCore"].contains(name(base.baseName)), environment[name(base.baseName)] == nil {
            return name(member.declName.baseName)
        }
        return nil
    }

    private func name(_ token: TokenSyntax) -> String { token.text.filter { $0 != "`" } }

    private final class Rewrite: SyntaxRewriter {
        let bindings: [SyntaxIdentifier: Binding]
        let wrappers: Set<SyntaxIdentifier>
        let replacements: [SyntaxIdentifier: ExprSyntax]

        init(bindings: [SyntaxIdentifier: Binding], wrappers: Set<SyntaxIdentifier>, replacements: [SyntaxIdentifier: ExprSyntax]) {
            self.bindings = bindings; self.wrappers = wrappers; self.replacements = replacements
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: VariableDeclSyntax) -> DeclSyntax {
            var result = node
            if wrappers.contains(node.id) {
                result.attributes = []
                result.bindingSpecifier = .keyword(.let, trailingTrivia: .space)
            }
            result.bindings = PatternBindingListSyntax(node.bindings.map { binding in
                var result = binding
                if let symbol = bindings[binding.id]?.symbol {
                    result.initializer = InitializerClauseSyntax(
                        equal: .equalToken(leadingTrivia: .space, trailingTrivia: .space),
                        value: symbol.expression
                    )
                }
                return result
            })
            return super.visit(result)
        }

        override func visit(_ node: DeclReferenceExprSyntax) -> ExprSyntax {
            replacements[node.id] ?? ExprSyntax(node)
        }

        override func visit(_ node: TupleExprSyntax) -> ExprSyntax {
            replacements[node.id] ?? super.visit(node)
        }
    }
}
