import RP2xxxPIO

@main
enum PIOExample {
    static func main() throws {
        @PIOLabel var entry
        let program = #constPIO(sideSet: .init(bits: 1, optional: true)) {
            @PIOLabel var loop
            Label(entry)
            Label(loop)
            WrapTarget()
            Set(.pins, 1).sideSet(value: 1).delay(7)
            Set(.pins, 0).sideSet(value: 0).delay(7)
            Jmp(to: loop)
            Wrap()
        }

        // Configuration is ordinary host-safe data; it does not access hardware.
        let setup = try PIOConfiguration(program: program, setCount: 1,
            clockDivider: 2.5, pins: .init(set: 25, sideSet: 25))
        print("Compiled words: \(hex(program.instructions))")
        print("Entry offset: \(program.labels[entry]!)")
        print("Wrap: \(setup.program.wrapTarget)...\(setup.program.wrap)")
        print("Clock divider: \(setup.clockDividerInteger) + \(setup.clockDividerFraction)/256")

        // A command-line operand demonstrates runtime assembly and typed errors.
        let value = CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 7
        do {
            let dynamic = try #pio { Set(.x, value); Jmp(to: 0) }
            print("Runtime words (value \(value)): \(hex(dynamic.instructions))")
        } catch {
            print("Runtime assembly rejected value \(value): \(error)")
        }
    }

    private static func hex(_ words: [UInt16]) -> String {
        words.map {
            let digits = String($0, radix: 16)
            return "0x" + String(repeating: "0", count: 4 - digits.count) + digits
        }.joined(separator: " ")
    }
}
