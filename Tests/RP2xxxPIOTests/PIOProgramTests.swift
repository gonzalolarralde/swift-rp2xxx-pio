import RP2xxxPIO
import Testing

private struct MinimalProgram: PIOProgram {
    let code = #constPIO { Nop() }
}

private struct ConfiguredProgram: PIOProgram {
    private static let entryLabel = PIOLabelHandle()
    private static let compiledCode = #constPIO(version: .rp2350, sideSet: .init(bits: 2, optional: true)) {
        Wait(true, .gpio(47))
        Label(entryLabel)
        WrapTarget()
        Out(.pins, 6).sideSet(value: 3)
        Wrap()
        Jmp(to: entryLabel)
    }

    var entry: PIOLabelHandle { Self.entryLabel }
    var code: PIOProgramData { Self.compiledCode }
    let origin: Int? = 4
    let input: PIOShiftConfiguration? = .init(pinCount: 16, right: false, automatic: true, threshold: 12)
    let output: PIOShiftConfiguration? = .init(pinCount: 6, right: false, automatic: true, threshold: 24)
    let setCount: Int? = 3
    let fifo: PIOFIFOJoin = .tx
    let movStatus: PIOMovStatus? = .irqSet(6, bank: .next)
    var clockDivider: Double = 2.5
    let sideSetPinDirections = true
    var pins = PIOPinMapping(input: 32, output: 33, set: 34, sideSet: 35, jump: 47)
}

private func configuration<P: PIOProgram>(of program: P) throws(PIOConfigurationError) -> PIOConfiguration {
    try program.configuration()
}

@Test func programProtocolProvidesDefaultsWithoutSDK() throws {
    let program = MinimalProgram()
    let actual = try configuration(of: program)
    #expect(actual == (try PIOConfiguration(program: program.code)))
    #expect(actual.origin == nil)
    #expect(actual.input == nil && actual.output == nil && actual.setCount == nil)
    #expect(actual.fifo == .txrx && actual.movStatus == nil)
    #expect(actual.clockDividerInteger == 1 && actual.clockDividerFraction == 0)
    #expect(!actual.sideSetPinDirections && actual.pins == PIOPinMapping())
}

@Test func programProtocolUsesEveryDeclaredOverrideInGenericCode() throws {
    let program = ConfiguredProgram()
    let expected = try PIOConfiguration(program: program.code, origin: 4,
        input: .init(pinCount: 16, right: false, automatic: true, threshold: 12),
        output: .init(pinCount: 6, right: false, automatic: true, threshold: 24),
        setCount: 3, fifo: .tx, movStatus: .irqSet(6, bank: .next), clockDivider: 2.5,
        sideSetPinDirections: true, pins: .init(input: 32, output: 33, set: 34, sideSet: 35, jump: 47))
    #expect(try configuration(of: program) == expected)
}

@Test func programProtocolInstancesHaveIndependentConfiguration() throws {
    let first = ConfiguredProgram()
    var second = first
    second.clockDivider = 3.75
    second.pins = .init(input: 16, output: 17, set: 18, sideSet: 19, jump: 20)
    let firstConfig = try configuration(of: first)
    let secondConfig = try configuration(of: second)
    #expect(firstConfig.clockDividerInteger == 2 && firstConfig.clockDividerFraction == 128)
    #expect(secondConfig.clockDividerInteger == 3 && secondConfig.clockDividerFraction == 192)
    #expect(firstConfig.pins != secondConfig.pins)
    #expect(first.code == second.code)
}

@Test func programProtocolDerivesMetadataAndLabelOffsets() {
    let program = ConfiguredProgram()
    #expect(program.instructions == program.code.instructions)
    #expect(program.version == .rp2350)
    #expect(program.sideSet == PIOSideSet(bits: 2, optional: true))
    #expect(program.wrapTarget == 1 && program.wrap == 1)
    #expect(program.usedGPIORanges == program.code.usedGPIORanges)
    #expect(program.symbols == program.code.symbols)
    #expect(program.labels == program.code.labels)
    #expect(program.fifoRequirements == program.code.fifoRequirements)
    #expect(program.offset(of: program.entry) == 1)
    #expect(program.offset(of: PIOLabelHandle()) == nil)
    #expect(MinimalProgram().offset(of: program.entry) == nil)
}

// Each test instance owns its own read log; no mutable global state is needed.
private final class ReadLog {
    var names: [String] = []
}

private struct RuntimeProgram: PIOProgram {
    let log: ReadLog
    var divider = 2.5
    var code: PIOProgramData { log.names.append("code"); return MinimalProgram().code }
    var origin: Int? { log.names.append("origin"); return nil }
    var input: PIOShiftConfiguration? { log.names.append("input"); return nil }
    var output: PIOShiftConfiguration? { log.names.append("output"); return nil }
    var setCount: Int? { log.names.append("setCount"); return nil }
    var fifo: PIOFIFOJoin { log.names.append("fifo"); return .txrx }
    var movStatus: PIOMovStatus? { log.names.append("movStatus"); return nil }
    var clockDivider: Double { log.names.append("clockDivider"); return divider }
    var sideSetPinDirections: Bool { log.names.append("sideSetPinDirections"); return false }
    var pins: PIOPinMapping { log.names.append("pins"); return .init() }
}

@Test func programProtocolReadsRuntimeRequirementsOncePerConfiguration() throws {
    let names = ["code", "origin", "input", "output", "setCount", "fifo", "movStatus", "clockDivider", "sideSetPinDirections", "pins"]
    let log = ReadLog()
    var program = RuntimeProgram(log: log)
    let first = try configuration(of: program)
    #expect(log.names == names)
    #expect(first.clockDividerInteger == 2 && first.clockDividerFraction == 128)
    log.names = []
    program.divider = 3.75
    let second = try configuration(of: program)
    #expect(log.names == names)
    #expect(second.clockDividerInteger == 3 && second.clockDividerFraction == 192)
    log.names = []
    program.divider = .nan
    #expect(throws: PIOConfigurationError.self) { try configuration(of: program) }
    #expect(log.names == names)
}

private struct InvalidFIFOProgram: PIOProgram {
    let fifo: PIOFIFOJoin = .tx
    let code = #constPIO { Push() }
}

private struct InvalidOriginProgram: PIOProgram {
    let origin: Int? = 31
    let code = #constPIO { Nop(); Nop() }
}

@Test func programProtocolPreservesConfigurationValidation() {
    #expect(throws: PIOConfigurationError.self) { try InvalidFIFOProgram().configuration() }
    #expect(throws: PIOConfigurationError.self) { try InvalidOriginProgram().configuration() }
}
