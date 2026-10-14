# RP2xxxPIO

A Swift PIO assembler and result-builder DSL for RP2040 and RP2350. Import
`RP2xxxPIO` on a host or in Embedded Swift. The public product is host-safe by
default; the optional `SDKInterop` trait adds CPicoSDK adapters.

## Run the example

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
It emits immutable `PIOProgram` data: instruction words, version, side-set encoding,
wrap bounds, GPIO-range metadata, public numeric symbols, and FIFO requirements.
Local labels disappear entirely. Captured labels receive a small runtime
association with their already-compiled offsets; no instructions are assembled
or patched on the device. This is not a promise of zero allocations: arrays,
dictionaries, strings, and externally declared label identities use normal Swift storage.

Use `try #pio` when inputs can be dynamic:

```swift
func program(value: Int, enabled: Bool) throws(PIOAssemblyError) -> PIOProgram {
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

The compilation macros accept only `version` and `sideSet(bits:optional:)`.
Everything that does not affect instruction encoding belongs to a separate,
host-safe `PIOConfiguration` value:

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
the host example; the library itself does not choose a board.

```swift
.package(path: "../swift-rp2xxx-pio", traits: ["SDKInterop"])
```

The trait provides scoped C descriptors, a native configuration adapter, and
the second macro, `#pioConfig`, for specialized setup generation:

```swift
import CPicoSDK

let offset = blink.withCProgram { pio_add_program(pio0, $0) }
var config = try #pioConfig(
    program: blink, offset: UInt32(offset), setCount: 1,
    clockDivider: 2.5, pins: .init(set: 25, sideSet: 25)
)
// Initialize and enable the chosen state machine explicitly.

// Equivalent native API, also useful for storing runtime configurations:
let setup = try PIOConfiguration(program: blink, setCount: 1,
    clockDivider: 2.5, pins: .init(set: 25, sideSet: 25))
let nativeConfig = try setup.defaultConfig(offset: UInt32(offset))
```

`withCProgram` borrows both the instruction storage and C descriptor. Neither
pointer may escape its closure. There is no permanent allocation or leaked
global descriptor. Use `setup.withCProgram` to include a fixed `origin` constraint;
`program.withCProgram` uses a relocatable origin. `defaultConfig(offset:)` applies
wrap, side-set, shift/pin counts, FIFO mode, MOV status, clock, and GPIO bases.

`#pioConfig` generates wrap and inherited side-set setup, plus only the SDK calls
selected by its arguments. Omitted input/output/FIFO/status/clock/pin options do
not generate their setters. Runtime optional values retain their necessary
conditional checks. Arguments are evaluated once, in source order, and share
validation with `PIOConfiguration`. Neither API accesses hardware: both construct
a local `pio_sm_config` value. `origin` belongs to loading, so it is not an argument
of this configuration macro.

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
platform shim. They compare 45 native and 45 macro-generated configurations
(nine fixtures at five load offsets) with pioasm-generated C, and verify C metadata
and 180 repeated/nested scoped borrows. They also exercise dynamic optional
arguments, evaluation order, pin bases, and configuration errors.
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
  --firmware-package /path/to/consumer --module ConsumerModule \
  --require-specialized-setup
# Add --triple armv7em-none-none-eabi for an RP2350 consumer build.
```

The script emits LLVM IR, ARM assembly, an object file, and a JSON report in
`.build/optimization-comparison/<triple>/`. It uses default and configured
programs with the same runtime load offset and keeps every C configuration field
live. It compares Swift function bodies, not just their C entry-point thunks.
These Swift-generator fixtures cover wrap, side-set, input shift, set count,
MOV status, and clock. Output/FIFO settings are covered by the separate C SDK
differential suite; no claim of exhaustive optimizer equivalence is made.

The original combined program/configuration API retained the shared initializer,
optional branches, and FIFO/status dispatch on both ARM targets. With the split,
constant local programs produce the same configuration arithmetic and stores as
pioasm, with no configuration branches or shared initializer call. The **whole
wrapper is not identical**: it retains three releases of constant Swift program
storage. The report records these separately; `--require-specialized-setup`
excludes only those reported releases when comparing setup. The stricter
`--require-local-equivalence` includes them and currently fails. Stored/global or
dynamic program values can retain lazy initialization and metadata-validation
branches; their reports are included without claiming constant folding.

This comparison narrows the pinned pioasm JSON's oversized clock fraction to
`UInt8`, just as the C SDK does, in a diagnostic copy of its generated Swift.
It does not change CPicoSDK or the generated sequence of SDK calls.

The reference JSON can retain a sixth WAIT GPIO bit above the 16-bit word, and
the pinned clock-divider implementation can emit an oversized fractional value.
Tests compare instruction words and fractions after the same narrowing used by
the C SDK; this library stores valid `UInt16`/`UInt8` values directly.

Embedded firmware preparation, linking, and flashing belong to the consuming
CPicoSDK application, not this package's example.
