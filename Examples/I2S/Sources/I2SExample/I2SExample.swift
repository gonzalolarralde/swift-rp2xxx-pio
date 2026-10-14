import RP2xxxPIO

@main
enum I2SExample {
    static func main() {
        @PIOLabel var entryPoint

        // Two 16-bit channels. Side-set drives BCLK on bit 0 and LRCLK on bit 1.
        let program = #constPIO(sideSet: .init(bits: 2)) {
            @PIOLabel var bitloop0
            @PIOLabel var bitloop1

            Label(bitloop1)
            Out(.pins, 1).sideSet(value: 0b10)
            Jmp(.xDecrement, to: bitloop1).sideSet(value: 0b11)
            Out(.pins, 1).sideSet(value: 0b00)
            Set(.x, 14).sideSet(value: 0b01)

            Label(bitloop0)
            Out(.pins, 1).sideSet(value: 0b00)
            Jmp(.xDecrement, to: bitloop0).sideSet(value: 0b01)
            Out(.pins, 1).sideSet(value: 0b10)

            Label(entryPoint)
            Set(.x, 14).sideSet(value: 0b11)
        }

        print("I2S: \(program.instructions.count) instructions, entry point \(program.labels[entryPoint]!)")
        print("Instructions: " + program.instructions.map { String($0, radix: 16) }.joined(separator: " "))
    }
}
