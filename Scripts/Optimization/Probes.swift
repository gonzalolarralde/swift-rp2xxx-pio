import CPicoSDK
import RP2xxxPIO

private struct DefaultStored: PIOProgram {
    private static let compiledCode = #constPIO { Nop(); Jmp(to: 0) }
    var code: PIOProgramData { Self.compiledCode }
}

private struct DefaultComputed: PIOProgram {
    var code: PIOProgramData { #constPIO { Nop(); Jmp(to: 0) } }
}

private protocol ConfiguredDefaults: PIOProgram {}
private extension ConfiguredDefaults {
    var input: PIOShiftConfiguration? { .init(pinCount: 32, right: false, automatic: true, threshold: 12) }
    var setCount: Int? { 3 }
    var movStatus: PIOMovStatus? { .rxLessThan(9) }
    var clockDivider: Double { 12 }
    var sideSetPinDirections: Bool { true }
}

private struct ConfiguredStored: ConfiguredDefaults {
    private static let compiledCode = #constPIO(sideSet: .init(bits: 2, optional: true)) {
        Nop(); WrapTarget(); Nop().sideSet(value: 3).delay(2); Pull(); Wrap(); Jmp(to: 1)
    }
    var code: PIOProgramData { Self.compiledCode }
}

private struct ConfiguredComputed: ConfiguredDefaults {
    var code: PIOProgramData {
        #constPIO(sideSet: .init(bits: 2, optional: true)) {
            Nop(); WrapTarget(); Nop().sideSet(value: 3).delay(2); Pull(); Wrap(); Jmp(to: 1)
        }
    }
}

// All wrappers receive the same runtime offset, constrained to a valid range.
// This lets the optimizer remove safety checks without confusing their cost
// with configuration specialization. The output pointer makes every field live.
// Every entry returns success explicitly; failure leaves the output untouched.
@_cdecl("native_default_local")
@inline(never)
public func nativeDefaultLocal(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) -> Bool {
    let program = #constPIO { Nop(); Jmp(to: 0) }
    do {
        result.pointee = try PIOConfiguration(program: program).defaultConfig(offset: offset & 15)
        return true
    } catch { return false }
}

@_cdecl("protocol_default_stored")
@inline(never)
public func protocolDefaultStored(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) -> Bool {
    do {
        result.pointee = try DefaultStored().defaultConfig(offset: offset & 15)
        return true
    } catch { return false }
}

@_cdecl("protocol_default_computed")
@inline(never)
public func protocolDefaultComputed(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) -> Bool {
    do {
        result.pointee = try DefaultComputed().defaultConfig(offset: offset & 15)
        return true
    } catch { return false }
}

@_cdecl("pioasm_default")
@inline(never)
public func pioasmDefault(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) -> Bool {
    result.pointee = opt_default.get_default_config(offset: offset & 15)
    return true
}

@_cdecl("native_configured_local")
@inline(never)
public func nativeConfiguredLocal(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) -> Bool {
    let program = #constPIO(
        sideSet: .init(bits: 2, optional: true)
    ) {
        Nop(); WrapTarget(); Nop().sideSet(value: 3).delay(2); Pull(); Wrap(); Jmp(to: 1)
    }
    do {
        result.pointee = try PIOConfiguration(program: program,
            input: .init(pinCount: 32, right: false, automatic: true, threshold: 12),
            setCount: 3, movStatus: .rxLessThan(9), clockDivider: 12, sideSetPinDirections: true).defaultConfig(offset: offset & 15)
        return true
    } catch { return false }
}

@_cdecl("protocol_configured_stored")
@inline(never)
public func protocolConfiguredStored(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) -> Bool {
    do {
        result.pointee = try ConfiguredStored().defaultConfig(offset: offset & 15)
        return true
    } catch { return false }
}

@_cdecl("protocol_configured_computed")
@inline(never)
public func protocolConfiguredComputed(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) -> Bool {
    do {
        result.pointee = try ConfiguredComputed().defaultConfig(offset: offset & 15)
        return true
    } catch { return false }
}

@_cdecl("pioasm_configured")
@inline(never)
public func pioasmConfigured(_ offset: UInt32, _ result: UnsafeMutablePointer<pio_sm_config>) -> Bool {
    result.pointee = opt_configured.get_default_config(offset: offset & 15)
    return true
}
