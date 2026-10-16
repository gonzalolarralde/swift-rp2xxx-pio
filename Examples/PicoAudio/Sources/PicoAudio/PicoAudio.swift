import CPicoSDK
import RP2xxxPIO

@main
enum PicoAudio {
    static func main() {
        stdio_init_all()
        do {
            try run()
        } catch {
            print("PicoAudio setup failed: \(error.description)")
        }
        // Setup failure is reported once. Do not start sending to an invalid SM.
        while true { tight_loop_contents() }
    }

    private static func run() throws(PicoAudioError) {
        let dataPin: UInt32 = 2
        let clockPin: UInt32 = 3  // BCLK; LRCLK is the next GPIO.
        let sampleRate: UInt32 = 48_000

        guard let pio = pio0 else { throw .invalidHardware("PIO0 is unavailable") }
        // The caller owns resource allocation; I2S.init neither claims nor loads.
        let sm = try claimStateMachine(on: pio)
        let offset = try I2S.Program().addProgram(to: pio)
        let audio = try I2S(
            pio: pio, sm: sm, offset: offset,
            dataPin: dataPin, clockPin: clockPin, sampleRate: sampleRate
        )

        var random = get_rand_32() | 1
        print("PicoAudio: \(sampleRate) Hz stereo noise — DATA GP\(dataPin), BCLK GP\(clockPin), LRCLK GP\(clockPin + 1)")

        while true {
            // Xorshift noise, attenuated to about 3% of full-scale amplitude.
            random ^= random << 13
            random ^= random >> 17
            random ^= random << 5
            let right = Int16(truncatingIfNeeded: random >> 16) >> 5
            let left = Int16(truncatingIfNeeded: random) >> 5

            // Entry starts channel 1 (right), followed by channel 0 (left).
            let frame = UInt32(UInt16(bitPattern: right)) << 16 | UInt32(UInt16(bitPattern: left))
            audio.write(frame)
        }
    }
}
