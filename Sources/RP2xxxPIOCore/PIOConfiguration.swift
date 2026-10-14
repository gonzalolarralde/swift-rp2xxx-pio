internal import ConstExpr

@ConstExpr(registrationAccess: .package)
public struct PIOSideSet: Equatable, Sendable {
    public let bits: Int
    public let optional: Bool
    @inlinable public init(bits: Int, optional: Bool = false) {
        self.bits = bits; self.optional = optional
    }
    @inlinable public var totalBits: Int { bits + (optional ? 1 : 0) }
}

public struct PIOShiftConfiguration: Equatable, Sendable {
    public let pinCount: Int
    public let right: Bool
    public let automatic: Bool
    public let threshold: Int
    @inlinable public init(pinCount: Int, right: Bool = true, automatic: Bool = false, threshold: Int = 32) {
        self.pinCount = pinCount; self.right = right; self.automatic = automatic; self.threshold = threshold
    }
}

/// Facts collected from instructions, not choices made by the assembler.
/// Raw words are opaque and do not contribute requirements.
public struct PIOFIFORequirements: OptionSet, Sendable {
    public let rawValue: UInt8
    @inlinable public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let push = Self(rawValue: 1)
    public static let indexedRead = Self(rawValue: 2)
    public static let indexedWrite = Self(rawValue: 4)

    @inlinable public func accepts(_ fifo: PIOFIFOJoin) -> Bool {
        if rawValue & 1 != 0, fifo != .txrx && fifo != .rx { return false }
        if rawValue & 2 != 0, fifo != .txGet && fifo != .putGet { return false }
        if rawValue & 4 != 0, fifo != .txPut && fifo != .putGet { return false }
        return true
    }
}

/// Absolute GPIO bases. Pin counts remain explicit; OUT bit counts are not pin counts.
public struct PIOPinMapping: Equatable, Sendable {
    public let input: Int?
    public let output: Int?
    public let set: Int?
    public let sideSet: Int?
    public let jump: Int?
    @inlinable public init(input: Int? = nil, output: Int? = nil, set: Int? = nil,
                          sideSet: Int? = nil, jump: Int? = nil) {
        self.input = input; self.output = output; self.set = set; self.sideSet = sideSet; self.jump = jump
    }
}

public enum PIOConfigurationError: Error, Equatable, Sendable {
    case operandOutOfRange(name: String, value: Int, minimum: Int, maximum: Int)
    case unsupportedFeature(String)
    case invalidConfiguration(String)
}

/// Validated runtime setup, separate from compilation. Wrap and side-set encoding
/// are inherited from `program`; origin is a loader constraint, not an instruction edit.
public struct PIOConfiguration: Equatable, Sendable {
    public let program: PIOProgram
    public let origin: Int?
    public let sideSetPinDirections: Bool
    public let pins: PIOPinMapping
    public let input: PIOShiftConfiguration?
    public let output: PIOShiftConfiguration?
    public let setCount: Int?
    public let fifo: PIOFIFOJoin
    public let movStatus: PIOMovStatus?
    public let clockDividerInteger: UInt16
    public let clockDividerFraction: UInt8

    @inlinable public init(program: PIOProgram, origin: Int? = nil, input: PIOShiftConfiguration? = nil,
                output: PIOShiftConfiguration? = nil, setCount: Int? = nil,
                fifo: PIOFIFOJoin = .txrx, movStatus: PIOMovStatus? = nil,
                clockDivider: Double = 1, sideSetPinDirections: Bool = false,
                pins: PIOPinMapping = .init()) throws(PIOConfigurationError) {
        let version = program.version
        try Self._check(program.instructions.count, 1, 32, "program length")
        try Self._check(program.wrapTarget, 0, program.instructions.count - 1, "wrap target")
        try Self._check(program.wrap, 0, program.instructions.count - 1, "wrap")
        if let origin { try Self._check(origin, 0, 32 - program.instructions.count, "origin") }
        if let side = program.sideSet { try Self._check(side.bits, 0, side.optional ? 4 : 5, "side-set bit count") }
        if sideSetPinDirections && program.sideSet == nil {
            throw .invalidConfiguration("side-set pin directions require side-set encoding")
        }
        if let input {
            try Self._check(input.pinCount, version == .rp2040 ? 32 : 1, 32, "input pin count")
            try Self._check(input.threshold, 1, 32, "autopush threshold")
            if input.automatic && fifo.rawValue > PIOFIFOJoin.rx.rawValue {
                throw .invalidConfiguration("autopush is incompatible with indexed RX FIFO modes")
            }
        }
        if let output {
            try Self._check(output.pinCount, 0, 32, "output pin count")
            try Self._check(output.threshold, 1, 32, "autopull threshold")
        }
        if let setCount { try Self._check(setCount, 0, 5, "set pin count") }
        if fifo.rawValue > PIOFIFOJoin.rx.rawValue && version == .rp2040 {
            throw .unsupportedFeature("indexed RX FIFO modes require RP2350")
        }
        guard program.fifoRequirements.accepts(fifo) else {
            throw .invalidConfiguration("FIFO mode is incompatible with the program's instructions")
        }
        if let movStatus {
            switch movStatus {
            case .txLessThan(let n), .rxLessThan(let n): try Self._check(n, 0, 31, "MOV status FIFO depth")
            case .irqSet(let n, _):
                guard version == .rp2350 else { throw .unsupportedFeature("IRQ MOV status requires RP2350") }
                try Self._check(n, 0, 7, "MOV status IRQ")
            }
        }
        // Match pioasm's single-precision divider conversion.
        let divider = Float(clockDivider)
        guard divider.isFinite && divider >= 1 && divider < 65536 else {
            throw .invalidConfiguration("clock divider must be finite, at least 1, and less than 65536")
        }
        let maxPin = version == .rp2040 ? 31 : 47
        if let pin = pins.input { try Self._check(pin, 0, maxPin, "input pin base") }
        if let pin = pins.output { try Self._check(pin, 0, maxPin, "output pin base") }
        if let pin = pins.set { try Self._check(pin, 0, maxPin, "set pin base") }
        if let pin = pins.sideSet { try Self._check(pin, 0, maxPin, "side-set pin base") }
        if let pin = pins.jump { try Self._check(pin, 0, maxPin, "jump pin") }
        self.program = program; self.origin = origin; self.sideSetPinDirections = sideSetPinDirections; self.pins = pins
        self.input = input; self.output = output; self.setCount = setCount
        self.fifo = fifo; self.movStatus = movStatus
        self.clockDividerInteger = UInt16(divider)
        self.clockDividerFraction = UInt8((divider - Float(UInt16(divider))) * 256)
    }

    /// Compiler support shared by native configuration and generated setup.
    @inlinable public static func _check(_ value: Int, _ minimum: Int, _ maximum: Int, _ name: String) throws(PIOConfigurationError) {
        guard value >= minimum && value <= maximum else {
            throw .operandOutOfRange(name: name, value: value, minimum: minimum, maximum: maximum)
        }
    }

    @inlinable public func _validateOffset(_ offset: UInt32) throws(PIOConfigurationError) {
        guard offset <= 31 && UInt32(program.wrapTarget) <= 31 - offset && UInt32(program.wrap) <= 31 - offset else {
            throw .invalidConfiguration("loaded wrap addresses exceed instruction memory")
        }
    }

    @inlinable public var _sdkFIFO: UInt32 {
        switch fifo {
        case .txrx: return 0
        case .tx: return 1
        case .rx: return 2
        case .txPut: return 8
        case .txGet: return 4
        case .putGet: return 12
        }
    }

    @inlinable public static func _sdkStatus(_ status: PIOMovStatus) -> (UInt32, UInt32) {
        switch status {
        case .txLessThan(let n): return (0, UInt32(n))
        case .rxLessThan(let n): return (1, UInt32(n))
        case .irqSet(let n, let bank): return (2, UInt32(n + bank.rawValue * 8))
        }
    }
}

@ConstExpr(registrationAccess: .package)
public enum PIODirective: Equatable, Sendable {
    case wrapTarget
    case wrap
}
