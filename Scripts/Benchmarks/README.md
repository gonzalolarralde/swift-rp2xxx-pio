# Program-construction benchmarks

These probes compare the CPU work and retained code needed to produce PIO words
and metadata. They do **not** compare PIO state-machine execution speed: matching
instruction words execute identically once loaded. `pioasm` runs at build time;
its runtime baseline is a static table, not a runtime assembler.

## Executed ARM instruction counts — 2026-10-16

`instruction_count.py` measures **dynamic execution**, not the static instruction
totals in the older tables. It runs the optimized ARM code on one emulated
Cortex-M33 core, with interrupts masked, and counts every executed instruction
through all callees. A loop executing ten times is counted ten times. This is
neither wall time nor a prediction of hardware cycles.

The measurement has precise boundaries:

- **A:** first instruction of the common C `benchmark_path` wrapper, with its
  runtime input and caller-owned output storage supplied.
- **Data ready:** return from `benchmark_construct`, which has initialized a
  complete, owning `PIOProgramData`. All instruction words, metadata, and captured
  label bindings must be live; the compiler cannot discard unused fields.
- **SDK ready (B):** entry to the callback passed to the actual `withCProgram`
  adapter, before executing the callback. Its `pio_program_t` descriptor and
  borrowed instruction storage are ready for `pio_add_program` at this point.

Counts include the wrapper/C–Swift ABI, construction, validation, allocations,
reference counting, and destruction of intermediate construction temporaries.
They exclude checking the result, destroying the finished program, PIO loading,
and SM resource claiming/configuration/enabling. These are raw counts, with no
baseline subtraction. A differently inlined application call site can have
different boundary/ownership overhead. The common wrapper executes seven
instructions on its successful path, in addition to its callees.

Captured-entry lookup is checked and counted **separately**, after B. The
captured handle is a lazy global: first use includes initializing it, whereas
warmed calls reuse it. Each program binds exactly one entry at offset 7.

### Results: construction through SDK-ready

`-O`, one Cortex-M33, with the software-AEABI and deterministic-entropy
adaptations documented below. Numbers are executed ARM instructions from A to B.

| Program source | No capture: first use | No capture: warm | One captured entry: first use | One captured entry: warm |
| --- | ---: | ---: | ---: | ---: |
| `#constPIO`, fully constant | 59 | 59 | 30,408 | 2,688 |
| `#pio`, fully constant | 189 | 189 | 30,410 | 2,690 |
| Native assembler, fully constant | 41,867 | 14,460 | 46,883 | 19,290 |
| `#pio`, one dynamic operand | 40,835 | 13,401 | 45,653 | 18,055 |
| Native assembler, one dynamic operand | 42,330 | 14,896 | 47,228 | 19,630 |
| `#pio`, all dynamic numeric values | 45,949 | 18,386 | 50,962 | 23,484–23,496 |
| Native assembler, all dynamic numeric values | 45,949 | 18,386 | 50,962 | 23,484–23,496 |

The all-dynamic captured median is 23,496. All other cells are invariant across
the recorded 64 inputs/repeats. SDK preparation adds 38–51 instructions after
the data-ready checkpoint. For example, uncaptured `#constPIO` reaches data-ready
in 21 instructions, then SDK-ready in 59. The corresponding `#pio` counts are
151 and 189. A captured entrypoint lookup costs another **397 instructions**,
measured separately rather than silently included or omitted from selected rows.

First-use costs are dominated by lazy shared initialization, not repeated PIO
encoding. An inclusive initializer trace for captured `#constPIO` attributes
23,873 instructions to Swift hash-seed initialization (including newlib PRNG
work), out of its 30,408 SDK-ready instructions. The warmed call is 2,688.

Equal flash size did **not** imply equal execution work: with one dynamic
operand, `#pio` uses 1,495 fewer warmed instructions than native assembly without
a capture (10.0%), and 1,575 fewer with a capture (8.0%). Fully dynamic `#pio` and
native assembly match in this fixture. The two fully constant captured macros
also nearly match; without captures, `#pio`'s throwing validation wrapper remains
observable. None of these instruction ratios is a hardware speedup claim.

### Runtime fidelity and platform adaptations

The harness loads the linked Pico ELF's real code/data into a Cortex-M33 CPU
emulator (Unicorn 2.1.4, using QEMU-derived CPU emulation). It retains and executes
the actual CPicoSDK allocator, newlib heap routines, ARC, dictionaries, software
spinlocks, and mutexes. No guest allocation or library function is replaced by a
host-language shortcut. Before A it initializes the ELF memory sections and runs
the SDK's real spinlock/mutex initialization functions. It does not boot the
board or measure reset-to-ready.

Three explicit platform choices make this reproducible without a connected Pico:

1. Only `SIO_CPUID` is modelled, returning core 0. Every other MMIO access, CPU
   fault, abort/assert, or signal path invalidates the sample. Flash is read-only.
2. RP2350-specific AEABI floating-point linker redirects are removed. The actual
   libgcc software helpers execute as counted ARM code, because the emulator
   cannot execute the RP2350 DCP coprocessor. Therefore these are **not exact
   native-DCP Pico 2 instruction counts**.
3. A benchmark-only deterministic `_getentropy` supplies seed bytes in guest ARM
   code. The current SDK's weak hook returns failure; newlib attempts to raise a
   signal, but the bare-metal `_kill` stub also returns failure. That error path
   is rejected by this harness. The benchmark provider allows successful,
   repeatable initialization while retaining the complete newlib `arc4random`
   and Swift hash-seeding work. It is **not suitable for production or security**,
   and does not measure a hardware entropy source.

The emulator counts IT instructions but not instructions whose IT predicate is
false. Calibration checks straight-line code, loops, nested calls, both IT
paths, memory accesses and mixed 16/32-bit instructions against known counts.
Separate negative checks require CPU faults, unknown MMIO, guest signal paths,
and exhausted instruction budgets to fail rather than produce partial results.

For each of the 14 matched cases, every input from 0 through 63 starts with a
fresh initialized image. The first construction is recorded separately; three
subsequent construct/destroy runs record warmed behavior. All **3,584** complete
samples must match real pioasm instruction words, metadata, the borrowed SDK
descriptor, and the expected captured-label count/offset. Ranges include all
recorded inputs and repeats, not just the fastest sample. First-use costs include
lazy shared runtime initialization; they are not costs paid on every construction.
Two complete executions of the same binaries reproduced every per-input count
and verification checksum exactly.

Raw counts, per-input samples, toolchain versions, ELF/source/SDK hashes,
calibration results, generated sources, assembly, and link commands are saved in
`.build/benchmarks/instruction-count-arm/`. See its `summary.md` for the separate
data-ready, SDK-ready, and entry-lookup measurements.

### Reproduce the execution-count run

First prepare the complete paired Embedded/link matrix described below. Then:

```sh
python3 -m venv .build/benchmarks/instruction-tools
.build/benchmarks/instruction-tools/bin/pip install \
  -r Scripts/Benchmarks/requirements-instructions.txt

.build/benchmarks/instruction-tools/bin/python Scripts/Benchmarks/instruction_count.py

# Repeat the measurements against the exact existing binaries.
.build/benchmarks/instruction-tools/bin/python Scripts/Benchmarks/instruction_count.py --skip-build

# A small correctness/bring-up subset, in its own output directory.
.build/benchmarks/instruction-tools/bin/python Scripts/Benchmarks/instruction_count.py \
  --cases constpio pio_captured pio_dynamic_captured --inputs 0 1 31 63 \
  --output .build/benchmarks/instruction-count-smoke

PYTHONDONTWRITEBYTECODE=1 .build/benchmarks/instruction-tools/bin/python \
  -m unittest discover -s Scripts/Benchmarks -p 'test_*.py' -v
```

The harness never changes SDK sources, example outputs, or firmware defaults,
and never flashes a board. This execution model follows Unicorn's
[per-instruction hooks and Cortex-M support](https://github.com/unicorn-engine/unicorn)
and its pinned version's API. It is intentionally independent of host scheduling
and timer resolution; it does not model memory wait states or CPU cycle timing.

## Numeric labels and shared-runtime baselines — 2026-10-16

Compiler-local label keys now use sequential `UInt64` IDs, not string names.
The macro owns one allocation sequence for local and captured symbols in a
program, including shadowed declarations. Aliases reuse an existing ID. This
has no identity collisions within an assembly; it does not rely on a hash's
collision probability. Runtime declarations still have fresh object identities:
a source-location hash could not distinguish repeated calls to one declaration.
The macro recovers human-readable error names from the evaluated source, keeping
both string-key operations and integer-to-string formatting out of runtime label
handling. Public named `Define` symbols remain a separate string-based feature.
When updating an existing build tree from the string-key representation,
recompile downstream consumers too: cached macro-expanded objects built against
the previous handle layout cannot be reused. The standalone example passed after
forcing its consumer to recompile; its initial incremental build reused an old
consumer object despite rebuilding the library.

### Empty does not always mean no runtime support

`--runtime-profile` selects support that an application may already use:

| Profile | Work kept live independently of PIO |
| --- | --- |
| `none` | Original empty entry point; no extra Swift workload |
| `allocation` | Escaping class allocation, lifetime, and deallocation |
| `collections` | Heap-backed integer array and integer-key dictionary |
| `strings` | Runtime UTF-8 decoding, canonical Unicode equality, string-key dictionary lookup, and hashing |
| `common` | Allocation, collections, and strings together |

These are **alternative baselines**, not a claim that every program needs full
Unicode handling. Merely keeping a string literal does not exercise the same
runtime as Unicode-aware comparison and hashing. Profiles also overlap: in this
SDK, allocation itself reaches a string-keyed allocator registry.

The support is compiled as a separate Swift object and called by the C driver
before the PIO probe. Opaque C observations prevent allocation/collection removal
without reading uninitialized storage. All 64 input variants run profile sanity
checks on the host. The same support object is linked with the empty, C, and PIO
cases for a given profile. It initializes before all timing intervals, including
the nominal cold first PIO call; its setup time is not part of construction timing.

### Linked results with numeric label keys

Pico 2, `-O`, `all` consumption, linker garbage collection, and function-level
sections for the probe, shared support, and rebuilt SDK Swift sources. The SDK
source is unchanged; the diagnostic rebuild also changes its WMO object
partitioning. C SDK/startup/runtime objects are retained as required. These are
full load-image sizes, including runtime and Unicode machinery, not probe-only
sizes. The SDK and project build defaults have not been modified.

| Runtime profile | Empty total flash | Extra: `#constPIO`, no captures | Extra: `#constPIO`, captured entry | Extra: `#pio`, one dynamic operand |
| --- | ---: | ---: | ---: | ---: |
| none | 5,508 B | 376 B | 76,352 B | 90,072 B |
| allocation | 77,340 B | 184 B | 4,832 B | 18,560 B |
| collections | 78,580 B | 216 B | 4,824 B | 18,544 B |
| strings | 89,588 B | 216 B | 4,824 B | 14,480 B |
| common | 90,924 B | 216 B | 4,832 B | 14,496 B |

"Extra" subtracts **only that row's matching empty image**. These linked-size
differences include layout changes and sharing of compiler/SDK helpers; they are
not additive costs to assume for arbitrary firmware.

For the common profile, full totals are 91,060 B for C pioasm data, 91,140 B for
`#constPIO`, 95,756 B for captured-entry `#constPIO`, 95,324 B for fully constant
`#pio` **without a captured entry**, and 105,420 B for either `#pio` or native
assembly with one dynamic operand, also without a captured entry. These are not
matched capture configurations; the complete paired matrix follows below.
The captured-entry case measures binding construction; it does not
include a separately consumed entry-point lookup or state-machine configuration.

Against the prior string-key implementation under the same fully sectioned SDK
configuration, with profile `none`, the captured-entry image fell from 86,036 B
to **81,860 B** (4,176 B saved). Its relocatable probe text fell from 28,926 B to
8,794 B. The linked saving is smaller because the SDK still retains shared
string/Unicode support. Fully constant `#pio` fell from 85,628 B to 81,388 B;
dynamic-operand `#pio` changed from 95,676 B to 95,580 B. Removing a helper from
PIO does not remove its flash cost if another live component still uses it.

Raw reports are under `.build/benchmarks/numeric-arm-{profile}/` and
`.build/benchmarks/numeric-firmware-{profile}/`. No board was flashed; these
measurements do not give hardware cycles or dynamic heap/maximum stack usage.
Host runs for the new profiles were correctness smoke checks, not new timing
measurements. The original timing table below predates numeric label keys.

### Complete paired matrix: constant, partially dynamic, and all dynamic

The same eight-instruction program is now measured both without an external
entry handle and with exactly one captured handle bound at offset 7. All numeric
values remain constant in the fully constant rows; only the handle association
is runtime work. The one-dynamic-operand rows vary a single SET operand. In the
all-dynamic rows, **every instruction's numeric operand, side-set value, and
delay varies at runtime**. Instruction kinds, destinations/conditions, count,
and the two-bit side-set configuration are fixed; this is not runtime opcode
selection. Every row constructs a program per call.

Full flash image bytes, with the same `-O`, `all` consumption and fully sectioned
probe/support/SDK configuration as above:

| Program source | `common`: no captured entry | `common`: one captured entry | `none`: no captured entry | `none`: one captured entry |
| --- | ---: | ---: | ---: | ---: |
| `#constPIO`, fully constant | 91,140 | 95,756 | 5,884 | 81,860 |
| `#pio`, fully constant | 95,324 | 95,828 | 81,388 | 81,932 |
| Native assembler, fully constant | 105,348 | 105,764 | 95,524 | 95,940 |
| `#pio`, one dynamic operand | 105,420 | 105,836 | 95,580 | 96,012 |
| Native assembler, one dynamic operand | 105,420 | 105,836 | 95,580 | 96,012 |
| `#pio`, all dynamic numeric values | 105,932 | 106,388 | 96,092 | 96,564 |
| Native assembler, all dynamic numeric values | 105,932 | 106,388 | 96,092 | 96,564 |

Matching empty images are **90,924 B** for `common` and **5,508 B** for `none`.
There is no dynamic `#constPIO` row: dynamic instruction values violate its
compile-time-only contract.

`#pio` is not smaller than `#constPIO` in either matched constant comparison.
With `common`, it is 4,184 B larger without captures and 72 B larger with one
capture. The earlier apparent advantage compared uncaptured `#pio` (95,324 B)
against captured `#constPIO` (95,756 B). Both captured variants retain label
binding and duplicate-handle validation. Uncaptured `#constPIO` produces data
directly, whereas even fully folded `#pio` calls the typed-throwing `_validated`
wrapper. With captures, `#constPIO` calls it through `_withLabels`, which traps
on conflicting external handles; `#pio` propagates an assembly error. The exact
72-byte linked difference is build-specific, not a general language guarantee.

The all-dynamic `#pio` and native cases have equal object text and linked flash
sizes in this configuration. The one-dynamic-operand cases also match each other;
retaining one runtime instruction already keeps the general assembler/encoder
reachable. No runtime-cycle claim follows from these size measurements.

Each of the 15 host fixtures passed all 64 input checks against real pioasm
output. A separate host verification executable also checks that each captured
fixture has exactly one binding and resolves it to offset 7. That checker is
absent from measured host binaries and all Embedded probes. The flash table
measures binding construction, **not a separately consumed entrypoint lookup**.
New host runs used one-iteration timing smoke checks only; their timing samples
are not performance measurements.

Reports: `.build/benchmarks/complete-matrix-host-common/`,
`.build/benchmarks/complete-matrix-arm-{common,none}/`, and
`.build/benchmarks/complete-matrix-firmware-{common,none}/`.

## Original measurements, before numeric label keys — 2026-10-16

Measured after adding partial instruction folding, on the working tree based on
`4706202b86be9d1a404c05d99bf974dfe63f4352`. These are an initial baseline, not
performance guarantees or pass/fail thresholds. No firmware was flashed.

The fixture is an eight-instruction, I2S-shaped program with two side-set bits.
The branch variant has eight or nine instructions. Results below keep words,
wrap bounds, GPIO/FIFO requirements and side-set width observable (`all`). The
same matrix also tests words only and an entirely unused result.

### Host construction time

Apple M1 Pro, Apple Swift 6.3 (`swiftlang-6.3.0.123.5`), arm64 macOS. Median
nanoseconds per call; each call constructs **and consumes** a program unless
marked stored. These numbers include the shared checksum consumer and call
overhead; they are not baseline-subtracted. Lower is better.

| Program source | `-O` ns/call | `-Osize` ns/call |
| --- | ---: | ---: |
| pioasm words in a static C array | 4.75 | 4.74 |
| pioasm words in a Swift `PIOProgramData` literal | 13.09 | 13.07 |
| Fully constant `#constPIO`, no captured labels | 13.20 | 13.06 |
| Fully constant `try #pio`, no captured labels | 31.39 | 34.52 |
| Native `PIOAssembler`, constant instructions | 1,686.81 | 1,682.14 |
| One dynamic operand, `#pio` | 1,587.63 | 1,583.21 |
| One dynamic operand, native assembler | 1,687.39 | 1,681.99 |
| One dynamic side-set value, `#pio` | 1,549.74 | 1,540.25 |
| One dynamic side-set value, native assembler | 1,693.31 | 1,688.70 |
| Dynamic side-set plus two local labels, `#pio` | 2,710.83 | 2,712.07 |
| Runtime optional instruction, `#pio` | 1,758.95 | 1,754.98 |
| Runtime optional instruction, native assembler | 1,927.10 | 1,925.81 |
| Stored `#constPIO`, steady-state access | 5.45 | 5.42 |
| Stored `#pio`, steady-state access | 5.91 | 6.49 |
| `#constPIO` with one captured label, constructed each call | 178.26 | 176.05 |

For context, hand-written Swift patching of a pioasm word table took about
25.5 ns/call, and choosing between two precompiled tables took 13.9 ns/call.
Those references operate on already-valid masked inputs; they do **not** provide
the assembler's validation, labels or general layout semantics.

Interpretation:

- `#constPIO` matches the equivalent Swift data literal here. Its remaining
  overhead relative to C is storage/lifetime work, not instruction encoding.
- Fully folded `#pio` still invokes `_validated` to preserve its typed-throwing
  contract. That out-of-line call has a visible cost even with no labels.
- Partial folding saves about 6–9% in these host dynamic cases, not orders of
  magnitude. Builder-array construction, layout, validation, and runtime encoding
  of the remaining instructions are still present. Numeric jumps are deliberately
  retained because their validity depends on final program length.
- Storing a compiled program moves construction to initialization. The stored
  timings are warmed reads, not first-use costs. Captured labels add runtime
  identity/dictionary work; local labels in a fully constant program disappear.

### Embedded code and linked flash

Embedded probes use the PicoAudio consumer's `armv7em-none-none-eabi` flags and
Swift `DEVELOPMENT-SNAPSHOT-2026-04-27-a` (6.4-dev). Linking uses the Pico 2
Cortex-M33 SDK harness, GCC 14.2.1, its memory map and `--gc-sections`.
This is a different compiler/runtime from the host timing experiment.

| `-O`, all fields live | Probe `.text` bytes | Static ARM instructions in probe | Linked flash, original probe sections | Linked flash, per-function sections |
| --- | ---: | ---: | ---: | ---: |
| Empty Swift entry point | 1,988 | 799 | 114,332 | 5,556 |
| Static C pioasm table | 44 | 16 | 5,700 | 5,700 |
| Swift pioasm data literal | 2,028 | 813 | 114,524 | 5,740 |
| `#constPIO`, no captured labels | 2,192 | 868 | 114,668 | 5,932 |
| Fully constant `#pio` | 28,662 | 10,201 | 141,396 | 139,780 |
| Native constant assembly | 37,138 | 13,163 | 151,396 | 149,764 |
| `#pio`, dynamic operand | 37,238 | 13,204 | 151,436 | 149,804 |
| Native, dynamic operand | 37,238 | 13,204 | 151,436 | 149,804 |
| `#constPIO`, captured label | 28,926 | 10,303 | 141,716 | 140,196 |

The static instruction column counts all instructions emitted into the
relocatable probe, including helper bodies. It is **not** executed CPU
instructions, cycles, or a call-path count. The probe excludes external runtime
implementations; the linked image includes the retained SDK/runtime graph.
Flash is the load-image `.bin` size, including alignment, not ELF file size.

The section experiment passes `-Xfrontend -function-sections` to the Swift probe
(and function/data sections to C). It does not change library or example defaults.
It is important to keep the empty baseline: without that flag, even the empty
Swift probe retains allocator/runtime code and substantially enlarges this
specific SDK harness. That is not all PIO overhead.

With function sections, `#constPIO` is 232 flash bytes above the C table in this
fixture. Fully constant `#pio`, however, retains `_validated`, dictionary/string
helpers and their runtime dependencies despite having no runtime assembler or
encoder. Captured-label `#constPIO` retains a similar graph. The existing empty-
bindings fast path in `_validated` does not make its out-of-line implementation
disappear. This is a concrete optimization target, not an inherent cost of PIO.

The dynamic Embedded `#pio` and native operand cases have identical object text
sizes here. Macro folding guarantees pre-encoding before Swift optimization;
it does not guarantee smaller machine code than the optimizer can derive from
native constant instruction constructors. A remaining dynamic instruction also
keeps the general encoder reachable.

`-Osize` reduces the function-section fully constant `#pio` image to 136,052
bytes and its dynamic-operand image to 143,788 bytes; `#constPIO` is 5,924 bytes.
The large retention issue is not resolved merely by optimizing for size.

Static SRAM, with function sections, is 1,140 bytes for the C fixture, 1,264 for
`#constPIO`, 10,756 for constant `#pio`, and 11,196 for dynamic-operand `#pio`.
These totals include RAM-resident code, vectors, data and BSS. They exclude
the linker's heap/stack reservations and actual dynamic heap/maximum stack use.
The JSON also records each SRAM section. Berkeley `data + bss` alone is
misleading in this harness because executable `.data` contains RAM-resident code.

The original application's Swift archive is **not** linked. The script builds
an isolated archive containing only its `CPicoSDK` and `CShims` runtime objects.
Otherwise weak Swift runtime symbols can pull complete application objects back
into the benchmark even though the application's entry point is unused. The
saved archive-member list, link command and map make that isolation auditable.

### What dead-code elimination removed

- Embedded `#constPIO` without captured labels retains no assembler or encoder.
  Its words and some literal-storage support remain when used.
- The hand-written Swift data literal's unused-result probe collapses to the
  empty baseline. The current macro-generated unused `#constPIO` does not fully
  collapse: with function sections it is 5,788 flash bytes versus 5,556 empty.
- Unused constant `#pio` retains its wrapper graph (139,620 flash bytes at `-O`
  with function sections). Unused dynamic programs retain assembly work; unused
  does not imply that validation and potentially observable behavior can vanish.
- Consuming words only versus all fields is reported separately. Ignoring label
  metadata does not by itself remove captured-label construction.
- Ordinary, non-Embedded Swift has a different retention profile. Linking the
  PIO/ConstExpr library objects retains about 374 KB of host machine-code text
  even in the empty control, including registration/type support. The clean Swift
  control, linked without those objects, has 500 bytes of text. Do not interpret
  the host executable size or a retained symbol as the runtime cost of a call,
  or extrapolate either to firmware flash. Host dylibs are excluded from sizes.

## Reproduce

Requires macOS, Python 3, Xcode command-line tools, Swift 6.3+, sibling
`swift-constexpr`, and the pinned pioasm from the root README's verification
instructions. Embedded runs additionally need an up-to-date release PicoAudio
(or compatible CPicoSDK consumer) build. Nothing installs tools or flashes a
board. All generated sources and outputs go under ignored `.build/benchmarks/`.

From the repository root:

```sh
# Builds optimized host dependencies, verifies every probe, then measures it.
python3 Scripts/Benchmarks/run.py

# Re-measure existing binaries without interleaving compilation and timing.
python3 Scripts/Benchmarks/run.py --retime --timing-processes 3

# Reuse an already-built Embedded consumer's compiler, module paths and flags.
python3 Scripts/Benchmarks/embedded.py \
  --firmware-package Examples/PicoAudio --module PicoAudio \
  --triple armv7em-none-none-eabi

# Reuse its existing SDK link harness, with a replacement application main.
python3 Scripts/Benchmarks/link_firmware.py \
  --cmake-build Examples/PicoAudio/.build/plugins/FinalizeBinaryPlugin/outputs/CMakeHarness/build_pico2 \
  --module PicoAudio --function-sections

# Complete paired matrix: use the same profile for empty and PIO cases.
python3 Scripts/Benchmarks/embedded.py \
  --firmware-package Examples/PicoAudio --module PicoAudio \
  --runtime-profile common --output .build/benchmarks/complete-matrix-arm-common \
  --cases empty constpio constpio_captured pio pio_captured native native_captured \
    pio_operand pio_operand_captured native_operand native_operand_captured \
    pio_dynamic pio_dynamic_captured native_dynamic native_dynamic_captured \
  --optimizations O --consumption all

python3 Scripts/Benchmarks/link_firmware.py \
  --cmake-build Examples/PicoAudio/.build/plugins/FinalizeBinaryPlugin/outputs/CMakeHarness/build_pico2 \
  --module PicoAudio --probes .build/benchmarks/complete-matrix-arm-common \
  --output .build/benchmarks/complete-matrix-firmware-common \
  --cases empty constpio constpio_captured pio pio_captured native native_captured \
    pio_operand pio_operand_captured native_operand native_operand_captured \
    pio_dynamic pio_dynamic_captured native_dynamic native_dynamic_captured \
  --optimizations O --consumption all --function-sections --sdk-function-sections

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s Scripts/Benchmarks -p 'test_*.py' -v
```

The firmware harness must already exist; this script does not run its post-build
or programming rules. Paths/target flags come from the selected consumer. When
building the example with a toolchain whose default SwiftPM build system rejects
the bare-metal target, select `--build-system native` with its prepared toolset.

Use `--cases constpio pio pio_operand`, `--optimizations O`, and
`--consumption all` for a smaller matrix. `--skip-build` reuses host dependencies
only when they are current. `--retime` uses every binary in the existing report
and ignores matrix-selection arguments.

Both `run.py` (host) and `embedded.py` accept `--runtime-profile`. Use a separate
output directory per profile. `link_firmware.py` reads the selected profile and
support objects from the Embedded report, so it cannot silently omit that
workload. Its JSON/summary reports full sizes and deltas from the matching
`empty` case; a missing empty case produces no delta rather than a guessed zero.
`--sdk-function-sections` re-emits SDK Swift sources with `-O`, WMO, and per-function
sections into the benchmark directory, then builds an isolated SDK archive.
It never overwrites the consumer's modules, SDK sources, or firmware outputs.

### Cases and methodology

The default matrix has 28 cases × 2 optimization levels × 3 consumption modes:
168 isolated measured host executables and 168 Embedded objects. Captured cases
also get separate correctness executables. Firmware linking defaults to `all`
and `unused`, so its two section configurations produce 224 images.
The first host baseline predates the clean `empty_swift` control; its 114 cases
are in `host/`, with the six clean controls in `host-clean-baseline/`.

- `empty`: same host link dependencies, no PIO calls; `empty_swift`: no PIO link
  objects. Their Embedded probes are intentionally the same empty entry point.
- `pioasm_c` / `pioasm_swift`: static C words / equivalent Swift program data.
- `constpio` / `pio` / `native`: fully known body, created per call.
- `*_operand` / `*_side`: one masked runtime SET operand or side-set value.
- `pio_dynamic` / `native_dynamic`: all eight numeric operands, side-set values,
  and delays are runtime values; instruction kinds/count and options stay fixed.
- `*_branch`: an optional NOP and the corresponding shifted numeric jump target.
- `pio_side_labels`: dynamic side-set with two locally declared label handles.
- `*_stored`: private shared program initialized once.
- `*_captured`: a paired constant, one-operand, or all-dynamic case with one
  external entry handle bound at offset 7 on each construction. Reports record
  `captured_entrypoint`, `entrypoint_offset`, `entrypoint_lookup_consumed`,
  `all_dynamic_instruction_values`, and `runtime_opcode_selection` explicitly.
- `reference_*`: patch or select pioasm tables for the same valid input domain.

`Programs.pio` supplies real pioasm JSON for both original layouts. For the
all-dynamic fixture, the harness also generates `DynamicPrograms.pio`, assembles
all 64 input variants independently with pioasm, and saves `dynamic-reference.json`.
Each measured host executable checks all 64 inputs against expected words/metadata
before timing. Captured-entry checks run in separate verification executables;
their lookup code cannot keep extra work live in the measured binary. An external,
separately compiled C consumer reads actual instruction storage; no LTO is used,
so Swift cannot replace the program with a constant checksum. The C baseline uses
that same consumer. This does not include configuring or loading a state machine;
the separate `Scripts/Optimization` probes cover SDK configuration code shape.

Timing records one cold call, then 1,000 warm-up calls and seven batches. The
reported baseline was re-timed in three fresh processes per executable, taking
the median of 21 samples. Batch sizes adapt toward at least 20 ms, capped at five
million calls. No compiler work was run concurrently with that re-timing. The
host scheduler, frequency changes and timer resolution still introduce noise.
Very short first calls can round to zero; cold times are not process-launch time.

Reports also retain min/max samples, process peak RSS, allocation-symbol
references, static disassembly counts, a conservative direct-call reachability
walk on the host, stripped/unstripped sizes, section sizes, compiler flags,
Embedded object compile durations, LLVM IR, disassembly and link maps. Presence
of an allocation symbol is not an allocation count; peak RSS is process-wide.
Direct-call reachability omits indirect/dylib calls and is not dynamic tracing.
Compile durations include macro expansion, imports, optimization and emission,
with warm caches; they are not isolated macro-expansion time.

The three primary reports are:

```text
.build/benchmarks/host/{report.json,summary.md}
.build/benchmarks/armv7em-none-none-eabi/{report.json,summary.md}
.build/benchmarks/firmware/{report.json,summary.md}
```

## Remaining measurements and optimization targets

Not measured yet: on-board RP2040/RP2350 cycles, dynamically executed CPU
instructions, exact allocations/bytes per construction, peak stack/heap, power,
and invalid-path timing. ARM probes have been compiled and linked, not run.
The correctness tests exercise invalid inputs, but that is not a performance
measurement. A useful next stage is board cycle counters or instruction tracing,
plus allocator instrumentation around construction and first use.

Priorities suggested by these measurements, not implemented in this baseline:

1. Make the zero-label throwing wrapper specialize away without weakening
   `try #pio`'s contract or duplicate-label validation.
2. Reduce label/string/error-support retention and investigate the unused
   `#constPIO` literal's remaining initialization work.
3. Reduce builder-array/layout allocation and specialize residual encoding.
4. Evaluate function-level linker granularity with the actual consumer, and
   repeat the full matrix before claiming an improvement.

Preserve the empty, C, Swift-data and native controls when changing any of these;
otherwise unrelated runtime/linker effects can masquerade as PIO improvements.
