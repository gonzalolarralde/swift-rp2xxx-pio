import RP2xxxPIO
import Testing

@Test func capturedLabelsBelongToEachProgram() throws {
    @PIOLabel var entry
    let first = #constPIO { Label(entry); Nop() }
    let second = #constPIO { Nop(); Label(entry); Nop() }
    let ordinary = try #pio { Nop(); Label(entry); Jmp(to: entry) }
    #expect(first.labels[entry] == 0)
    #expect(second.labels[entry] == 1 && ordinary.labels[entry] == 1)
    #expect(ordinary.instructions == [0xa042, 1])
    @PIOLabel var unrelated
    #expect(first.labels[unrelated] == nil)
}

@Test func localLabelScopesAndAliasesRemainDistinct() {
    let program = #constPIO {
        @PIOLabel var loop
        Label(loop)
        Nop()
        if true {
            @PIOLabel var loop
            let alias = loop
            Label(alias)
            Jmp(to: loop)
        }
        Jmp(to: loop)
    }
    #expect(program.instructions == [0xa042, 1, 0])
    #expect(program.labels.isEmpty)
}

@Test func capturedAliasesInsideBodyUseOneBinding() {
    @PIOLabel var entry
    let program = #constPIO {
        let alias = entry
        Jmp(to: alias)
        Label(entry)
        Nop()
    }
    #expect(program.instructions == [1, 0xa042])
    #expect(program.labels[entry] == 1 && program.labels.count == 1)
}

@Test func runtimeLabelAliasesAreNotGuessedByTheMacro() throws {
    @PIOLabel var entry
    let alias = entry
    // The macro cannot prove that these outer names are aliases. Ordinary
    // assembly must fall back and use their real identities, without patching
    // an instruction after claiming it was a compile-time constant.
    let program = try #pio { Label(entry); Nop(); Jmp(to: alias) }
    #expect(program.instructions == [0xa042, 0])
    #expect(program.labels[alias] == 0)
    #expect(throws: PIOAssemblyError.self) {
        _ = try #pio { Label(entry); Nop(); Label(alias); Nop() }
    }
}

@Test func dynamicEncodingOptionsRunBeforeBodyExactlyOnce() throws {
    var events: [Int] = []
    func read(_ value: Int) -> Int { events.append(value); return value }
    @PIOLabel var entry
    let program = try #pio(sideSet: .init(bits: read(1), optional: true)) {
        @PIOLabel var loop
        Label(loop)
        Label(entry)
        Set(.x, read(3))
        Jmp(to: loop).sideSet(value: 1)
    }
    #expect(events == [1, 3])
    #expect(program.instructions == [0xe023, 0x1800])
    #expect(program.labels[entry] == 0)
}

@Test func externalLabelBindingDoesNotEvaluateAnUnselectedCapture() {
    @PIOLabel var entry
    let program = #constPIO {
        if false { Label(entry); Set(.x, 99) }
        Nop()
    }
    #expect(program.labels[entry] == nil)
    #expect(program.instructions == [0xa042])
}

@Test func repeatedDeclarationsCreateFreshHandles() {
    func make() -> (PIOProgramData, PIOLabelHandle) {
        @PIOLabel var entry
        return (#constPIO { Label(entry); Jmp(to: entry) }, entry)
    }
    let (first, firstEntry) = make()
    let (second, secondEntry) = make()
    #expect(firstEntry != secondEntry)
    #expect(first.labels[firstEntry] == 0 && first.labels[secondEntry] == nil)
    #expect(second.labels[secondEntry] == 0 && second.labels[firstEntry] == nil)
}

@Test func dynamicConfigurationDoesNotPreventConstantCompilation() throws {
    var events: [Double] = []
    func clock() -> Double { events.append(2.5); return 2.5 }
    let program = #constPIO { Set(.x, 3); Nop() }
    let config = try PIOConfiguration(program: program, clockDivider: clock())
    #expect(events == [2.5])
    #expect(program.instructions == [0xe023, 0xa042])
    #expect(config.clockDividerInteger == 2)
    #expect(config.clockDividerFraction == 128)
}
