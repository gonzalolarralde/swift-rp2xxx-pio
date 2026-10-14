@_exported import RP2xxxPIOCore
#if SDKInterop
@_exported import RP2xxxPIOSDK
import CPicoSDK
#endif

/// Fold when inputs are known; otherwise assemble with typed runtime errors.
@freestanding(expression)
public macro pio(
    version: PIOVersion = .rp2040, sideSet: PIOSideSet? = nil,
    @PIOBuilder _ body: () -> PIOProgramSource
) -> PIOProgram =
    #externalMacro(module: "RP2xxxPIOMacros", type: "PIOMacro")

/// Compile every instruction and encoding option; captured label handles are associated
/// with their already-computed offsets when the Swift value is constructed.
@freestanding(expression)
public macro constPIO(
    version: PIOVersion = .rp2040, sideSet: PIOSideSet? = nil,
    @PIOBuilder _ body: () -> PIOProgramSource
) -> PIOProgram =
    #externalMacro(module: "RP2xxxPIOMacros", type: "ConstPIOMacro")

#if SDKInterop
/// Generate only the selected SDK setup calls. Arguments may be runtime values;
/// validation throws PIOConfigurationError. No hardware is read or written.
@freestanding(expression)
public macro pioConfig(
    program: PIOProgram, offset: UInt32, input: PIOShiftConfiguration? = nil,
    output: PIOShiftConfiguration? = nil, setCount: Int? = nil,
    fifo: PIOFIFOJoin = .txrx, movStatus: PIOMovStatus? = nil, clockDivider: Double = 1,
    sideSetPinDirections: Bool = false, pins: PIOPinMapping = .init()
) -> pio_sm_config = #externalMacro(module: "RP2xxxPIOMacros", type: "PIOConfigMacro")
#endif
