/// A PIO program value and its default state-machine configuration.
///
/// Only `code` is required. Override the other requirements with exactly matching
/// types, including optionality, to replace their defaults in generic code.
/// Configuration does not claim resources, load instructions, or touch hardware.
public protocol PIOProgram {
    var code: PIOProgramData { get }
    var origin: Int? { get }
    var input: PIOShiftConfiguration? { get }
    var output: PIOShiftConfiguration? { get }
    var setCount: Int? { get }
    var fifo: PIOFIFOJoin { get }
    var movStatus: PIOMovStatus? { get }
    var clockDivider: Double { get }
    var sideSetPinDirections: Bool { get }
    var pins: PIOPinMapping { get }
}

public extension PIOProgram {
    @inlinable var origin: Int? { nil }
    @inlinable var input: PIOShiftConfiguration? { nil }
    @inlinable var output: PIOShiftConfiguration? { nil }
    @inlinable var setCount: Int? { nil }
    @inlinable var fifo: PIOFIFOJoin { .txrx }
    @inlinable var movStatus: PIOMovStatus? { nil }
    @inlinable var clockDivider: Double { 1 }
    @inlinable var sideSetPinDirections: Bool { false }
    @inlinable var pins: PIOPinMapping { .init() }

    @inlinable var instructions: [UInt16] { code.instructions }
    @inlinable var version: PIOVersion { code.version }
    @inlinable var sideSet: PIOSideSet? { code.sideSet }
    @inlinable var wrapTarget: Int { code.wrapTarget }
    @inlinable var wrap: Int { code.wrap }
    @inlinable var usedGPIORanges: UInt8 { code.usedGPIORanges }
    @inlinable var symbols: [PIOSymbol] { code.symbols }
    @inlinable var labels: [PIOLabelHandle: Int] { code.labels }
    @inlinable var fifoRequirements: PIOFIFORequirements { code.fifoRequirements }

    /// A program-relative offset, or nil if this program does not define the handle.
    @inlinable func offset(of label: PIOLabelHandle) -> Int? { code.labels[label] }

    /// Reads each requirement once and validates a fresh configuration. Computed
    /// requirements may supply runtime values; the result is never cached.
    @inlinable func configuration() throws(PIOConfigurationError) -> PIOConfiguration {
        try PIOConfiguration(program: code, origin: origin, input: input, output: output,
            setCount: setCount, fifo: fifo, movStatus: movStatus, clockDivider: clockDivider,
            sideSetPinDirections: sideSetPinDirections, pins: pins)
    }
}
