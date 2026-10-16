# RP2xxxPIO

A Swift PIO assembler and result-builder DSL for RP2040 and RP2350. Import
`RP2xxxPIO` on a host or in Embedded Swift. The public product is host-safe by
default; the optional `SDKInterop` trait adds CPicoSDK adapters.

## I2S host example

The example is its own Swift package in `Examples/I2S`. It assembles a stereo
I2S transmitter with two 16-bit channels. From the repository root, run:

```sh
swift run --package-path Examples/I2S I2SExample
```

The two bit loops shift audio data onto the output pin while side-set drives
BCLK and LRCLK. An external entry-point label identifies the initial counter
setup. The example uses fixed pin ordering: BCLK at the side-set base GPIO and
LRCLK at the next GPIO.

You can also open that package directly and run `swift run` from its directory.
It depends on the library through a local package dependency (`../..`).

This is a normal, non-Embedded Swift executable: it prints the eight compiled
instruction words and entry-point offset, without accessing hardware. No SDK
setup or shell build script is needed. The source is in
`Examples/I2S/Sources/I2SExample/I2SExample.swift`.

```swift
import RP2xxxPIO

@PIOLabel var entryPoint
let program = #constPIO(sideSet: .init(bits: 2)) {
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

    Label(entryPoint)
    Set(.x, 14).sideSet(value: 0b11)
}
let entryOffset = program.labels[entryPoint] // 7, relative to this program
```

`#constPIO` requires instructions and encoding options to be known and valid during macro expansion.
It emits immutable `PIOProgramData` data: instruction words, version, side-set encoding,
wrap bounds, GPIO-range metadata, public numeric symbols, and FIFO requirements.
Local labels disappear entirely. Captured labels receive a small runtime
association with their already-compiled offsets; no instructions are assembled
or patched on the device. This is not a promise of zero allocations: arrays,
dictionaries, strings, and externally declared label identities use normal Swift storage.

Use `try #pio` when inputs can be dynamic:

```swift
func program(value: Int, enabled: Bool) throws(PIOAssemblyError) -> PIOProgramData {
    try #pio {
        if enabled { Set(.x, value) } else { Nop() }
        Jmp(to: 0)
    }
}
```

Known programs fold to the same data as `#constPIO`. Partially known bodies
can retain precomputed builder components; dynamic assembly throws
`PIOAssemblyError`. Definitely invalid constant programs are compiler errors
in either macro. The ordinary macro retains its typed-throwing contract even
when folded, so `try #pio` is valid with warnings treated as errors.

Native assembly uses exactly the same implementation:

```swift
let native = try PIOAssembler.assemble {
    Set(.x, 31)
    Jmp(.xDecrement, to: 0)
}
```

## PicoAudio firmware example

`Examples/PicoAudio` is a second, Embedded Swift package for Pico 2. It copies
the I2S program above, loads it into PIO, configures the pins and state machine,
and continuously sends low-level pseudorandom stereo noise at approximately
48 kHz. Each FIFO word contains two signed 16-bit samples; the PIO clock divider
sets the playback rate, and blocking FIFO writes pace the producer.

Connect an I2S DAC or amplifier that accepts 3.3 V logic, 16-bit channel slots,
and operation without MCLK:

| Pico connection | I2S signal |
| --- | --- |
| GP2 | DATA / DIN |
| GP3 | BCLK |
| GP4 | LRCLK / WS |
| GND | Common ground |

Power the DAC/amplifier according to its own requirements; do not connect a
speaker directly to a GPIO. Start with the amplifier volume low. The GPIOs and
sample rate are constants at the top of `PicoAudio.swift`; the two clock GPIOs
must remain consecutive.

```sh
cd Examples/PicoAudio
./build.sh
```

The script is copied byte-for-byte from
[CPicoSDK's main-branch example](https://github.com/gonzalolarralde/CPicoSDK/blob/a1aa863645122f9a985a0b6de4f63c5e04853a73/Example/build.sh).
It uses ordinary SwiftPM through Swiftly and CPicoSDK's
preparation/finalization workflow.
Install Swiftly first; the initial build may download the SDK and pinned Swift
snapshot. The app depends on CPicoSDK `main`, with the resolved revision saved
in its own `Package.resolved`. It also uses the local PIO library and the same
sibling `swift-constexpr` checkout as the host example.

A normal build produces ELF and UF2 files without programming a board. Flashing
is a separate, explicit action via the unchanged script's `--flash` option.
The source is in `Examples/PicoAudio/Sources/PicoAudio/PicoAudio.swift`.

The hand-written `I2S.swift` contains an inert `I2S.Program: PIOProgram` struct
and a non-owning `I2S` hardware handle. Program requirements are instance members;
only the immutable compiled instructions and label identity use private shared
storage. The protocol supplies metadata, label lookup, validated configuration,
and scoped C interop; there is no second configuration macro.

`PicoAudio.swift` explicitly claims a state machine and calls
`I2S.Program().addProgram(to: pio)`. That loading convenience lives in the
application's `PIOHelpers.swift`, not the library. `I2S.init(pio:sm:offset:...)`
takes those existing resources, validates the pins and sample rate, and configures
and starts the state machine. It never claims, loads, unloads, or unclaims anything.
`audio.write(frame)` sends a stereo frame; copies of the handle refer to the same
hardware. Setup failures are caught and reported without forced error handling.
There is no `.pio` input or generated Swift file in this example. The build script
remains unchanged.

## Instructions and control flow

The DSL covers all instruction forms in the pinned upstream PIO assembler:

- `Jmp(condition, to: labelOrAddress)`, with all eight conditions.
- `Wait(polarity, .gpio(n) / .pin(n) / .irq(n, mode:) / .jmpPin(offset:))`.
- `In(source, count)` and `Out(destination, count)`, including 32-bit shifts.
- `Push(ifFull:blocking:)` and `Pull(ifEmpty:blocking:)`; blocking defaults to true.
- `Mov(to:from:operation:)`, including inversion, bit reversal, RP2350 pin
  directions, and indexed RX FIFO transfers using `.rxFIFO(.y / .index(n))`.
- `Irq(operation, index, mode:)`, `Set(destination, value)`, `Nop()`, and `Word(value)`.

Instructions support `.delay(cycles)` and `.sideSet(value:)`. `Word` is raw
16-bit data, not an instruction with modifiers. Operands are validated, not
silently masked. A program contains at most 32 instructions. JMP destinations
must be inside the program and remain unrelocated for the SDK loader.

`@PIOLabel var loop` declares an immutable, opaque handle. `Label(loop)` marks
its position and `Jmp(to: loop)` targets it, including forward references.
Declare it inside the body for a private label, or outside for an entry point
accessible through `program.labels[loop]`. Offsets belong to each program, so
one external handle can identify different offsets in different programs.
Separate declarations always have different identities, even with the same
Swift name in nested scopes. No label names or `isPublic` flag are needed.

For compile-time assembly, use stable handle identifiers in `Label` and `Jmp`.
Immutable aliases declared inside the body are supported. Outer aliases with
different names cannot be proven equivalent: use the same reference for the
declaration and jumps, or ordinary `#pio` for runtime resolution. Distinct
external declarations in a constant program must refer to distinct handles;
duplicate runtime identities throw with `#pio` and fail a precondition with
`#constPIO`. Computed handle expressions and identity-dependent control flow
use runtime assembly with `#pio`; they are not accepted as constant programs.

`Define("name", value, isPublic: true)` exports an integer symbol; Swift `let`
bindings provide arithmetic and reusable operands.

Boolean `if`, `if`/`else`, and `else if` are supported. Known selections fold
without executing unselected branches. Unknown conditions preserve the original
runtime builder and its lazy behavior. Loops, pattern conditions, asynchronous
expressions, and throwing builder expressions are not supported in this release.
The ordinary Swift APIs can construct a `PIOProgramSource` from an array when
programmatic generation is needed. Importing/parsing `.pio` text is out of scope.

## Compilation and configuration

Defaults match pioasm: PIO version 0, no fixed origin, wrap from instruction 0
through the last instruction, no side-set allocation, separate TX/RX FIFOs,
and clock divider 1. Unspecified pin/shift/status settings retain SDK defaults.
Pin counts, autopush, and autopull are explicit. Configuration inherits wrap
bounds and side-set width/optionality from the compiled program. In particular,
`Out(.pins, 24)` shifts 24 bits; it does **not** imply 24 output pins.

The compilation macros accept only `version` and `sideSet(bits:optional:)` and
return `PIOProgramData`. Reusable named programs conform to the host-safe
`PIOProgram` protocol; no declaration or configuration macro is needed:

```swift
struct SerialOutput: PIOProgram {
    let output: PIOShiftConfiguration? = .init(
        pinCount: 1, right: false, automatic: true, threshold: 32
    )
    let fifo: PIOFIFOJoin = .tx
    var clockDivider: Double = 1
    let code = #constPIO {
        Out(.pins, 1)
    }
}

let program = SerialOutput(clockDivider: 2.5)
let setup = try program.configuration()
let words = program.instructions
```

Only `code` is mandatory. Protocol extensions default `origin`, `input`, `output`,
`setCount`, and `movStatus` to nil; `fifo` to `.txrx`; `clockDivider` to 1;
`sideSetPinDirections` to false; and `pins` to an empty `PIOPinMapping`.
Each customizable setting is a protocol requirement, so generic consumers see
the supplied instance's implementation. **Use the exact property type, including
optionality:** a nonoptional `output` does not satisfy the optional requirement
and can leave generic code using the default nil. Swift also needs an explicit
type for shorthand values such as `let fifo: PIOFIFOJoin = .tx`.

`configuration()` reads each requirement once and validates a fresh
`PIOConfiguration`. Computed requirements can supply runtime values; they are
not cached by the library: each call uses that instance's current settings.
Immutable compiled data may still use
private static storage exposed through an instance `code` property, as PicoAudio
does. Metadata conveniences (`instructions`, `version`, `sideSet`,
`wrapTarget`, `wrap`, `usedGPIORanges`, `symbols`, `labels`, and `fifoRequirements`)
forward to `code`. `offset(of: handle)` returns a program-relative label offset,
or nil for a handle the program does not define. Named members such as
`offset_entryPoint` are not synthesized.

For ad hoc or per-instance settings, construct a `PIOConfiguration` directly.
Everything that does not affect instruction encoding remains separate from
the compiled data:

```swift
let program = #constPIO(
    version: .rp2350,
    sideSet: .init(bits: 1, optional: true)
) {
    WrapTarget()
    Out(.pins, 6).sideSet(value: 1)
    Wrap()
}
let setup = try PIOConfiguration(
    program: program,
    origin: 4,
    input: .init(pinCount: 16, automatic: true, threshold: 16),
    output: .init(pinCount: 6, right: false, automatic: true, threshold: 24),
    setCount: 2,
    fifo: .txrx,
    movStatus: .txLessThan(4),
    clockDivider: 2.5,
    sideSetPinDirections: false,
    pins: .init(input: 0, output: 16, set: 22, sideSet: 24)
)
```

`#pio` accepts dynamic encoding options; native assembly accepts them in
`PIOOptions`. Runtime clock, pin, and shift choices do not prevent `#constPIO`
from compiling a program. Input `automatic` means autopush; output `automatic`
means autopull. Only position-dependent `WrapTarget()` and `Wrap()` markers
remain in the instruction body. Side-set pin directions are a configuration
choice; they do not change the encoded words.

Configuration throws `PIOConfigurationError`, separately from assembly errors.
The assembler records FIFO requirements for `Push` and indexed RX FIFO moves;
configuration checks the chosen mode against those requirements. A program
combining instructions that require mutually incompatible modes is rejected
by the assembler. Raw `Word` values are opaque and do not add FIFO requirements.

Optional side-set consumes an additional enable bit from the shared five-bit
delay/side-set field. Nonoptional side-set requires a value on every instruction,
including an explicit zero when its width is zero. A side-set modifier requires
an explicit `sideSet` parameter. RP2350 WAIT GPIO retains the three-range bitmap;
GPIO 0...15 and 32...47 cannot be mixed in a single program.

Duplicate wrap markers, invalid origins, and RP2040 IRQ-status
configuration are rejected even where upstream accepts or defers them. A fixed
origin plus program length must fit the 32-word instruction memory.

## CPicoSDK interop

Enable `SDKInterop` on this dependency and select board traits on the
application's direct CPicoSDK dependency. This is optional and separate from
the host example; the library itself does not choose a board. PicoAudio
demonstrates this setup for Pico 2.

```swift
.package(path: "../swift-rp2xxx-pio", traits: ["SDKInterop"])
```

The trait adds scoped C descriptors and ordinary Swift configuration methods:

```swift
import CPicoSDK

enum LoadingError: Error { case sdk(Int32) }
let program = SerialOutput()
let loadedOffset = try program.withCProgram { pio_add_program(pio0, $0) }
guard loadedOffset >= 0 else { throw LoadingError.sdk(loadedOffset) }
var config = try program.defaultConfig(offset: UInt32(loadedOffset))
sm_config_set_out_pin_base(&config, 2)
// Initialize and enable the chosen state machine explicitly.

// The value-based API remains available for runtime/instance-specific choices:
let setup = try PIOConfiguration(program: program.code,
    output: program.output, fifo: program.fifo,
    clockDivider: 2.5, pins: .init(output: 2))
let nativeConfig = try setup.defaultConfig(offset: UInt32(loadedOffset))
```

`withCProgram` borrows both the instruction storage and C descriptor. Neither
pointer may escape its closure. There is no permanent allocation or leaked
global descriptor. The protocol's `withCProgram` validates its configuration and
includes the declared `origin`; it throws `PIOConfigurationError` before entering
the closure if the settings are invalid. `setup.withCProgram` uses an already
validated value, while `code.withCProgram` borrows relocatable instruction data.

`defaultConfig(offset:)` constructs a local `pio_sm_config` and applies relocated
wrap bounds, side-set, shift/pin counts, FIFO mode, MOV status, clock, and GPIO
bases. Protocol methods reuse `PIOConfiguration` and the same SDK adapter;
configuration is ordinary Swift, not generated setter code. Neither method
itself accesses hardware. `origin` is a loading constraint, not a change to the
compiled instructions or the load offset passed to `defaultConfig`.

The SDK loader owns JMP relocation and RP2350 GPIO-base adjustment. Loading,
claiming a state machine, GPIO setup, and enabling hardware are never automatic.

## Dependencies and Embedded boundary

This development checkout requires Swift 6.3+, a sibling `swift-constexpr`
checkout containing `ConstExprEvaluation`, and CPicoSDK's remote `main` branch
(the resolved revision is checked in). The host example uses ordinary Swift;
it does not enable `SDKInterop` or compile CPicoSDK. No changes are required in CPicoSDK.

`RP2xxxPIOCore` is plain Swift with `ConstExpr` annotations. Those annotations
generate registrations in the host copy and become no-ops in Embedded mode.
Only `RP2xxxPIOMacros` imports the evaluator, rendering support, and SwiftSyntax.
The public facade re-exports the core and, when enabled, the SDK bridge using
Swift's underscored `@_exported` attribute. CPicoSDK is not in the macro graph.

The registry is generated from the annotated core declarations:

```sh
swift package --allow-writing-to-package-directory generate-constexpr-registry \
  --module RP2xxxPIOCore --output-target RP2xxxPIOMacros --registry-name PIORegistry
# Append --check to detect stale generated source without changing it.
```

## Verification

```sh
bash Scripts/prepare-pioasm.sh
swift test -Xswiftc -warnings-as-errors
swift run --package-path Examples/I2S I2SExample
# Optional firmware build; does not flash a board.
(cd Examples/PicoAudio && ./build.sh)
```

The reference build is pinned to pico-sdk revision
`079c6f39023649b154152db30f1d781e884879bc`. Differential tests cover more than
500 instruction/modifier combinations and configuration metadata. Without the
reference executable, live-oracle tests explicitly skip; checked-in
upstream golden fixtures, native, macro, error, and branch tests still run.
Set `PIOASM` to override its path.

To execute the SDK adapter checks on the host, set `PIO_SDK_PATH` to a pico-sdk
source directory and rerun `swift test`. These checks compile the production
adapter against the real RP2040 and RP2350 PIO headers using the SDK's host
platform shim. They compare 45 value-based and 45 protocol-based configurations
(nine fixtures at five load offsets) with pioasm-generated C, and verify C metadata
and 180 repeated, nested protocol/value scoped borrows. They also exercise
runtime requirements, omitted defaults, pin bases, and configuration errors.
The same harness compiles PicoAudio's actual program, initializer, and loading
helper with recording substitutes for hardware operations. It checks unchanged
I2S words/configuration, explicit loading/claiming, initializer call order, invalid
inputs, and SDK failures without touching hardware.
Without that variable, this optional integration test explicitly skips. It does
not access hardware. `CPICOSDK_ROOT` can override the resolved CPicoSDK checkout
used for its RP2040 descriptor compatibility overload.

### Optimized setup comparison

This optional developer probe is separate from the host example. It requires
an already-built CPicoSDK consumer package that imports this library with
`SDKInterop`. It compiles the library and CPicoSDK's actual pioasm-generated
Swift with that consumer's release/Embedded compiler flags:

```sh
python3 Scripts/Optimization/compare.py \
  --firmware-package /path/to/consumer --module ConsumerModule
# Add --triple armv7em-none-none-eabi for an RP2350 consumer build.
```

The script emits LLVM IR, ARM assembly, an object file, and a JSON report in
`.build/optimization-comparison/<triple>/`. It uses default and configured
programs with the same runtime load offset and keeps every C configuration field
live. It compares Swift function bodies, not just their C entry-point thunks.
These Swift-generator fixtures cover wrap, side-set, input shift, set count,
MOV status, and clock. Output/FIFO settings are covered by the separate C SDK
differential suite; no claim of exhaustive optimizer equivalence is made.

The report compares protocol instances exposing private shared instruction storage
and instances computing `code` directly, plus locally constructed
`PIOConfiguration` values. Every probe returns a success flag; throwing paths
return false without writing the output. There is no forced error handling.
It reports direct/indirect calls, conditional branches, and referenced helper bodies:
a small wrapper can still call a shared routine containing validation and
configuration branches. These are code-shape comparisons, not timing benchmarks.

The protocol removes the configuration macro, not necessarily its runtime cost.
Ordinary Swift can specialize defaults, but the current RP2040 and RP2350 release
probes retain shared configuration helpers and storage lifetime work rather than matching
pioasm's straight-line setters. Stored programs can also retain lazy initialization
and metadata validation. `--require-protocol-equivalence` optionally enforces
exact equality for the stored-code probes and is expected to fail with this
implementation. The normal report records differences without treating them
as a correctness failure. The setup-only comparison excludes only explicitly
reported direct releases of constant storage; it does not hide helper calls.

This comparison narrows the pinned pioasm JSON's oversized clock fraction to
`UInt8`, just as the C SDK does, in a diagnostic copy of its generated Swift.
It does not change CPicoSDK or the generated sequence of SDK calls.

The reference JSON can retain a sixth WAIT GPIO bit above the 16-bit word, and
the pinned clock-divider implementation can emit an oversized fractional value.
Tests compare instruction words and fractions after the same narrowing used by
the C SDK; this library stores valid `UInt16`/`UInt8` values directly.

Embedded firmware preparation, linking, and flashing belong to the consuming
CPicoSDK application. PicoAudio uses CPicoSDK's unchanged launcher for those
steps; the PIO compiler does not perform them.
