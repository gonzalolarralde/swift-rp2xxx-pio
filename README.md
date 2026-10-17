# RP2xxxPIO

A Swift assembler DSL for the RP2040 and RP2350 programmable I/O (PIO) hardware.

Write PIO programs inline with your Embedded Swift firmware, using typed
instructions, Swift labels, and ordinary values—even runtime inputs. Constant
programs compile to compact 16-bit instruction words at build time, keeping the
assembler out of the runtime path.

## Write a PIO program

```swift
import RP2xxxPIO

struct Pulse: PIOProgram {
    var clockDivider: Double = 1
    var pins: PIOPinMapping = .init()
    let setCount: Int? = 1

    let code = #constPIO {
        @PIOLabel var loop

        Label(loop)
        Set(.pins, 1).delay(7)
        Set(.pins, 0).delay(7)
        Jmp(to: loop)
    }
}
```

This program repeatedly drives one output high and low. Labels are Swift
identifiers, not strings or manually maintained addresses: the result builder
captures their positions, and the assembler resolves the jumps.

`PIOProgram` combines instruction data with state-machine settings. Only `code`
is required; pins, clock rate, and other settings can vary per instance without
recompiling the instructions. Declaring a program does not touch hardware.

## Use it in your firmware

With `SDKInterop` enabled, pass the program to CPicoSDK to load its instructions
and prepare the state-machine configuration:

```swift
import CPicoSDK
import RP2xxxPIO

enum LoadingError: Error { case sdk(Int32) }

func loadPulse(into pio: PIO) throws -> (offset: UInt32, config: pio_sm_config) {
    let program = Pulse(clockDivider: 100, pins: .init(set: 2))
    let setup = try program.configuration()

    let result = setup.withCProgram { pio_add_program(pio, $0) }
    guard result >= 0 else { throw LoadingError.sdk(result) }

    let offset = UInt32(result)
    return (offset, try setup.defaultConfig(offset: offset))
}
```

Your application owns the hardware lifecycle: claim a state machine, initialize
the GPIOs and pin directions, then initialize and enable the state machine with
this offset and configuration. The SDK handles jump relocation when loading.
Pointers passed to `withCProgram` must stay inside its closure.

For a complete firmware example, see
[PicoAudio](Examples/PicoAudio/Sources/PicoAudio/PicoAudio.swift), which loads an
[I2S program](Examples/PicoAudio/Sources/PicoAudio/I2S.swift) and sends stereo audio.

## Add the package

Use Swift 6.3 or newer. Add
[swift-rp2xxx-pio](https://github.com/gonzalolarralde/swift-rp2xxx-pio) to your
package:

```swift
.package(
    url: "https://github.com/gonzalolarralde/swift-rp2xxx-pio.git",
    branch: "main",
    traits: ["SDKInterop"]
)
```

Add its product to your target's dependencies:

```swift
.product(name: "RP2xxxPIO", package: "swift-rp2xxx-pio")
```

Firmware applications also declare CPicoSDK with their board/platform traits;
the [PicoAudio manifest](Examples/PicoAudio/Package.swift) shows the complete
setup. Omit `traits: ["SDKInterop"]` for host-side assembly and tests—no board or
SDK installation is needed. SwiftPM resolves the library's dependencies; no
sibling checkout is required.

## `#pio` or `#constPIO`?

Both macros compile fully constant programs at build time, producing the same
PIO instruction words without runtime assembly.

- **`try #pio`** is the flexible form. It compiles what it can ahead of time and
  assembles runtime-dependent parts when needed.
- **`#constPIO`** is the guarantee: the entire program and its encoding options
  must be resolvable at build time. Use it to catch accidental runtime assembly
  as a compiler error, not to opt into an otherwise unavailable optimization.

`#pio` keeps its typed-throwing contract even for constant programs, so it still
uses `try`. Its validation wrapper can retain overhead; identical PIO words do
not imply identical generated Swift machine code.

For example, a program can depend on an input:

```swift
func makeProgram(value: Int) throws(PIOAssemblyError) -> PIOProgramData {
    try #pio {
        Set(.x, value)
        Nop()
        Jmp(to: 0)
    }
}
```

Here the constant `Nop()` can be precompiled, while the operand and final jump
layout are validated at runtime. Invalid dynamic operands throw
`PIOAssemblyError`; definitely invalid constant programs are compiler errors
in either macro. See the [mixed-program example](Examples/PartialPrograms/Sources/PartialPrograms/PartialPrograms.swift)
for branches, side-set, and dynamic instruction counts.

Local labels disappear from fully compiled programs. Declare a label outside
the builder to expose an entry point through `code.labels[handle]` or
`program.offset(of: handle)`. Captured labels keep a runtime offset mapping:
build-time instruction generation does not promise zero allocations.

## Examples and reference

- [I2S](Examples/I2S/Sources/I2SExample/I2SExample.swift): a host-side transmitter program.
- [PartialPrograms](Examples/PartialPrograms/Sources/PartialPrograms/PartialPrograms.swift): runtime customization and validation.
- [PicoAudio build guide](Documentation/Development.md#picoaudio-firmware-example): a complete Pico 2 application.
- [API reference](Documentation/Reference.md): instructions, labels, configuration, and SDK interop.
- [Benchmarks](Scripts/Benchmarks/README.md): construction work, linked size, and measurement limits.

## Verification

This is an experimental library; the API may change. Tests compare instruction
words against Raspberry Pi's `pioasm` and configuration against SDK headers for
both chips. Firmware is build-checked, but physical audio output has not been
verified. Configuration is not guaranteed to optimize to the same code as
pioasm-generated SDK calls.

Run `swift test` for the host suite. See the
[development guide](Documentation/Development.md#verification) for reference
assembler checks, SDK verification, and firmware builds.

## License

[MIT](LICENSE.md). Copyright (c) 2026 Gonzalo Larralde.
