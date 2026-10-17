import RP2xxxPIO
import Testing

@Test func uint16WordsMixWithInstructionsLabelsAndMandatorySideSet() throws {
    @PIOLabel var entry
    let word: UInt16 = 0x7001
    let native = try PIOAssembler.assemble(options: .init(sideSet: .init(bits: 2))) {
        word
        Label(entry)
        Set(.x, 14).sideSet(value: 1)
        Jmp(to: entry).sideSet(value: 3)
    }
    let partial = try #pio(sideSet: .init(bits: 2)) {
        word
        Label(entry)
        Set(.x, 14).sideSet(value: 1)
        Jmp(to: entry).sideSet(value: 3)
    }
    let constant = #constPIO(sideSet: .init(bits: 2)) {
        UInt16(0x7001)
        Label(entry)
        Set(.x, 14).sideSet(value: 1)
        Jmp(to: entry).sideSet(value: 3)
    }
    #expect(native == partial && partial == constant)
    #expect(partial.instructions == [0x7001, 0xe82e, 0x1801])
    #expect(partial.labels[entry] == 1)
    // Explicit raw words remain opaque, like Word; compiler-produced encoded
    // instructions carry source metadata separately (tested below).
    #expect((#constPIO { UInt16(0x8020) }).fifoRequirements.isEmpty)
    #expect(throws: PIOAssemblyError.self) {
        try PIOAssembler.assemble(options: .init(sideSet: .init(bits: 1))) { Word(0) }
    }
    #expect(throws: PIOAssemblyError.self) {
        try PIOAssembler.assemble(PIOProgramSource(Array(repeating: .encoded(0, gpioRanges: 0, fifo: 0), count: 33)))
    }
}

@Test func partialCompilationMatchesNativeAcrossDynamicOperandsAndBranches() throws {
    @PIOLabel var entry
    func macro(_ mode: Int, _ count: Int, _ side: Int, _ delay: Int) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio(sideSet: .init(bits: 2, optional: true)) {
            Define("limit", 31, isPublic: true)
            WrapTarget()
            Nop()
            if mode != 0 { Out(.pins, 1).sideSet(value: 2) }
            Out(.pins, count).sideSet(value: 1)
            Label(entry)
            Set(.x, 14).sideSet(value: side).delay(delay)
            switch mode {
            case 0: Nop().delay(2)
            case 1: Out(.x, 32); Set(.y, 7)
            default: Nop()
            }
            Wrap()
            Jmp(.xDecrement, to: entry)
        }
    }
    func native(_ mode: Int, _ count: Int, _ side: Int, _ delay: Int) throws(PIOAssemblyError) -> PIOProgramData {
        try PIOAssembler.assemble(options: .init(sideSet: .init(bits: 2, optional: true))) {
            Define("limit", 31, isPublic: true)
            WrapTarget()
            Nop()
            if mode != 0 { Out(.pins, 1).sideSet(value: 2) }
            Out(.pins, count).sideSet(value: 1)
            Label(entry)
            Set(.x, 14).sideSet(value: side).delay(delay)
            switch mode {
            case 0: Nop().delay(2)
            case 1: Out(.x, 32); Set(.y, 7)
            default: Nop()
            }
            Wrap()
            Jmp(.xDecrement, to: entry)
        }
    }
    for mode in 0...2 {
        for count in [0, 1, 16, 32, 33] {
            for side in [-1, 0, 3, 4] {
                for delay in [-1, 0, 3, 4] {
                    #expect(outcome { try macro(mode, count, side, delay) } == outcome { try native(mode, count, side, delay) })
                }
            }
        }
    }
}

@Test func foldedGPIOMetadataCombinesWithDynamicInstructionsInEitherOrder() throws {
    func program(_ gpio: Int, _ upperFirst: Bool) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio(version: .rp2350) {
            if upperFirst { Wait(true, .gpio(47)) }
            Wait(false, .gpio(gpio))
            if !upperFirst { Wait(true, .gpio(47)) }
            Nop()
        }
    }
    for first in [false, true] {
        for gpio in [0, 15, 16, 31, 32, 47, 48] {
            let native = outcome {
                try PIOAssembler.assemble(options: .init(version: .rp2350)) {
                    if first { Wait(true, .gpio(47)) }
                    Wait(false, .gpio(gpio))
                    if !first { Wait(true, .gpio(47)) }
                    Nop()
                }
            }
            #expect(outcome { try program(gpio, first) } == native)
        }
    }
    #expect(try program(16, true).usedGPIORanges == 6)
    #expect(try program(47, false).usedGPIORanges == 4)
}

@Test func foldedMetadataOnlyIncludesSelectedBranches() throws {
    func program(_ upper: Bool, _ indexed: Bool) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio(version: .rp2350) {
            if upper { Wait(true, .gpio(47)) } else { Wait(true, .gpio(0)) }
            if indexed {
                Mov(to: .rxFIFO(.index(7)), from: .isr)
                Mov(to: .osr, from: .rxFIFO(.y))
            } else { Push() }
        }
    }
    for upper in [false, true] {
        for indexed in [false, true] {
            let value = try program(upper, indexed)
            #expect(value.usedGPIORanges == (upper ? 4 : 1))
            #expect(value.fifoRequirements == (indexed ? [.indexedRead, .indexedWrite] : .push))
            _ = try PIOConfiguration(program: value, fifo: indexed ? .putGet : .rx)
            #expect(throws: PIOConfigurationError.self) { try PIOConfiguration(program: value, fifo: .tx) }
        }
    }
}

@Test func foldedFIFORequirementsStillRejectCrossInstructionConflicts() throws {
    func program(_ index: Int, _ pushFirst: Bool) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio(version: .rp2350) {
            if pushFirst { Push() }
            Mov(to: .rxFIFO(.index(index)), from: .isr)
            if !pushFirst { Push() }
        }
    }
    for first in [false, true] {
        #expect(outcome { try program(3, first) } == .failure(.invalidConfiguration("Push and indexed RX FIFO moves require incompatible FIFO modes")))
    }
    func dynamicPush(_ conditional: Bool) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio(version: .rp2350) {
            Mov(to: .osr, from: .rxFIFO(.y))
            Push(ifFull: conditional)
        }
    }
    #expect(throws: PIOAssemblyError.self) { try dynamicPush(false) }
    #expect(throws: PIOAssemblyError.self) { try dynamicPush(true) }
}

@Test func partialCompilationPreservesEffectsLazinessAndLabelIdentity() throws {
    var events: [Int] = []
    func read(_ value: Int) -> Int { events.append(value); return value }
    func flag(_ value: Bool) -> Bool { events.append(value ? 10 : 20); return value }
    @PIOLabel var entry
    let alias = entry
    func program(_ extra: Bool) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio(sideSet: .init(bits: 1, optional: true)) {
            @PIOLabel var loop
            Label(loop)
            Out(.pins, 1)
            if flag(extra) {
                @PIOLabel var loop
                Label(loop)
                Set(.x, read(3))
                Jmp(to: loop)
            } else { Nop().sideSet(value: read(1)) }
            Label(entry)
            Set(.y, read(7))
            Jmp(to: alias)
            Jmp(to: loop)
        }
    }
    let first = try program(false)
    #expect(first.instructions == [0x6001, 0xb842, 0xe047, 2, 0])
    #expect(first.labels[entry] == 2)
    #expect(events == [20, 1, 7])
    events = []
    let second = try program(true)
    #expect(second.instructions == [0x6001, 0xe023, 1, 0xe047, 3, 0])
    #expect(second.labels[entry] == 3)
    #expect(events == [10, 3, 7])
}

@Test func partialCompilationRetainsInvalidBranchAndNumericJumpValidation() throws {
    func invalidBranch(_ selected: Bool) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio { if selected { Set(.x, 99) }; Nop() }
    }
    #expect(try invalidBranch(false).instructions == [0xa042])
    #expect(outcome { try invalidBranch(true) } == .failure(.operandOutOfRange(name: "SET value", value: 99, minimum: 0, maximum: 31)))
    func numericJump(_ extra: Bool) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio { Jmp(to: 2); if extra { Nop() }; Nop() }
    }
    #expect(try numericJump(true).instructions == [2, 0xa042, 0xa042])
    #expect(outcome { try numericJump(false) } == .failure(.operandOutOfRange(name: "jump target", value: 2, minimum: 0, maximum: 1)))
}

@Test func partialCompilationHandlesNestedConstantsAndPatternShadows() throws {
    func program(_ input: Int?, _ mode: Int) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio {
            let count = 3
            Out(.pins, count)
            if let count = input { Out(.pins, count) } else { Out(.pins, count) }
            switch mode {
            case 0:
                let count = 7
                Out(.pins, count)
            case let count where count > 0: Out(.pins, count)
            default: Nop()
            }
        }
    }
    #expect(try program(nil, 0).instructions == [0x6003, 0x6003, 0x6007])
    #expect(try program(8, 5).instructions == [0x6003, 0x6008, 0x6005])
    #expect(try program(32, -1).instructions == [0x6003, 0x6000, 0xa042])
    #expect(throws: PIOAssemblyError.self) { try program(33, 0) }
}

@Test func partialCompilationKeepsConditionalLabelErrorsAndInstructionLimit() throws {
    @PIOLabel var target
    func labels(_ defined: Bool, _ duplicate: Bool) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio {
            Jmp(to: target)
            if defined { Label(target); Nop() }
            if duplicate { Label(target); Nop() }
        }
    }
    #expect(throws: PIOAssemblyError.self) { try labels(false, false) }
    #expect(throws: PIOAssemblyError.self) { try labels(true, true) }
    #expect(try labels(true, false).instructions == [1, 0xa042])
    #expect(try labels(false, true).instructions == [1, 0xa042])
    func length(_ extra: Bool) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio {
            Nop(); Nop(); Nop(); Nop(); Nop(); Nop(); Nop(); Nop()
            Nop(); Nop(); Nop(); Nop(); Nop(); Nop(); Nop(); Nop()
            Nop(); Nop(); Nop(); Nop(); Nop(); Nop(); Nop(); Nop()
            Nop(); Nop(); Nop(); Nop(); Nop(); Nop(); Nop(); Nop()
            if extra { UInt16(0xa042) }
        }
    }
    #expect(try length(false).instructions.count == 32)
    #expect(outcome { try length(true) } == .failure(.invalidStructure("a program may contain at most 32 instructions")))
}

@Test func partialCompilationPreservesDynamicVersionValidation() throws {
    func program(_ version: PIOVersion) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio(version: version) {
            Nop()
            Mov(to: .rxFIFO(.y), from: .isr)
            Wait(true, .gpio(47))
        }
    }
    let value = try program(.rp2350)
    #expect(value.instructions == [0xa042, 0x8010, 0x208f])
    #expect(value.usedGPIORanges == 4 && value.fifoRequirements == .indexedWrite)
    #expect(throws: PIOAssemblyError.self) { try program(.rp2040) }
}

private func outcome(_ body: () throws -> PIOProgramData) -> Result<PIOProgramData, PIOAssemblyError> {
    do { return .success(try body()) }
    catch let error as PIOAssemblyError { return .failure(error) }
    catch {
        Issue.record("Unexpected error type: \(error)")
        return .failure(.invalidStructure("unexpected error type"))
    }
}
