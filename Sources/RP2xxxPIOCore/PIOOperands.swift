internal import ConstExpr

@ConstExpr(registrationAccess: .package)
public enum PIOVersion: Int, Equatable, Sendable { case rp2040 = 0, rp2350 = 1 }

@ConstExpr(registrationAccess: .package)
public enum PIOJmpCondition: Int, Equatable, Sendable {
    case always = 0, notX, xDecrement, notY, yDecrement, xNotEqualY, pin, notOSREmpty
}

@ConstExpr(registrationAccess: .package)
public enum PIOIRQIndexMode: Int, Equatable, Sendable { case absolute = 0, previous, relative, next }

@ConstExpr(registrationAccess: .package)
public enum PIOWaitSource: Equatable, Sendable {
    case gpio(Int)
    case pin(Int)
    case irq(Int, mode: PIOIRQIndexMode = .absolute)
    case jmpPin(offset: Int = 0)
}

@ConstExpr(registrationAccess: .package)
public enum PIOInSource: Int, Equatable, Sendable { case pins = 0, x, y, null, status = 5, isr, osr }

@ConstExpr(registrationAccess: .package)
public enum PIOOutDestination: Int, Equatable, Sendable { case pins = 0, x, y, null, pinDirs, pc, isr, exec }

@ConstExpr(registrationAccess: .package)
public enum PIOFIFOIndex: Equatable, Sendable { case y, index(Int) }

@ConstExpr(registrationAccess: .package)
public enum PIOMovDestination: Equatable, Sendable { case pins, x, y, pinDirs, exec, pc, isr, osr, rxFIFO(PIOFIFOIndex) }

@ConstExpr(registrationAccess: .package)
public enum PIOMovSource: Equatable, Sendable { case pins, x, y, null, status, isr, osr, rxFIFO(PIOFIFOIndex) }

@ConstExpr(registrationAccess: .package)
public enum PIOMovOperation: Int, Equatable, Sendable { case none = 0, invert, bitReverse }

@ConstExpr(registrationAccess: .package)
public enum PIOIRQOperation: Int, Equatable, Sendable { case set = 0, wait, clear }

@ConstExpr(registrationAccess: .package)
public enum PIOSetDestination: Int, Equatable, Sendable { case pins = 0, x, y, pinDirs = 4 }

public enum PIOFIFOJoin: Int, Equatable, Sendable { case txrx = 0, tx, rx, txPut, txGet, putGet }

public enum PIOMovStatus: Equatable, Sendable {
    case txLessThan(Int)
    case rxLessThan(Int)
    case irqSet(Int, bank: PIOIRQBank = .current)
}

public enum PIOIRQBank: Int, Equatable, Sendable { case current = 0, previous, next }
