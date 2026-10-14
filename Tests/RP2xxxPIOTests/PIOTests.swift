import RP2xxxPIO
import Testing

@Test func nativeInstructionFamilies() throws {
    @PIOLabel var loop
    let program = try PIOAssembler.assemble {
        Label(loop)
        Set(.x, 31)
        Wait(true, .pin(2))
        In(.pins, 32)
        Out(.x, 8)
        Push()
        Pull()
        Mov(to: .y, from: .x, operation: .invert)
        Irq(.wait, 3, mode: .relative)
        Nop()
        Jmp(.xDecrement, to: loop)
    }
    #expect(program.instructions == [0xe03f, 0x20a2, 0x4000, 0x6028, 0x8020, 0x80a0, 0xa049, 0xc033, 0xa042, 0x0040])
    #expect(program.wrap == 9)
    #expect(program.labels[loop] == 0)
}

@Test func constantMacroUsesNativeAssembler() throws {
    let constant = #constPIO {
        @PIOLabel var loop
        Label(loop)
        Set(.pins, 1).delay(3)
        Jmp(to: loop)
    }
    let ordinary = try #pio { Set(.pins, 1).delay(3); Jmp(to: 0) }
    #expect(constant == ordinary)
    #expect(constant.instructions == [0xe301, 0x0000])
}
