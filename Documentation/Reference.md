# API reference

Start with the [README](../README.md) for a program and firmware integration example.

## Macro behavior

`#constPIO` requires instructions and encoding options to be known and valid during macro expansion.
It emits immutable `PIOProgramData`: instruction words, version, side-set encoding,
wrap bounds, GPIO-range metadata, public numeric symbols, and FIFO requirements.
Local labels disappear entirely. Captured labels receive a runtime
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

Known programs fold to the same data as `#constPIO`. With known encoding options,
partially known bodies pre-encode constant instructions, including instructions
inside runtime `if`/`else` and `switch` branches. Dynamic instructions, original
control flow, and label handles remain in the builder. The existing assembler
resolves the resulting layout, encodes the remaining instructions, and checks
program-wide constraints. Dynamic assembly throws `PIOAssemblyError`.
Definitely invalid constant programs are compiler errors
in either macro. The ordinary macro retains its typed-throwing contract even
when folded, so `try #pio` is valid with warnings treated as errors.

For example, `Out(.pins, 1)` can become `UInt16(0x6001)`, while
`Out(.pins, count)` remains an instruction. Jumps stay symbolic in partially
compiled programs (including numeric jumps, whose bounds depend on final program
length). Dynamic encoding options conservatively retain runtime encoding.
An invalid instruction in an uncertain branch is validated only if that branch
is selected. Precompiled instructions retain GPIO-range and FIFO metadata in
their selected branch; this information is not always recoverable from the bits.

Run the separate [mixed-program example](../Examples/PartialPrograms/Sources/PartialPrograms/PartialPrograms.swift):

```sh
swift run --package-path Examples/PartialPrograms PartialPrograms
```

It demonstrates dynamic operands, side-set values, optional instructions, a
switch, labels, metadata, and runtime validation failures.

Native assembly uses exactly the same implementation:

```swift
let native = try PIOAssembler.assemble {
    Set(.x, 31)
    Jmp(.xDecrement, to: 0)
}
```

## Instructions and control flow

The DSL covers the instruction forms in the pinned upstream PIO assembler;
RP2350-only instructions require `version: .rp2350`:

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

The builder also accepts `UInt16` values as **complete encoded words**, including
their delay/side-set bits. Each occupies one instruction slot. Explicit integers
are an opaque escape hatch: like `Word`, they do not infer GPIO/FIFO requirements
or validate instruction operands. Unlike `Word`, `UInt16` is accepted with
mandatory side-set because the bits are already supplied. Prefer typed
instructions for validation and metadata; macro-folded instructions preserve
both, using `PIOStatement.encoded` with metadata when necessary.

`@PIOLabel var loop` declares an immutable, opaque handle inside a function,
builder body, or type. At file scope, where Swift does not support property
wrappers, use `let loop = PIOLabelHandle()` instead. `Label(loop)` marks
its position and `Jmp(to: loop)` targets it, including forward references.
Declare it inside the body for a private label, or outside for an entry point
accessible through `program.labels[loop]`. Offsets belong to each program, so
one external handle can identify different offsets in different programs.
Separate declarations always have different identities, even with the same
Swift name in nested scopes. No label names or `isPublic` flag are needed.

Compiler-only labels use sequential `UInt64` IDs in one program-local namespace.
The compiler assigns each declaration a distinct ID, including shadowed names;
aliases reuse their declaration's ID. This is collision-free within the assembly,
not a truncated hash of source text or a process-randomized Swift hash. These IDs
are erased during constant compilation. Runtime declarations still create fresh
identity objects, so invoking the same declaration twice creates distinct handles.
Label equality and dictionary hashing use only identity/numeric data; source names
for compiler diagnostics remain in the macro, not in the device's label handle.

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

Boolean `if`, `if`/`else`, `else if`, and `switch` are supported. Known selections fold
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

Enable `SDKInterop` on this dependency. An application that imports `CPicoSDK`
must also declare its own CPicoSDK package and target-product dependencies and
select the appropriate platform/board traits. The PIO library does not select
a board or provide a complete firmware build configuration. See the complete
[PicoAudio manifest](../Examples/PicoAudio/Package.swift) for a Pico 2 example.

In the application's `dependencies` array, enable the PIO trait with:

```swift
.package(url: "https://github.com/gonzalolarralde/swift-rp2xxx-pio.git", branch: "main", traits: ["SDKInterop"])
```

The trait adds scoped C descriptors and ordinary Swift configuration methods.
For example, using `SerialOutput` from [above](#compilation-and-configuration),
this application helper loads the program into a supplied PIO block and returns
its offset and configuration. It does not claim or start a state machine:

```swift
import CPicoSDK
import RP2xxxPIO

enum LoadingError: Error { case sdk(Int32) }

func loadSerialOutput(into pio: PIO) throws -> (offset: UInt32, config: pio_sm_config) {
    let program = SerialOutput(clockDivider: 2.5)
    let result = try program.withCProgram { pio_add_program(pio, $0) }
    guard result >= 0 else { throw LoadingError.sdk(result) }
    let offset = UInt32(result)
    var config = try program.defaultConfig(offset: offset)
    sm_config_set_out_pin_base(&config, 2)
    return (offset, config)
}
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
