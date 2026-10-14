#if SDKInterop
import CPicoSDK
import RP2xxxPIOCore

public extension PIOProgram {
    /// Borrows the instruction storage and C descriptor for the duration of `body`.
    /// Neither pointer may escape. `pio_add_program` copies the words into PIO
    /// instruction memory and can safely be called here. This method does not load it.
    func withCProgram<Result>(_ body: (UnsafePointer<pio_program_t>) -> Result) -> Result {
        _withCProgram(origin: nil, body)
    }

    fileprivate func _withCProgram<Result>(origin: Int?, _ body: (UnsafePointer<pio_program_t>) -> Result) -> Result {
        precondition(!instructions.isEmpty && instructions.count <= 32)
        precondition(origin == nil || (origin! >= 0 && origin! + instructions.count <= 32))
        return instructions.withUnsafeBufferPointer { buffer in
            // Unqualified lookup includes CPicoSDK's Swift compatibility
            // overload for RP2040's shorter C descriptor.
            var native = pio_program(
                instructions: buffer.baseAddress!, length: .init(buffer.count),
                origin: .init(origin ?? -1), pio_version: .init(version.rawValue),
                used_gpio_ranges: .init(usedGPIORanges)
            )
            return withUnsafePointer(to: &native, body)
        }
    }
}

public extension PIOConfiguration {
    /// Borrows the program with this configuration's optional fixed origin.
    func withCProgram<Result>(_ body: (UnsafePointer<pio_program_t>) -> Result) -> Result {
        program._withCProgram(origin: origin, body)
    }

    /// Native counterpart of #pioConfig. Only constructs a local C value;
    /// GPIO setup, claiming, loading, initialization, and enabling remain explicit.
    @inlinable func defaultConfig(offset: UInt32) throws(PIOConfigurationError) -> pio_sm_config {
        try _validateOffset(offset)
        var result = pio_get_default_sm_config()
        sm_config_set_wrap(&result, offset + UInt32(program.wrapTarget), offset + UInt32(program.wrap))
        if let input {
            sm_config_set_in_pin_count(&result, UInt32(input.pinCount))
            sm_config_set_in_shift(&result, input.right, input.automatic, UInt32(input.threshold))
        }
        if let output {
            sm_config_set_out_pin_count(&result, UInt32(output.pinCount))
            sm_config_set_out_shift(&result, output.right, output.automatic, UInt32(output.threshold))
        }
        if let count = setCount { sm_config_set_set_pin_count(&result, UInt32(count)) }
        if let side = program.sideSet {
            sm_config_set_sideset(&result, UInt32(side.totalBits), side.optional, sideSetPinDirections)
        }
        if let status = movStatus {
            let (selector, value) = Self._sdkStatus(status)
            sm_config_set_mov_status(&result, pio_mov_status_type(rawValue: selector), value)
        }
        sm_config_set_fifo_join(&result, pio_fifo_join(rawValue: _sdkFIFO))
        sm_config_set_clkdiv_int_frac(&result, clockDividerInteger, clockDividerFraction)
        if let pin = pins.input { sm_config_set_in_pin_base(&result, UInt32(pin)) }
        if let pin = pins.output { sm_config_set_out_pin_base(&result, UInt32(pin)) }
        if let pin = pins.set { sm_config_set_set_pin_base(&result, UInt32(pin)) }
        if let pin = pins.sideSet { sm_config_set_sideset_pin_base(&result, UInt32(pin)) }
        if let pin = pins.jump { sm_config_set_jmp_pin(&result, UInt32(pin)) }
        return result
    }
}
#endif
