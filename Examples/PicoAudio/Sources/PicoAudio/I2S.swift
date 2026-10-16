import CPicoSDK
import RP2xxxPIO

/// A non-owning handle to a caller-supplied state machine and loaded program.
/// Copies refer to the same hardware. No resources are claimed, loaded, or released.
struct I2S {
    let pio: PIO
    let sm: UInt32
    let offset: UInt32

    /// An inert program value, available before constructing a hardware handle.
    struct Program: PIOProgram {
        var clockDivider: Double = 1
        var pins: PIOPinMapping = .init()

        // One serial data pin, MSB first, pulling a stereo frame every 32 bits.
        var output: PIOShiftConfiguration? {
            .init(pinCount: 1, right: false, automatic: true, threshold: 32)
        }
        var fifo: PIOFIFOJoin { .tx }
        var code: PIOProgramData { Self.compiledCode }
        var entryPoint: PIOLabelHandle { Self.entryLabel }

        // Share the immutable instruction/label storage across program instances.
        private static let entryLabel = PIOLabelHandle()
        private static let compiledCode = #constPIO(sideSet: .init(bits: 2)) {
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

            Label(entryLabel)
            Set(.x, 14).sideSet(value: 0b11)
        }
    }

    /// Configures and starts the supplied SM. The caller must have claimed it and
    /// loaded `Program` at `offset`; neither operation is performed here.
    init(
        pio: PIO, sm: UInt32, offset: UInt32,
        dataPin: UInt32, clockPin: UInt32, sampleRate: UInt32
    ) throws(PicoAudioError) {
        guard sm < UInt32(NUM_PIO_STATE_MACHINES) else {
            throw .invalidHardware("State-machine index is out of range")
        }
        guard sampleRate > 0 else { throw .invalidHardware("Sample rate must be positive") }
        let pins = try Pins(data: dataPin, clock: clockPin)
        // Two instructions per bit × 16 bits × two channels = 64 PIO cycles/frame.
        // Convert before multiplying so even invalid large rates cannot overflow.
        let divider = Double(clock_get_hz(clk_sys)) / (Double(sampleRate) * 64)
        let program = Program(clockDivider: divider, pins: .init(output: Int(dataPin), sideSet: Int(clockPin)))
        var config: pio_sm_config
        do {
            config = try program.defaultConfig(offset: offset)
        } catch {
            throw .configuration(error)
        }
        guard let entry = program.offset(of: program.entryPoint) else {
            throw .invalidHardware("I2S program is missing its entry label")
        }

        pins.initialize(on: pio)
        let status = pio_sm_init(pio, sm, offset + UInt32(entry), &config)
        guard status == 0 else { throw .stateMachineInitializationFailed(status) }
        try pins.configureOutputs(on: pio, sm: sm)
        pio_sm_put_blocking(pio, sm, 0) // Start with a silent frame.
        pio_sm_set_enabled(pio, sm, true)

        self.pio = pio
        self.sm = sm
        self.offset = offset
    }

    func write(_ frame: UInt32) {
        pio_sm_put_blocking(pio, sm, frame)
    }
}

private extension I2S {
    struct Pins {
        let data: UInt32
        let clock: UInt32

        init(data: UInt32, clock: UInt32) throws(PicoAudioError) {
            // This example targets Pico 2's GP0...GP29. LRCLK follows BCLK.
            guard data < 30, clock < 29, data != clock, data != clock + 1 else {
                throw .invalidHardware("I2S needs distinct Pico GPIOs; BCLK and LRCLK must be consecutive")
            }
            self.data = data
            self.clock = clock
        }

        func initialize(on pio: PIO) {
            pio_gpio_init(pio, data)
            pio_gpio_init(pio, clock)
            pio_gpio_init(pio, clock + 1)
        }

        func configureOutputs(on pio: PIO, sm: UInt32) throws(PicoAudioError) {
            pio_sm_set_pins_with_mask(pio, sm, 0, (1 << data) | (3 << clock))
            let dataStatus = pio_sm_set_consecutive_pindirs(pio, sm, data, 1, true)
            guard dataStatus == 0 else { throw .pinDirectionSetupFailed(dataStatus) }
            let clockStatus = pio_sm_set_consecutive_pindirs(pio, sm, clock, 2, true)
            guard clockStatus == 0 else { throw .pinDirectionSetupFailed(clockStatus) }
        }
    }
}
