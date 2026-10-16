// Compiled by PIOSDKTests beside the actual PicoAudio sources. Only hardware
// operations are replaced here; SDK types/config setters and PIO code are real.
import CPicoSDK
import RP2xxxPIO

private final class HardwareCalls {
    var events: [String] = []
    var loadResult: Int32 = 7
    var claimResult: Int32 = 2
    var initializationResult: Int32 = 0
    var directionResult: Int32 = 0
    var loadedWords: [UInt16] = []
    var initialConfig: pio_sm_config?
}

// Each standalone test executable is synchronous and has its own state.
nonisolated(unsafe) private var hardware = HardwareCalls()

func pio_add_program(_ pio: PIO, _ program: UnsafePointer<pio_program_t>) -> Int32 {
    hardware.events.append("load")
    hardware.loadedWords = Array(UnsafeBufferPointer(start: program.pointee.instructions, count: Int(program.pointee.length)))
    return hardware.loadResult
}

func pio_claim_unused_sm(_ pio: PIO, _ required: Bool) -> Int32 {
    precondition(!required, "Claim failures must be returned, not asserted by the SDK")
    hardware.events.append("claim")
    return hardware.claimResult
}

func clock_get_hz(_ clock: clock_handle_t) -> UInt32 { 150_000_000 }

func pio_gpio_init(_ pio: PIO, _ pin: UInt32) {
    hardware.events.append("gpio:\(pin)")
}

func pio_sm_init(_ pio: PIO, _ sm: UInt32, _ pc: UInt32, _ config: UnsafePointer<pio_sm_config>) -> Int32 {
    hardware.events.append("init:\(sm):\(pc)")
    hardware.initialConfig = config.pointee
    return hardware.initializationResult
}

func pio_sm_set_pins_with_mask(_ pio: PIO, _ sm: UInt32, _ values: UInt32, _ mask: UInt32) {
    hardware.events.append("pins:\(sm):\(values):\(mask)")
}

func pio_sm_set_consecutive_pindirs(_ pio: PIO, _ sm: UInt32, _ base: UInt32, _ count: UInt32, _ output: Bool) -> Int32 {
    precondition(output)
    hardware.events.append("directions:\(sm):\(base):\(count)")
    return hardware.directionResult
}

func pio_sm_put_blocking(_ pio: PIO, _ sm: UInt32, _ value: UInt32) {
    hardware.events.append("write:\(sm):\(value)")
}

func pio_sm_set_enabled(_ pio: PIO, _ sm: UInt32, _ enabled: Bool) {
    hardware.events.append("enable:\(sm):\(enabled)")
}

func checkPicoAudioHardwareBoundary() throws {
    // No shim dereferences this pointer. Real MMIO functions must never run here.
    let pio = UnsafeMutablePointer<pio_hw_t>.allocate(capacity: 1)
    defer { pio.deallocate() }
    hardware = HardwareCalls()
    let program = I2S.Program()
    let loadedOffset = try program.addProgram(to: pio)
    precondition(loadedOffset == 7 && hardware.events == ["load"])
    precondition(hardware.loadedWords == [0x7001, 0x1840, 0x6001, 0xe82e, 0x6001, 0x0844, 0x7001, 0xf82e])
    for result: Int32 in [-1, -17, .min] {
        hardware.loadResult = result
        do { _ = try program.addProgram(to: pio); fatalError("negative loader result accepted") }
        catch { precondition(error == .programLoadFailed(result)) }
    }
    hardware.events = []
    var invalidProgram = program
    invalidProgram.clockDivider = .nan
    do { _ = try invalidProgram.addProgram(to: pio); fatalError("invalid program loaded") }
    catch {
        guard case .configuration = error else { fatalError("wrong validation error") }
        precondition(hardware.events.isEmpty)
    }

    hardware = HardwareCalls()
    let claimed = try claimStateMachine(on: pio)
    precondition(claimed == 2 && hardware.events == ["claim"])
    hardware.claimResult = -1
    do { _ = try claimStateMachine(on: pio); fatalError("negative claim result accepted") }
    catch { precondition(error == .noStateMachine) }

    hardware = HardwareCalls()
    let audio = try I2S(pio: pio, sm: 2, offset: 7, dataPin: 2, clockPin: 3, sampleRate: 48_000)
    precondition(audio.pio == pio && audio.sm == 2 && audio.offset == 7)
    // In particular, no "claim" or "load" event may occur inside init.
    precondition(hardware.events == ["gpio:2", "gpio:3", "gpio:4", "init:2:14", "pins:2:0:28",
        "directions:2:2:1", "directions:2:3:2", "write:2:0", "enable:2:true"])
    guard var actual = hardware.initialConfig else { fatalError("configuration not supplied") }
    var expected = pio_get_default_sm_config()
    sm_config_set_wrap(&expected, 7, 14)
    sm_config_set_out_pin_count(&expected, 1)
    sm_config_set_out_shift(&expected, false, true, 32)
    sm_config_set_fifo_join(&expected, PIO_FIFO_JOIN_TX)
    sm_config_set_sideset(&expected, 2, false, false)
    sm_config_set_clkdiv_int_frac(&expected, 48, 212)
    sm_config_set_out_pin_base(&expected, 2)
    sm_config_set_sideset_pin_base(&expected, 3)
    precondition(withUnsafeBytes(of: &actual) { Array($0) } == withUnsafeBytes(of: &expected) { Array($0) })
    hardware.events = []
    audio.write(0x12345678)
    precondition(hardware.events == ["write:2:305419896"])

    let invalidInputs: [(UInt32, UInt32, UInt32, UInt32, UInt32)] = [
        (4, 7, 2, 3, 48_000), (2, 31, 2, 3, 48_000), (2, .max, 2, 3, 48_000),
        (2, 7, 3, 3, 48_000), (2, 7, 4, 3, 48_000), (2, 7, 30, 3, 48_000),
        (2, 7, 2, 29, 48_000), (2, 7, 2, .max, 48_000), (2, 7, 2, 3, 0), (2, 7, 2, 3, .max),
    ]
    for (sm, offset, dataPin, clockPin, rate) in invalidInputs {
        hardware = HardwareCalls()
        do {
            _ = try I2S(pio: pio, sm: sm, offset: offset, dataPin: dataPin, clockPin: clockPin, sampleRate: rate)
            fatalError("invalid hardware settings accepted")
        } catch { precondition(hardware.events.isEmpty, "invalid input touched hardware") }
    }

    hardware = HardwareCalls()
    hardware.initializationResult = -4
    do { _ = try I2S(pio: pio, sm: 2, offset: 7, dataPin: 2, clockPin: 3, sampleRate: 48_000); fatalError("failed init accepted") }
    catch { precondition(error == .stateMachineInitializationFailed(-4)) }
    precondition(hardware.events == ["gpio:2", "gpio:3", "gpio:4", "init:2:14"])
    hardware = HardwareCalls()
    hardware.directionResult = -5
    do { _ = try I2S(pio: pio, sm: 2, offset: 7, dataPin: 2, clockPin: 3, sampleRate: 48_000); fatalError("failed pin setup accepted") }
    catch { precondition(error == .pinDirectionSetupFailed(-5)) }
    precondition(!hardware.events.contains(where: { $0.hasPrefix("write:") || $0.hasPrefix("enable:") }))
    print("PicoAudio hardware-boundary and error checks passed")
}
