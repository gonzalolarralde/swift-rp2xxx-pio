# Development and verification

For the public API, start with the [README](../README.md) and
[API reference](Reference.md). Commands below run from the repository root.
Host verification has been exercised on macOS; SDK and optimization checks use `xcrun`.

## PicoAudio firmware example

`Examples/PicoAudio` is an Embedded Swift package for Pico 2. It defines
an I2S program, loads it into PIO, configures the pins and state machine,
and continuously sends low-amplitude pseudorandom stereo noise at approximately
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
sample rate are constants in `PicoAudio.run()`; the two clock GPIOs
must remain consecutive.

```sh
# From the repository root:
(cd Examples/PicoAudio && ./build.sh)
```

The script uses Swiftly and CPicoSDK's preparation/finalization workflow.
Install Swiftly first. Preparation may download build tools and the SDK, install
the toolchain pinned in [.swift-version](../Examples/PicoAudio/.swift-version), and
generate local editor/toolset settings. See [build.sh](../Examples/PicoAudio/build.sh)
for preparation options and [Package.swift](../Examples/PicoAudio/Package.swift)
for the board/platform traits. SwiftPM fetches the library's transitive
dependencies; a separate sibling checkout is not needed.

A normal build produces ELF and UF2 files without programming a board. Flashing
is a separate, explicit action via the script's `--flash` option.
The application entry point is
[PicoAudio.swift](../Examples/PicoAudio/Sources/PicoAudio/PicoAudio.swift).
The firmware has been build-checked and its setup exercised with host-side
hardware substitutes; audio output has not been verified on a physical board.

The hand-written [I2S.swift](../Examples/PicoAudio/Sources/PicoAudio/I2S.swift)
contains an inert `I2S.Program: PIOProgram` struct
and a non-owning `I2S` hardware handle. Program requirements are instance members;
only the immutable compiled instructions and label identity use private shared
storage. The protocol supplies metadata, label lookup, validated configuration,
and scoped C interop.

`PicoAudio.swift` explicitly claims a state machine and calls
`I2S.Program().addProgram(to: pio)`. That loading convenience lives in the
application's [PIOHelpers.swift](../Examples/PicoAudio/Sources/PicoAudio/PIOHelpers.swift),
not the library. `I2S.init(pio:sm:offset:...)`
takes those existing resources, validates the pins and sample rate, and configures
and starts the state machine. It never claims, loads, unloads, or unclaims anything.
`audio.write(frame)` sends a stereo frame; copies of the handle refer to the same
hardware. Setup failures are caught and reported without forced error handling.
There is no `.pio` input or generated Swift file in this example.

## Embedded boundary and generated registry

The host example uses ordinary Swift; it does not enable `SDKInterop` or compile
CPicoSDK. Embedded consumers use CPicoSDK's cross-compilation and linking setup.
No changes to CPicoSDK are required.

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

From the repository root, run the host suite and example:

```sh
swift test -Xswiftc -warnings-as-errors
swift run --package-path Examples/PartialPrograms PartialPrograms
```

For live comparison against the reference assembler, also install CMake and a
C++ compiler, then build the pinned pioasm executable (the first run needs
network access):

```sh
bash Scripts/prepare-pioasm.sh
swift test -Xswiftc -warnings-as-errors
```

The reference build is pinned to pico-sdk revision
`079c6f39023649b154152db30f1d781e884879bc`. Differential tests cover more than
500 instruction/modifier combinations and configuration metadata. Without the
reference executable, live-oracle tests explicitly skip; checked-in
upstream golden fixtures, native, macro, error, and branch tests still run.
Set `PIOASM` to override its path.

To execute the SDK adapter checks on macOS, provide both the pico-sdk sources
and a CPicoSDK checkout containing its RP2040 compatibility overload. The
reference build above already downloads suitable pico-sdk sources:

```sh
PIO_SDK_PATH="$PWD/.build/pioasm-reference" \
CPICOSDK_ROOT=/absolute/path/to/CPicoSDK \
swift test -Xswiftc -warnings-as-errors
```

Replace the CPicoSDK path with your checkout, or with
`$PWD/Examples/PicoAudio/.build/checkouts/CPicoSDK` after building PicoAudio.
`PIO_SDK_PATH` may instead point to another compatible pico-sdk source directory.
The pinned pioasm executable must also be present for these checks to run.

These checks compile the production adapter against the real RP2040 and RP2350
PIO headers using the SDK's host
platform shim. They compare 45 value-based and 45 protocol-based configurations
(nine fixtures at five load offsets) with pioasm-generated C, and verify C metadata
and 180 repeated, nested protocol/value scoped borrows. They also exercise
runtime requirements, omitted defaults, pin bases, and configuration errors.
The same harness compiles PicoAudio's actual program, initializer, and loading
helper with recording substitutes for hardware operations. It checks unchanged
I2S words/configuration, explicit loading/claiming, initializer call order, invalid
inputs, and SDK failures without touching hardware.
Without `PIO_SDK_PATH` or pioasm, this optional integration test explicitly skips;
a passing host-only run does not imply that SDK integration was checked. If
`CPICOSDK_ROOT` is omitted, the harness looks in `.build/checkouts/CPicoSDK`,
which may not exist in a host-only checkout. No physical hardware is accessed.

### Optimized setup comparison

This optional macOS developer probe requires Python 3, the pinned pioasm build,
and an already-built CPicoSDK consumer that imports this library with
`SDKInterop`. It compiles the library and CPicoSDK's actual pioasm-generated
Swift with that consumer's release/Embedded compiler flags. After building
PicoAudio, run from the repository root:

```sh
python3 Scripts/Optimization/compare.py \
  --firmware-package Examples/PicoAudio --module PicoAudio \
  --triple armv7em-none-none-eabi
```

For a different consumer, substitute its package path and Swift module name.
RP2040 consumers use `--triple armv6m-none-none-eabi` (the script's default).

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

The protocol is a convenience API, not a zero-overhead guarantee.
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

### Runtime and size benchmarks

The separate [benchmark suite and initial findings](../Scripts/Benchmarks/README.md)
compare `#constPIO`, fully constant and partially folded `#pio`, native assembly,
and pioasm word tables. It measures host construction time, emitted ARM code,
linked Pico firmware size/static SRAM, stored-versus-rebuilt programs, and
dead-code elimination with live or unused results. The report distinguishes
host timings, static code size, and executed instruction counts on an emulated
Cortex-M33. Native board timing and allocation/stack profiling remain future work.
