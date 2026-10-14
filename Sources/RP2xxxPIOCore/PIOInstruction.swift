internal import ConstExpr

@ConstExpr(registrationAccess: .package)
public enum PIOJumpTarget: Equatable, Sendable { case address(Int), label(PIOLabelHandle) }

@ConstExpr(registrationAccess: .package)
public enum PIOOperation: Equatable, Sendable {
    case jmp(PIOJmpCondition, PIOJumpTarget)
    case wait(Bool, PIOWaitSource)
    case input(PIOInSource, Int)
    case output(PIOOutDestination, Int)
    case push(ifFull: Bool, blocking: Bool)
    case pull(ifEmpty: Bool, blocking: Bool)
    case mov(PIOMovDestination, PIOMovSource, PIOMovOperation)
    case irq(PIOIRQOperation, Int, PIOIRQIndexMode)
    case set(PIOSetDestination, Int)
    case nop
}

/// An unencoded instruction. Modifiers are validated by the assembler.
@ConstExpr(registrationAccess: .package)
public struct PIOInstruction: Equatable, Sendable {
    public let operation: PIOOperation
    public let delayCycles: Int
    public let sideSetValue: Int?

    public init(_ operation: PIOOperation, delay: Int = 0, sideSet: Int? = nil) {
        self.operation = operation
        self.delayCycles = delay
        self.sideSetValue = sideSet
    }

    public func delay(_ cycles: Int) -> PIOInstruction {
        PIOInstruction(operation, delay: cycles, sideSet: sideSetValue)
    }

    public func sideSet(value: Int) -> PIOInstruction {
        PIOInstruction(operation, delay: delayCycles, sideSet: value)
    }
}

@ConstExpr(registrationAccess: .package)
public func Jmp(_ condition: PIOJmpCondition = .always, to label: PIOLabelHandle) -> PIOInstruction {
    PIOInstruction(.jmp(condition, .label(label)))
}

@ConstExpr(registrationAccess: .package)
public func Jmp(_ condition: PIOJmpCondition = .always, to address: Int) -> PIOInstruction {
    PIOInstruction(.jmp(condition, .address(address)))
}

@ConstExpr(registrationAccess: .package)
public func Wait(_ polarity: Bool, _ source: PIOWaitSource) -> PIOInstruction { PIOInstruction(.wait(polarity, source)) }

@ConstExpr(registrationAccess: .package)
public func In(_ source: PIOInSource, _ count: Int) -> PIOInstruction { PIOInstruction(.input(source, count)) }

@ConstExpr(registrationAccess: .package)
public func Out(_ destination: PIOOutDestination, _ count: Int) -> PIOInstruction { PIOInstruction(.output(destination, count)) }

@ConstExpr(registrationAccess: .package)
public func Push(ifFull: Bool = false, blocking: Bool = true) -> PIOInstruction {
    PIOInstruction(.push(ifFull: ifFull, blocking: blocking))
}

@ConstExpr(registrationAccess: .package)
public func Pull(ifEmpty: Bool = false, blocking: Bool = true) -> PIOInstruction {
    PIOInstruction(.pull(ifEmpty: ifEmpty, blocking: blocking))
}

@ConstExpr(registrationAccess: .package)
public func Mov(to destination: PIOMovDestination, from source: PIOMovSource, operation: PIOMovOperation = .none) -> PIOInstruction {
    PIOInstruction(.mov(destination, source, operation))
}

@ConstExpr(registrationAccess: .package)
public func Irq(_ operation: PIOIRQOperation = .set, _ index: Int, mode: PIOIRQIndexMode = .absolute) -> PIOInstruction {
    PIOInstruction(.irq(operation, index, mode))
}

@ConstExpr(registrationAccess: .package)
public func Set(_ destination: PIOSetDestination, _ value: Int) -> PIOInstruction { PIOInstruction(.set(destination, value)) }

@ConstExpr(registrationAccess: .package)
public func Nop() -> PIOInstruction { PIOInstruction(.nop) }
