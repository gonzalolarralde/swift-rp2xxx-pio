internal import ConstExpr

@ConstExpr(registrationAccess: .package)
public enum PIOStatement: Equatable, Sendable {
    case instruction(PIOInstruction)
    case directive(PIODirective)
    case label(PIOLabelHandle)
    case symbol(String, Int, isPublic: Bool)
    case word(Int)
    /// Already encoded bits. Compiler-produced values retain the source
    /// instruction's metadata, which cannot always be recovered from its bits
    /// (notably RP2350 WAIT GPIO 32...47). The metadata is trusted, not decoded.
    case encoded(UInt16, gpioRanges: UInt8, fifo: UInt8)
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
    /// A raw, complete instruction word, including delay/side-set bits. Like
    /// Word, this is an opaque escape hatch and does not infer GPIO/FIFO usage.
    static func buildExpression(_ word: UInt16) -> [PIOStatement] { [.encoded(word, gpioRanges: 0, fifo: 0)] }
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
