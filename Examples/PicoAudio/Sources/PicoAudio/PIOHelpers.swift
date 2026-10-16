import CPicoSDK
import RP2xxxPIO

enum PicoAudioError: Error, Equatable, CustomStringConvertible {
    case configuration(PIOConfigurationError)
    case invalidHardware(String)
    case noStateMachine
    case programLoadFailed(Int32)
    case stateMachineInitializationFailed(Int32)
    case pinDirectionSetupFailed(Int32)

    var description: String {
        switch self {
        case .configuration(let error):
            switch error {
            case .operandOutOfRange(let name, let value, let minimum, let maximum):
                return "\(name) \(value) is outside \(minimum)...\(maximum)"
            case .unsupportedFeature(let message), .invalidConfiguration(let message):
                return message
            }
        case .invalidHardware(let message): return message
        case .noStateMachine: return "No unused PIO state machine"
        case .programLoadFailed(let code): return "PIO program loading failed (SDK error \(code))"
        case .stateMachineInitializationFailed(let code):
            return "PIO state-machine initialization failed (SDK error \(code))"
        case .pinDirectionSetupFailed(let code):
            return "PIO pin-direction setup failed (SDK error \(code))"
        }
    }
}

// Hardware operations deliberately live in the application, not the PIO library.
extension PIOProgram {
    func addProgram(to pio: PIO) throws(PicoAudioError) -> UInt32 {
        let result: Int32
        do {
            result = try withCProgram { pio_add_program(pio, $0) }
        } catch {
            throw .configuration(error)
        }
        guard result >= 0 else { throw .programLoadFailed(result) }
        return UInt32(result)
    }
}

func claimStateMachine(on pio: PIO) throws(PicoAudioError) -> UInt32 {
    let result = pio_claim_unused_sm(pio, false)
    guard result >= 0 else { throw .noStateMachine }
    return UInt32(result)
}
