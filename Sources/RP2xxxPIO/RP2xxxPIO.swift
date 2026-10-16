@_exported import RP2xxxPIOCore
#if SDKInterop
@_exported import RP2xxxPIOSDK
#endif

/// Fold when inputs are known; otherwise assemble with typed runtime errors.
@freestanding(expression)
public macro pio(
    version: PIOVersion = .rp2040, sideSet: PIOSideSet? = nil,
    @PIOBuilder _ body: () -> PIOProgramSource
) -> PIOProgramData =
    #externalMacro(module: "RP2xxxPIOMacros", type: "PIOMacro")

/// Compile every instruction and encoding option; captured label handles are associated
/// with their already-computed offsets when the Swift value is constructed.
@freestanding(expression)
public macro constPIO(
    version: PIOVersion = .rp2040, sideSet: PIOSideSet? = nil,
    @PIOBuilder _ body: () -> PIOProgramSource
) -> PIOProgramData =
    #externalMacro(module: "RP2xxxPIOMacros", type: "ConstPIOMacro")
