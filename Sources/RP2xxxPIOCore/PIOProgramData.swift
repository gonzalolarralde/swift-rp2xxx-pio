/// A public symbol's value is a program-relative offset when `isLabel` is true.
public struct PIOSymbol: Equatable, Sendable {
    public let name: String
    public let value: Int
    public let isLabel: Bool
    public init(name: String, value: Int, isLabel: Bool) {
        self.name = name; self.value = value; self.isLabel = isLabel
    }
}

/// Immutable, unrelocated instruction words and pioasm-compatible metadata.
/// The SDK loader performs JMP relocation and RP2350 GPIO-base adjustment.
public struct PIOProgramData: Equatable, Sendable {
    public let instructions: [UInt16]
    public let version: PIOVersion
    public let sideSet: PIOSideSet?
    public let fifoRequirements: PIOFIFORequirements
    public let wrapTarget: Int
    public let wrap: Int
    public let usedGPIORanges: UInt8
    public let symbols: [PIOSymbol]
    /// Program-relative offsets, keyed by immutable label handles.
    public let labels: [PIOLabelHandle: Int]

    /// For already-encoded data, including macro expansions. Prefer `PIOAssembler`
    /// for source instructions: this initializer deliberately does not reassemble.
    @inlinable public init(instructions: [UInt16], version: PIOVersion = .rp2040, sideSet: PIOSideSet? = nil,
                wrapTarget: Int = 0, wrap: Int, usedGPIORanges: UInt8 = 0,
                symbols: [PIOSymbol] = [], labels: [PIOLabelHandle: Int] = .init(), fifoRequirements: PIOFIFORequirements = []) {
        self.instructions = instructions; self.version = version; self.sideSet = sideSet
        self.wrapTarget = wrapTarget; self.wrap = wrap; self.usedGPIORanges = usedGPIORanges
        self.symbols = symbols; self.labels = labels; self.fifoRequirements = fifoRequirements
    }

    public func symbol(named name: String) -> PIOSymbol? { symbols.first { $0.name == name } }

    /// Compiler support: associates captured handles with already-compiled
    /// offsets. Distinct external declarations must use distinct handles.
    public func _withLabels(_ bindings: [(PIOLabelHandle, Int)]) -> PIOProgramData {
        do { return try PIOAssembler._validated(self, labels: bindings) }
        catch { preconditionFailure("External PIO label declarations must have distinct handles") }
    }
}

public enum PIOAssemblyError: Error, Equatable, Sendable {
    case operandOutOfRange(name: String, value: Int, minimum: Int, maximum: Int)
    case unsupportedFeature(String)
    case invalidConfiguration(String)
    case invalidStructure(String)
    case duplicateSymbol(String)
    case undefinedLabel(String)
}

/// Native assembly is available even without macros or the SDK interop trait.
public enum PIOAssembler {
    public static func source(@PIOBuilder _ body: () -> PIOProgramSource) -> PIOProgramSource { body() }

    public static func assemble(options: PIOOptions = .init(), @PIOBuilder _ body: () -> PIOProgramSource) throws(PIOAssemblyError) -> PIOProgramData {
        try assemble(options: options, body())
    }

    public static func assemble(options: PIOOptions = .init(), _ source: PIOProgramSource) throws(PIOAssemblyError) -> PIOProgramData {
        var assembly = PIOAssembly(options: options)
        return try assembly.assemble(source)
    }

    /// Preserves `try #pio`'s typed-throwing contract after constant folding.
    public static func _validated(_ program: PIOProgramData, labels bindings: [(PIOLabelHandle, Int)] = []) throws(PIOAssemblyError) -> PIOProgramData {
        if bindings.isEmpty { return program }
        var labels = program.labels
        for (label, offset) in bindings {
            guard labels.updateValue(offset, forKey: label) == nil else { throw .duplicateSymbol(label.diagnosticName) }
        }
        return PIOProgramData(instructions: program.instructions, version: program.version, sideSet: program.sideSet,
            wrapTarget: program.wrapTarget, wrap: program.wrap, usedGPIORanges: program.usedGPIORanges,
            symbols: program.symbols, labels: labels, fifoRequirements: program.fifoRequirements)
    }
}

func checked(_ value: Int, _ minimum: Int, _ maximum: Int, _ name: String) throws(PIOAssemblyError) -> Int {
    guard value >= minimum, value <= maximum else {
        throw .operandOutOfRange(name: name, value: value, minimum: minimum, maximum: maximum)
    }
    return value
}
