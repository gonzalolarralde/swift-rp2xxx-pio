import CPicoSDK
import RP2xxxPIO

// Deliberately includes constant folding, runtime assembly, typed error handling,
// and both SDK adapters in the linked firmware. Building never flashes a board.
@_cdecl("pio_dynamic_probe")
public func dynamicProbe(_ value: Int32) -> UInt16 {
    do {
        let program = try #pio {
            if value >= 0 { Set(.x, Int(value)) } else { Set(.y, 0) }
            Nop()
        }
        return program.instructions[0]
    } catch {
        switch error {
        case .operandOutOfRange: return 0xffff
        default: return 0xfffe
        }
    }
}

@_cdecl("main")
public func firmwareMain() -> Int32 {
    @PIOLabel var entryPoint
    let program = #constPIO(
        sideSet: .init(bits: 1, optional: true)
    ) {
        @PIOLabel var loop
        Label(entryPoint)
        Label(loop)
        WrapTarget()
        if true { Set(.pins, 1).sideSet(value: 1).delay(7) }
        Set(.pins, 0).sideSet(value: 0).delay(7)
        Wrap()
    }
    let folded = try! #pio { Nop() }
    let setup = try! PIOConfiguration(program: program, output: .init(pinCount: 1, automatic: true, threshold: 32))
    let config = try! #pioConfig(program: program, offset: 0, output: .init(pinCount: 1, automatic: true, threshold: 32))
    let native = try! setup.defaultConfig(offset: 0)
    precondition(config.pinctrl == native.pinctrl && config.shiftctrl == native.shiftctrl)
    precondition(config.clkdiv == 0x10000)
    let count = program.withCProgram { Int($0.pointee.length) }
    precondition(count == 2 && folded.instructions[0] == 0xa042 && program.labels[entryPoint] == 0)
    precondition(dynamicProbe(32) == 0xffff)
    precondition(dynamicProbe(3) == 0xe023)
    let runtimeValue = Int32(time_us_32() & 31)
    precondition(dynamicProbe(runtimeValue) == 0xe020 | UInt16(runtimeValue))
    while true { tight_loop_contents() }
}
