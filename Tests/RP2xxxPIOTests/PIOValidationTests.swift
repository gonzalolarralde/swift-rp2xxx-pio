import RP2xxxPIO
import Testing

@Test func allConfigurationAndMetadataSurviveAssembly() throws {
    @PIOLabel var loop
    let program = #constPIO(
        version: .rp2350, sideSet: .init(bits: 2, optional: true)
    ) {
        Define("limit", 123, isPublic: true)
        Nop()
        WrapTarget()
        Label(loop)
        Wait(true, .gpio(47)).sideSet(value: 3).delay(2)
        Push()
        Wrap()
        Jmp(to: loop)
    }
    #expect(program.instructions == [0xa042, 0x3e8f, 0x8020, 0x0001])
    #expect(program.version == .rp2350)
    #expect(program.wrapTarget == 1 && program.wrap == 2)
    #expect(program.usedGPIORanges == 4)
    #expect(program.symbols == [.init(name: "limit", value: 123, isLabel: false)])
    #expect(program.labels[loop] == 1)
    let config = try PIOConfiguration(program: program, origin: 4,
        input: .init(pinCount: 16, right: false, automatic: true, threshold: 12),
        output: .init(pinCount: 20, right: false, automatic: true, threshold: 24),
        setCount: 3, fifo: .rx, movStatus: .irqSet(6, bank: .next),
        clockDivider: 12.5, sideSetPinDirections: true)
    #expect(config.program == program && config.origin == 4)
    #expect(config.program.sideSet == .init(bits: 2, optional: true))
    #expect(config.sideSetPinDirections)
    #expect(config.clockDividerInteger == 12 && config.clockDividerFraction == 128)
    #expect(program.fifoRequirements == .push)
}

@Test func nativeTypedErrorsRejectInvalidPrograms() {
    let invalid: [[PIOStatement]] = [
        [.instruction(Set(.pins, -1))], [.instruction(Set(.x, 32))],
        [.instruction(In(.pins, 0))], [.instruction(In(.isr, 33))],
        [.instruction(Out(.pins, 0))], [.instruction(Nop().delay(-1))],
        [.instruction(Nop().delay(32))], [.instruction(Nop().sideSet(value: 0))],
        [.instruction(Wait(true, .gpio(32)))], [.instruction(Wait(true, .pin(32)))],
        [.instruction(Wait(true, .irq(8)))], [.instruction(Wait(true, .jmpPin()))],
        [.instruction(Irq(.set, 8))], [.instruction(Irq(.set, 0, mode: .next))],
        [.instruction(Jmp(to: -1))], [.instruction(Jmp(to: 1))],
        [.instruction(Jmp(to: PIOLabelHandle()))],
        [.instruction(Mov(to: .pinDirs, from: .x))],
        [.directive(Wrap())], [.instruction(Nop()), .directive(WrapTarget())],
        [.directive(WrapTarget()), .directive(WrapTarget()), .instruction(Nop())],
        [.instruction(Nop()), .directive(Wrap()), .directive(Wrap())],
        [Define("x", 1), Define("x", 2), .instruction(Nop())],
        [Word(-1)], [Word(65536)],
        Array(repeating: .instruction(Nop()), count: 33),
    ]
    for statements in invalid {
        #expect(throws: PIOAssemblyError.self) { try PIOAssembler.assemble(PIOProgramSource(statements)) }
    }
    @PIOLabel var duplicate
    #expect(throws: PIOAssemblyError.self) {
        try PIOAssembler.assemble { Label(duplicate); Label(duplicate); Nop() }
    }
    let invalidOptions: [(PIOOptions, [PIOStatement])] = [
        (.init(sideSet: .init(bits: 1)), [.instruction(Nop())]),
        (.init(sideSet: .init(bits: 1)), [.instruction(Nop().sideSet(value: 2))]),
        (.init(sideSet: .init(bits: 1)), [.instruction(Nop().sideSet(value: 0).delay(16))]),
        (.init(sideSet: .init(bits: 5, optional: true)), [.instruction(Nop())]),
        (.init(sideSet: .init(bits: -1)), [.instruction(Nop())]),
    ]
    for (options, statements) in invalidOptions {
        #expect(throws: PIOAssemblyError.self) {
            try PIOAssembler.assemble(options: options, PIOProgramSource(statements))
        }
    }
}

@Test func rp2350ValidationRejectsInvalidExtendedOperations() {
    let invalid: [[PIOStatement]] = [
        [.instruction(Wait(true, .gpio(48)))],
        [.instruction(Wait(true, .gpio(0))), .instruction(Wait(true, .gpio(32)))],
        [.instruction(Wait(true, .jmpPin(offset: 4)))],
    ]
    for statements in invalid {
        #expect(throws: PIOAssemblyError.self) {
            try PIOAssembler.assemble(options: .init(version: .rp2350), PIOProgramSource(statements))
        }
    }
    let invalidInstructions: [PIOInstruction] = [
        Mov(to: .rxFIFO(.index(8)), from: .isr),
        Mov(to: .rxFIFO(.y), from: .x),
        Mov(to: .x, from: .rxFIFO(.y)),
    ]
    for instruction in invalidInstructions {
        #expect(throws: PIOAssemblyError.self) {
            try PIOAssembler.assemble(options: .init(version: .rp2350), PIOProgramSource([.instruction(instruction)]))
        }
    }
}

@Test func configurationValidationIsSeparateFromCompilation() throws {
    let program = #constPIO { Nop(); Nop() }
    let invalid: [() throws -> PIOConfiguration] = [
        { try .init(program: program, origin: 31) },
        { try .init(program: program, input: .init(pinCount: 16)) },
        { try .init(program: program, input: .init(pinCount: 32, threshold: 33)) },
        { try .init(program: program, output: .init(pinCount: 33)) },
        { try .init(program: program, output: .init(pinCount: 1, threshold: 0)) },
        { try .init(program: program, setCount: 6) },
        { try .init(program: program, fifo: .txPut) },
        { try .init(program: program, movStatus: .rxLessThan(32)) },
        { try .init(program: program, movStatus: .irqSet(0)) },
        { try .init(program: program, clockDivider: 0.5) },
        { try .init(program: program, clockDivider: .infinity) },
        { try .init(program: program, clockDivider: .nan) },
        { try .init(program: program, clockDivider: 65536) },
        { try .init(program: program, sideSetPinDirections: true) },
        { try .init(program: program, pins: .init(input: -1)) },
        { try .init(program: program, pins: .init(jump: 32)) },
    ]
    for build in invalid { #expect(throws: PIOConfigurationError.self) { try build() } }
    let indexed = #constPIO(version: .rp2350) {
        Mov(to: .rxFIFO(.y), from: .isr); Mov(to: .osr, from: .rxFIFO(.y))
    }
    #expect(indexed.fifoRequirements == [.indexedRead, .indexedWrite])
    for fifo: PIOFIFOJoin in [.txrx, .tx, .rx, .txPut, .txGet] {
        #expect(throws: PIOConfigurationError.self) { try PIOConfiguration(program: indexed, fifo: fifo) }
    }
    _ = try PIOConfiguration(program: indexed, fifo: .putGet)
    #expect(throws: PIOConfigurationError.self) {
        try PIOConfiguration(program: indexed, input: .init(pinCount: 32, automatic: true), fifo: .putGet)
    }
    #expect(throws: PIOConfigurationError.self) { try PIOConfiguration(program: indexed, fifo: .putGet, movStatus: .irqSet(8)) }
    #expect(throws: PIOConfigurationError.self) { try PIOConfiguration(program: indexed, fifo: .putGet, pins: .init(output: 48)) }
    let push = #constPIO { Push() }
    #expect(throws: PIOConfigurationError.self) { try PIOConfiguration(program: push, fifo: .tx) }
    #expect(throws: PIOAssemblyError.self) {
        try PIOAssembler.assemble(options: .init(version: .rp2350)) { Push(); Mov(to: .rxFIFO(.y), from: .isr) }
    }
    let config = try PIOConfiguration(program: program)
    #expect(throws: PIOConfigurationError.self) { try config._validateOffset(31) }
    try config._validateOffset(30)
}

@Test func dynamicBranchesRemainLazyAndThrowTypedErrors() throws {
    var events: [Int] = []
    func read(_ value: Int) -> Int { events.append(value); return value }
    func program(_ flag: Bool, _ value: Int) throws(PIOAssemblyError) -> PIOProgram {
        try #pio {
            if flag { Set(.x, read(value)) } else { Set(.y, read(7)) }
            Nop()
        }
    }
    #expect(try program(false, 99).instructions == [0xe047, 0xa042])
    #expect(events == [7])
    #expect(throws: PIOAssemblyError.self) { try program(true, 99) }
    #expect(events == [7, 99])
}

@Test func compiledProgramsCanBeReusedWithoutInferringPinCounts() throws {
    @PIOLabel var entry
    let program = #constPIO(sideSet: .init(bits: 2, optional: true)) {
        Nop(); WrapTarget(); Label(entry); Out(.pins, 24).sideSet(value: 3); Wrap()
    }
    let first = try PIOConfiguration(program: program)
    let second = try PIOConfiguration(program: program, origin: 7,
        output: .init(pinCount: 6), clockDivider: 2.5, sideSetPinDirections: true)
    #expect(first.program == second.program)
    #expect(first.output == nil && first.setCount == nil)
    #expect(second.output?.pinCount == 6)
    #expect(second.program.wrap == 1 && second.program.wrapTarget == 1)
    #expect(second.program.sideSet == .init(bits: 2, optional: true))
    #expect(second.program.labels[entry] == 1)
    #expect(first.origin == nil && second.origin == 7)
}

@Test func fifoCompatibilityIsCheckedForEveryMode() throws {
    let programs: [(PIOProgram, [PIOFIFOJoin])] = [
        (#constPIO { Push() }, [.txrx, .rx]),
        (#constPIO(version: .rp2350) { Mov(to: .rxFIFO(.y), from: .isr) }, [.txPut, .putGet]),
        (#constPIO(version: .rp2350) { Mov(to: .osr, from: .rxFIFO(.y)) }, [.txGet, .putGet]),
    ]
    for (program, allowed) in programs {
        for mode: PIOFIFOJoin in [.txrx, .tx, .rx, .txPut, .txGet, .putGet] {
            if allowed.contains(mode) { _ = try PIOConfiguration(program: program, fifo: mode) }
            else { #expect(throws: PIOConfigurationError.self) { try PIOConfiguration(program: program, fifo: mode) } }
        }
    }
    let raw = #constPIO { Word(0x8020) }
    #expect(raw.fifoRequirements.isEmpty)
}

@Test func knownBranchesSupportLocalLabelsAndOptionalSelection() {
    let program = #constPIO {
        let enabled = true
        @PIOLabel var loop
        Label(loop)
        if enabled {
            let value = 3
            Set(.x, value)
            if false { Set(.y, 99) } else { Nop() }
        }
        if false { Word(65536) }
        Jmp(to: loop)
    }
    #expect(program.instructions == [0xe023, 0xa042, 0])
}

@Test func partialProgramPreservesInstructionOrderAndRuntimeInputs() throws {
    var events: [Int] = []
    func read(_ value: Int) -> Int { events.append(value); return value }
    let program = try #pio(sideSet: .init(bits: 1, optional: true)) {
        Set(.pins, 1).sideSet(value: 1)
        let value = read(3)
        if true { Set(.x, value) } else { Set(.y, read(99)) }
        Nop().delay(7)
        Set(.y, read(5))
    }
    #expect(program.instructions == [0xf801, 0xe023, 0xa742, 0xe045])
    #expect(events == [3, 5])
}
