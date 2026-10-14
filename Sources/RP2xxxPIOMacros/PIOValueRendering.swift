import ConstExprEvaluation
import RP2xxxPIOCore
import SwiftSyntax
import SwiftSyntaxBuilder

// Host-only rendering for partially constant builder components. The device
// model stays syntax-free and assembly still happens once, after the builder.
extension PIOInstruction: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax { ExprSyntax(stringLiteral: try PIOValueRendering.instruction(self)) }
}

extension PIOStatement: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax { ExprSyntax(stringLiteral: try PIOValueRendering.statement(self)) }
}

extension PIODirective: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax {
        ExprSyntax(stringLiteral: "RP2xxxPIOCore.PIODirective" + PIOValueRendering.directive(self))
    }
}

extension PIOProgramSource: ConstExprRepresentable {
    public func constExprExpression() throws -> ExprSyntax {
        let items = try statements.map(PIOValueRendering.statement).joined(separator: ", ")
        return ExprSyntax(stringLiteral: "RP2xxxPIOCore.PIOProgramSource([\(items)])")
    }
}

enum PIOValueRendering {
    static func statement(_ value: PIOStatement) throws -> String {
        let body: String
        switch value {
        case .instruction(let value): body = ".instruction(\(try instruction(value)))"
        case .directive(let value): body = ".directive(\(directive(value)))"
        case .label(let value): body = ".label(\(try label(value)))"
        case .symbol(let name, let value, let isPublic): body = ".symbol(\(quoted(name)), \(value), isPublic: \(isPublic))"
        case .word(let value): body = ".word(\(value))"
        }
        return "RP2xxxPIOCore.PIOStatement" + body
    }

    static func instruction(_ value: PIOInstruction) throws -> String {
        let operation: String
        switch value.operation {
        case .jmp(let condition, let target):
            let address: String
            switch target {
            case .address(let value): address = ".address(\(value))"
            case .label(let value): address = ".label(\(try label(value)))"
            }
            operation = ".jmp(\(simple(condition)), \(address))"
        case .wait(let polarity, let source):
            let operand: String
            switch source {
            case .gpio(let value): operand = ".gpio(\(value))"
            case .pin(let value): operand = ".pin(\(value))"
            case .irq(let value, let mode): operand = ".irq(\(value), mode: \(simple(mode)))"
            case .jmpPin(let value): operand = ".jmpPin(offset: \(value))"
            }
            operation = ".wait(\(polarity), \(operand))"
        case .input(let source, let count): operation = ".input(\(simple(source)), \(count))"
        case .output(let destination, let count): operation = ".output(\(simple(destination)), \(count))"
        case .push(let conditional, let blocking): operation = ".push(ifFull: \(conditional), blocking: \(blocking))"
        case .pull(let conditional, let blocking): operation = ".pull(ifEmpty: \(conditional), blocking: \(blocking))"
        case .mov(let destination, let source, let modifier):
            operation = ".mov(\(movDestination(destination)), \(movSource(source)), \(simple(modifier)))"
        case .irq(let operationValue, let index, let mode): operation = ".irq(\(simple(operationValue)), \(index), \(simple(mode)))"
        case .set(let destination, let value): operation = ".set(\(simple(destination)), \(value))"
        case .nop: operation = ".nop"
        }
        return "RP2xxxPIOCore.PIOInstruction(\(operation), delay: \(value.delayCycles), sideSet: \(value.sideSetValue.map(String.init) ?? "nil"))"
    }

    static func directive(_ value: PIODirective) -> String {
        switch value {
        case .wrapTarget: return ".wrapTarget"
        case .wrap: return ".wrap"
        }
    }

    private static func movDestination(_ value: PIOMovDestination) -> String {
        if case .rxFIFO(let index) = value { return ".rxFIFO(\(fifoIndex(index)))" }
        return simple(value)
    }

    private static func movSource(_ value: PIOMovSource) -> String {
        if case .rxFIFO(let index) = value { return ".rxFIFO(\(fifoIndex(index)))" }
        return simple(value)
    }

    private static func fifoIndex(_ value: PIOFIFOIndex) -> String {
        switch value {
        case .y: return ".y"
        case .index(let value): return ".index(\(value))"
        }
    }

    // Only private, payload-free library enums reach this helper. Their case
    // names are Swift identifiers; associated cases are explicitly handled above.
    private static func simple<T>(_ value: T) -> String { "." + String(describing: value) }
    private enum RenderingError: Error { case runtimeLabel }
    private static func label(_ value: PIOLabelHandle) throws -> String {
        guard let name = value.symbolicName else { throw RenderingError.runtimeLabel }
        return "RP2xxxPIOCore.PIOLabelHandle._symbol(\(quoted(name)))"
    }
    private static func quoted(_ value: String) -> String { StringLiteralExprSyntax(content: value).trimmedDescription }
}
