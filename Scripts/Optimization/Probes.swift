import CPicoSDK
import RP2xxxPIO

private let storedDefault = #constPIO { Nop(); Jmp(to: 0) }
private let storedConfigured = #constPIO(
    sideSet: .init(bits: 2, optional: true)
) {
    Nop(); WrapTarget(); Nop().sideSet(value: 3).delay(2); Pull(); Wrap(); Jmp(to: 1)
}

// All wrappers receive the same runtime offset, constrained to a valid range.
// This lets the optimizer remove safety checks without confusing their cost
// with configuration specialization. The output pointer makes every field live.
@_cdecl("macro_default_local")
@inline(never)
public func macroDefaultLocal(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) {
    let program = #constPIO { Nop(); Jmp(to: 0) }
    result.pointee = try! #pioConfig(program: program, offset: offset & 15)
}

@_cdecl("macro_default_stored")
@inline(never)
public func macroDefaultStored(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) {
    result.pointee = try! #pioConfig(program: storedDefault, offset: offset & 15)
}

@_cdecl("pioasm_default")
@inline(never)
public func pioasmDefault(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) {
    result.pointee = opt_default.get_default_config(offset: offset & 15)
}

@_cdecl("macro_configured_local")
@inline(never)
public func macroConfiguredLocal(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) {
    let program = #constPIO(
        sideSet: .init(bits: 2, optional: true)
    ) {
        Nop(); WrapTarget(); Nop().sideSet(value: 3).delay(2); Pull(); Wrap(); Jmp(to: 1)
    }
    result.pointee = try! #pioConfig(program: program, offset: offset & 15,
        input: .init(pinCount: 32, right: false, automatic: true, threshold: 12),
        setCount: 3, movStatus: .rxLessThan(9), clockDivider: 12, sideSetPinDirections: true)
}

@_cdecl("macro_configured_stored")
@inline(never)
public func macroConfiguredStored(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) {
    result.pointee = try! #pioConfig(program: storedConfigured, offset: offset & 15,
        input: .init(pinCount: 32, right: false, automatic: true, threshold: 12),
        setCount: 3, movStatus: .rxLessThan(9), clockDivider: 12, sideSetPinDirections: true)
}

@_cdecl("pioasm_configured")
@inline(never)
public func pioasmConfigured(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) {
    result.pointee = opt_configured.get_default_config(offset: offset & 15)
}
