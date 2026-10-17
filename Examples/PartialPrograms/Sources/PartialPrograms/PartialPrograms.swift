import RP2xxxPIO

@main
enum PartialPrograms {
    // Parameters remain runtime inputs even when callers happen to pass literals.
    // Inspect this macro's expansion to see UInt16 constants mixed with Out,
    // Set, Jmp, labels, and the original Swift conditional/switch.
    static func serial(count: Int, side: Int, extra: Bool, mode: Int) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio(sideSet: .init(bits: 2)) {
            @PIOLabel var loop
            WrapTarget()
            Label(loop)
            Out(.pins, 1).sideSet(value: 2)      // Precompiled.
            Out(.pins, count).sideSet(value: 0) // Runtime operand.
            Set(.x, 14).sideSet(value: side)    // Runtime side-set.
            if extra {
                Set(.y, 7).sideSet(value: 1)    // Precompiled, conditionally present.
            }
            switch mode {
            case 0: Nop().sideSet(value: 0)
            default: Out(.x, 32).sideSet(value: 3)
            }
            Jmp(.xDecrement, to: loop).sideSet(value: 1)
            Wrap()
        }
    }

    static func metadata(upperGPIOs: Bool, indexedFIFO: Bool) throws(PIOAssemblyError) -> PIOProgramData {
        try #pio(version: .rp2350) {
            if upperGPIOs { Wait(true, .gpio(47)) } else { Wait(true, .gpio(0)) }
            if indexedFIFO {
                Mov(to: .rxFIFO(.index(7)), from: .isr)
                Mov(to: .osr, from: .rxFIFO(.y))
            } else { Push() }
        }
    }

    static func main() throws {
        for extra in [false, true] {
            let program = try serial(count: 16, side: 3, extra: extra, mode: extra ? 1 : 0)
            print("extra=\(extra): " + program.instructions.map { String($0, radix: 16) }.joined(separator: " "))
        }
        let program = try metadata(upperGPIOs: true, indexedFIFO: true)
        print("GPIO ranges=\(program.usedGPIORanges), FIFO requirements=\(program.fifoRequirements.rawValue)")
        _ = try PIOConfiguration(program: program, fifo: .putGet)
        do {
            _ = try serial(count: 33, side: 3, extra: false, mode: 0)
            preconditionFailure("invalid count was accepted")
        } catch { print("Runtime validation: \(error)") }
        let raw = #constPIO { UInt16(0xa042) }
        print("Explicit encoded word: \(String(raw.instructions[0], radix: 16))")
    }
}
