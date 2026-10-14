internal import ConstExpr

@ConstExpr(registrationAccess: .package)
public enum PIOStatement: Equatable, Sendable {
    case instruction(PIOInstruction)
    case directive(PIODirective)
    case label(PIOLabelHandle)
    case symbol(String, Int, isPublic: Bool)
    case word(Int)
}

@ConstExpr(registrationAccess: .package)
public struct PIOProgramSource: Equatable, Sendable {
    public let statements: [PIOStatement]
    public init(_ statements: [PIOStatement]) { self.statements = statements }
}

@resultBuilder
public enum PIOBuilder {}

@ConstExprMembers(registrationAccess: .package)
public extension PIOBuilder {
    static func buildExpression(_ instruction: PIOInstruction) -> [PIOStatement] { [.instruction(instruction)] }
    static func buildExpression(_ directive: PIODirective) -> [PIOStatement] { [.directive(directive)] }
    static func buildExpression(_ statement: PIOStatement) -> [PIOStatement] { [statement] }
    static func buildPartialBlock(first: [PIOStatement]) -> [PIOStatement] { first }
    static func buildPartialBlock(accumulated: [PIOStatement], next: [PIOStatement]) -> [PIOStatement] { accumulated + next }
    static func buildFinalResult(_ statements: [PIOStatement]) -> PIOProgramSource { PIOProgramSource(statements) }
    static func buildBlock() -> [PIOStatement] { [] }
    static func buildEither(first: [PIOStatement]) -> [PIOStatement] { first }
    static func buildEither(second: [PIOStatement]) -> [PIOStatement] { second }
    static func buildOptional(_ statements: [PIOStatement]?) -> [PIOStatement] { statements ?? [] }
}

@ConstExpr(registrationAccess: .package)
public func Label(_ label: PIOLabelHandle) -> PIOStatement { .label(label) }

@ConstExpr(registrationAccess: .package)
public func Define(_ name: String, _ value: Int, isPublic: Bool = false) -> PIOStatement { .symbol(name, value, isPublic: isPublic) }

@ConstExpr(registrationAccess: .package)
public func Word(_ value: Int) -> PIOStatement { .word(value) }

@ConstExpr(registrationAccess: .package)
public func WrapTarget() -> PIODirective { .wrapTarget }

@ConstExpr(registrationAccess: .package)
public func Wrap() -> PIODirective { .wrap }
