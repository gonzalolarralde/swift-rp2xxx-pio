import ConstExprEvaluation
import ConstExprMacroSupport
import RP2xxxPIOCore
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

enum PIOExpansion {
    static func expand(_ node: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext, strict: Bool) -> ExprSyntax {
        guard let closure = node.trailingClosure ?? node.arguments.last?.expression.as(ClosureExprSyntax.self) else {
            ConstExprBuilderMacroSupport.diagnoseNonConstant("a program body is required", of: node, in: context)
            return failure("missing PIO body", strict: strict)
        }
        let arguments = node.arguments.filter { $0.label != nil }.map { argument in
            "\(argument.label!.text): \(argument.expression.trimmedDescription)"
        }.joined(separator: ", ")
        let optionsExpression = "RP2xxxPIOCore.PIOOptions(\(arguments))"
        let originalBody = "RP2xxxPIOCore.PIOAssembler.source \(closure.trimmedDescription)"
        func runtime(_ body: String) -> ExprSyntax {
            // Options are evaluated before the body, exactly once, as they are
            // in a normal function call with a trailing builder closure.
            ExprSyntax(stringLiteral: "RP2xxxPIOCore.PIOAssembler.assemble(options: \(optionsExpression), \(body))")
        }
        let labels = PIOLabelLowering()
        let lowered = labels.lower(closure)
        if let reason = labels.failureReason {
            if strict {
                ConstExprBuilderMacroSupport.diagnoseNonConstant(reason, of: node, in: context)
                return failure("nonconstant PIO labels", strict: true)
            }
            return runtime(originalBody)
        }
        let preparedNode = MacroExpansionExprSyntax(macroName: node.macroName, arguments: [], trailingClosure: lowered)
        let prepared = ConstExprBuilderMacroSupport.prepare(
            of: preparedNode, in: context, registry: PIORegistry.value,
            builderType: "RP2xxxPIOCore.PIOBuilder", runtimeFunction: "RP2xxxPIOCore.PIOAssembler.source",
            supportsBranches: true
        )
        let options: PIOOptions?
        let optionsFailure: String?
        switch ConstExprRunner(registry: PIORegistry.value).evaluateValue(
            source: "let pioOptions = \(optionsExpression)", binding: "pioOptions", policy: .certifying
        ) {
        case .success(let value):
            options = try? value.require(PIOOptions.self)
            optionsFailure = options == nil ? "program options could not be decoded" : nil
        case .fallback(let reason): options = nil; optionsFailure = "program options: \(reason.message)"
        }
        if let value = prepared.constantValue, let options {
            do {
                let source = try value.require(PIOProgramSource.self)
                let program = try PIOAssembler.assemble(options: options, source)
                let rendered = PIOProgramRendering.render(program)
                let bindings = labels.captures.compactMap { symbol -> String? in
                    guard let capture = symbol.capture, let offset = program.labels[._symbol(symbol.key)] else { return nil }
                    return "(\(capture), \(offset))"
                }.joined(separator: ", ")
                if strict {
                    return ExprSyntax(stringLiteral: bindings.isEmpty ? rendered : "\(rendered)._withLabels([\(bindings)])")
                }
                let association = bindings.isEmpty ? "" : ", labels: [\(bindings)]"
                return ExprSyntax(stringLiteral: "RP2xxxPIOCore.PIOAssembler._validated(\(rendered)\(association))")
            } catch {
                if case .undefinedLabel(let name) = error as? PIOAssemblyError,
                   labels.captures.contains(where: { $0.key == name }) {
                    if !strict { return runtime(originalBody) }
                    ConstExprBuilderMacroSupport.diagnoseNonConstant(
                        "an external jump label has no matching Label declaration; use the same handle reference for both",
                        of: node, in: context
                    )
                    return failure("unresolved external label", strict: true)
                }
                ConstExprBuilderMacroSupport.diagnoseNonConstant(
                    "invalid PIO program: \((error as? PIOAssemblyError)?.macroMessage ?? String(describing: error))", of: node, in: context
                )
                return failure("invalid PIO program", strict: strict)
            }
        }
        if strict {
            ConstExprBuilderMacroSupport.diagnoseNonConstant(
                optionsFailure ?? prepared.failureReason ?? "the builder result is not constant", of: node, in: context
            )
            return failure("nonconstant PIO program", strict: true)
        }
        if labels.hasLabels { return runtime(originalBody) }
        let body = (try? prepared.constantValue?.constExprExpression()) ?? prepared.runtimeExpression
        return runtime(body.trimmedDescription)
    }

    private static func failure(_ message: String, strict: Bool) -> ExprSyntax {
        // A typed closure avoids a secondary Never-to-Program coercion error.
        let expression = "{ () -> RP2xxxPIOCore.PIOProgram in Swift.fatalError(\"\(message)\") }()"
        return ExprSyntax(stringLiteral: strict ? expression : "RP2xxxPIOCore.PIOAssembler._validated(\(expression))")
    }
}

private extension PIOAssemblyError {
    var macroMessage: String {
        switch self {
        case .operandOutOfRange(let name, let value, let minimum, let maximum):
            return "\(name) must be between \(minimum) and \(maximum); got \(value)"
        case .unsupportedFeature(let message), .invalidConfiguration(let message), .invalidStructure(let message):
            return message
        case .duplicateSymbol(let name): return "duplicate symbol '\(name)'"
        case .undefinedLabel(let name): return "undefined label '\(name)'"
        }
    }
}
