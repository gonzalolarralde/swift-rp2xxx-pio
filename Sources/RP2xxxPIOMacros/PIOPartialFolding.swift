import ConstExprEvaluation
import RP2xxxPIOCore
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Specializes individual builder expressions, not the builder's control flow.
/// The ordinary Swift builder still owns evaluation order, branch selection,
/// label identity, and layout. The evaluator supplies values; only the existing
/// assembler supplies instruction bits and metadata.
final class PIOPartialFolding {
    private enum Binding { case known(String), unknown }
    private typealias Environment = [String: Binding]
    private let options: PIOOptions
    private let runner = ConstExprRunner(registry: PIORegistry.value)
    private let resultName: String

    init(options: PIOOptions, context: some MacroExpansionContext) {
        self.options = options
        resultName = context.makeUniqueName("pioInstruction").text
    }

    func rewrite(_ closure: ClosureExprSyntax) -> ClosureExprSyntax {
        guard closure.signature == nil else { return closure }
        var result = closure
        result.statements = block(closure.statements, environment: [:])
        return result
    }

    private func block(_ statements: CodeBlockItemListSyntax, environment initial: Environment) -> CodeBlockItemListSyntax {
        var environment = initial
        // Reserve local names even before their declarations. A forward use or
        // a local function must not accidentally resolve to a registered API.
        for item in statements {
            if let declaration = item.item.as(DeclSyntax.self) {
                for name in declaredNames(declaration) { environment[name] = .unknown }
            }
        }
        var constantBindings: Set<SyntaxIdentifier> = []
        var items: [CodeBlockItemSyntax] = []
        for var item in statements {
            if let variable = item.item.as(VariableDeclSyntax.self) {
                for binding in variable.bindings {
                    guard let pattern = binding.pattern.as(IdentifierPatternSyntax.self) else { continue }
                    let name = normalized(pattern.identifier.text)
                    if variable.bindingSpecifier.tokenKind == .keyword(.let),
                       variable.attributes.isEmpty, variable.modifiers.isEmpty,
                       binding.accessorBlock == nil, let initializer = binding.initializer,
                       let value = evaluate(initializer.value, type: binding.typeAnnotation?.type, environment: environment),
                       let rendered = try? value.constExprExpression() {
                        environment[name] = .known(rendered.trimmedDescription)
                        constantBindings.insert(binding.id)
                    } else { environment[name] = .unknown }
                }
            } else if let expression = item.item.as(ExprSyntax.self) {
                item.item = .expr(expressionBody(expression, environment: environment))
            } else if var statement = item.item.as(ExpressionStmtSyntax.self) {
                statement.expression = expressionBody(statement.expression, environment: environment)
                item.item = .stmt(StmtSyntax(statement))
            }
            items.append(item)
        }
        // Keep user initializers, scopes, and lifetimes intact. A no-op local
        // use prevents folding from introducing unused-binding warnings, even
        // when a nested declaration shadows the same name. Swift eliminates
        // these value reads; they are not builder expressions/instructions.
        let originalReferences = references(statements)
        var retained: [CodeBlockItemSyntax] = []
        for item in items {
            retained.append(item)
            guard let variable = item.item.as(VariableDeclSyntax.self) else { continue }
            for binding in variable.bindings {
                guard constantBindings.contains(binding.id),
                      let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
                      originalReferences.contains(normalized(pattern.identifier.text)) else { continue }
                retained.append(CodeBlockItemSyntax(item: .decl(DeclSyntax(stringLiteral: "\nlet _ = \(pattern.identifier.text)\n"))))
            }
        }
        return CodeBlockItemListSyntax(retained)
    }

    private func expressionBody(_ expression: ExprSyntax, environment: Environment) -> ExprSyntax {
        if var selection = expression.as(IfExprSyntax.self) {
            var branchEnvironment = environment
            for name in patterns(selection.conditions) { branchEnvironment[name] = .unknown }
            selection.body.statements = block(selection.body.statements, environment: branchEnvironment)
            if let alternative = selection.elseBody?.as(IfExprSyntax.self) {
                selection.elseBody = .ifExpr(expressionBody(ExprSyntax(alternative), environment: environment).cast(IfExprSyntax.self))
            } else if var alternative = selection.elseBody?.as(CodeBlockSyntax.self) {
                alternative.statements = block(alternative.statements, environment: environment)
                selection.elseBody = .codeBlock(alternative)
            }
            return ExprSyntax(selection)
        }
        if var selection = expression.as(SwitchExprSyntax.self) {
            selection.cases = SwitchCaseListSyntax(selection.cases.map { item in
                guard var branch = item.as(SwitchCaseSyntax.self) else { return item }
                var branchEnvironment = environment
                for name in patterns(branch.label) { branchEnvironment[name] = .unknown }
                branch.statements = block(branch.statements, environment: branchEnvironment)
                return .switchCase(branch)
            })
            return ExprSyntax(selection)
        }
        let component = ExprSyntax(stringLiteral: "RP2xxxPIOCore.PIOBuilder.buildExpression(\(expression.trimmedDescription))")
        guard let value = evaluate(component, environment: environment),
              let statements = try? value.require([PIOStatement].self), statements.count == 1,
              case .instruction(let instruction) = statements[0]
        else { return expression }
        // Even numeric jumps depend on final program length for validation.
        // Keep all jumps in the existing symbolic/runtime assembler path.
        if case .jmp = instruction.operation { return expression }
        // An invalid instruction in an uncertain branch must remain a runtime
        // error only if that branch is selected. Whole constants are diagnosed
        // by the existing complete-program path, before this pass is attempted.
        guard let program = try? PIOAssembler.assemble(options: options, PIOProgramSource(statements)),
              let word = program.instructions.first
        else { return expression }
        let rendered: String
        if program.usedGPIORanges == 0 && program.fifoRequirements.isEmpty && environment["Swift"] == nil {
            rendered = "Swift.UInt16(\(word))"
        } else {
            rendered = "RP2xxxPIOCore.PIOStatement.encoded(\(word), gpioRanges: \(program.usedGPIORanges), fifo: \(program.fifoRequirements.rawValue))"
        }
        return ExprSyntax(stringLiteral: rendered)
            .with(\.leadingTrivia, expression.leadingTrivia)
            .with(\.trailingTrivia, expression.trailingTrivia)
    }

    private func evaluate(_ expression: ExprSyntax, type: TypeSyntax? = nil, environment: Environment) -> ConstExprValue? {
        var names: [String: String] = [:]
        let bindings = environment.sorted { $0.key < $1.key }.enumerated().map { index, entry in
            let (name, binding) = entry
            let temporary = "\(resultName)_binding\(index)"
            names[name] = temporary
            let value: String
            switch binding {
            case .known(let expression): value = expression
            case .unknown: value = "\(resultName)_unknown"
            }
            return "let \(temporary) = \(value)"
        }
        let annotation = type.map { ": \($0.trimmedDescription)" } ?? ""
        let renamed = References(names: names).rewrite(expression).cast(ExprSyntax.self)
        let source = (bindings + ["let \(resultName)\(annotation) = \(renamed.trimmedDescription)"]).joined(separator: "\n")
        guard case .success(let value) = runner.evaluateValue(source: source, binding: resultName, policy: .permissive) else { return nil }
        return value
    }

    private func declaredNames(_ declaration: DeclSyntax) -> Set<String> {
        if let variable = declaration.as(VariableDeclSyntax.self) {
            return variable.bindings.reduce(into: []) { $0.formUnion(patterns($1.pattern)) }
        }
        if let function = declaration.as(FunctionDeclSyntax.self) { return [normalized(function.name.text)] }
        if let type = declaration.as(StructDeclSyntax.self) { return [normalized(type.name.text)] }
        if let type = declaration.as(EnumDeclSyntax.self) { return [normalized(type.name.text)] }
        if let type = declaration.as(ClassDeclSyntax.self) { return [normalized(type.name.text)] }
        if let type = declaration.as(TypeAliasDeclSyntax.self) { return [normalized(type.name.text)] }
        return []
    }

    private func normalized(_ name: String) -> String { name.filter { $0 != "`" } }
    private func patterns(_ node: some SyntaxProtocol) -> Set<String> {
        let visitor = Names(patterns: true)
        visitor.walk(node)
        return visitor.names
    }
    private func references(_ node: some SyntaxProtocol) -> Set<String> {
        let visitor = Names(patterns: false)
        visitor.walk(node)
        return visitor.names
    }
    private final class Names: SyntaxVisitor {
        var names: Set<String> = []
        let patterns: Bool
        init(patterns: Bool) { self.patterns = patterns; super.init(viewMode: .sourceAccurate) }
        override func visit(_ node: IdentifierPatternSyntax) -> SyntaxVisitorContinueKind {
            if patterns { names.insert(node.identifier.text.filter { $0 != "`" }) }
            return .visitChildren
        }
        override func visit(_ node: DeclReferenceExprSyntax) -> SyntaxVisitorContinueKind {
            if !patterns { names.insert(node.baseName.text.filter { $0 != "`" }) }
            return .visitChildren
        }
    }

    /// Alpha-rename only lexical references, never member names. Besides
    /// preserving shadowing, this handles escaped Swift identifiers uniformly.
    private final class References: SyntaxRewriter {
        let names: [String: String]
        init(names: [String: String]) { self.names = names; super.init(viewMode: .sourceAccurate) }
        override func visit(_ node: DeclReferenceExprSyntax) -> ExprSyntax {
            guard let name = names[node.baseName.text.filter({ $0 != "`" })] else { return ExprSyntax(node) }
            var result = node
            result.baseName = .identifier(name)
                .with(\.leadingTrivia, node.baseName.leadingTrivia)
                .with(\.trailingTrivia, node.baseName.trailingTrivia)
            return ExprSyntax(result)
        }
        override func visit(_ node: MemberAccessExprSyntax) -> ExprSyntax {
            var result = node
            if let base = node.base { result.base = rewrite(base).cast(ExprSyntax.self) }
            return ExprSyntax(result)
        }
    }
}
