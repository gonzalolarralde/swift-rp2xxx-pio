#!/usr/bin/env python3
"""Count executed Cortex-M33 instructions from construction to SDK-ready.

Requires the pinned requirements-instructions.txt environment and an existing
Embedded/linked benchmark matrix. Writes only to the requested benchmark output;
does not flash a board, change SDK sources, or replace the guest allocator.
"""
import argparse
import datetime
import hashlib
import json
import pathlib
import statistics

from run import ROOT, HERE, case_details, digest, dynamic_reference, run, source
from instruction_emulator import Image, Machine, ExecutionError, calibrate

PAIRED_CASES = ["constpio", "constpio_captured", "pio", "pio_captured", "native", "native_captured",
                "pio_operand", "pio_operand_captured", "native_operand", "native_operand_captured",
                "pio_dynamic", "pio_dynamic_captured", "native_dynamic", "native_dynamic_captured"]
EXPORTS = ["benchmark_path", "benchmark_construct", "benchmark_prepare", "benchmark_ready",
           "benchmark_storage_size", "benchmark_label_count", "benchmark_entry", "benchmark_verify",
           "benchmark_destroy", "runtime_init_mutex", "runtime_init_spin_locks_reset"]


def instruction_source(case, words, extra):
    prefix = source(case, words, extra).split('@_cdecl("benchmark_step")', 1)[0]
    entry = "Int32(program.labels[entry] ?? -1)" if case_details(case)["captured_entrypoint"] else "-1"
    return prefix + f"""
import InstructionSupport
import CPicoSDK

@_cdecl("benchmark_storage_size")
public func benchmarkStorageSize() -> UInt32 {{ UInt32(MemoryLayout<PIOProgramData>.size) }}

@_cdecl("benchmark_construct")
public func benchmarkConstruct(_ input: UInt32, _ output: UnsafeMutableRawPointer) -> UInt32 {{
    do {{
        output.assumingMemoryBound(to: PIOProgramData.self).initialize(to: try makeProgram(input))
        return 1
    }} catch {{ return 0 }}
}}

@_cdecl("benchmark_prepare")
public func benchmarkPrepare(_ storage: UnsafeRawPointer) -> UInt32 {{
    storage.assumingMemoryBound(to: PIOProgramData.self).pointee.withCProgram {{ descriptor in
        benchmark_ready(UnsafeRawPointer(descriptor))
    }}
}}

@_cdecl("benchmark_verify")
public func benchmarkVerify(_ storage: UnsafeRawPointer, _ input: UInt32) -> UInt64 {{
    let program = storage.assumingMemoryBound(to: PIOProgramData.self).pointee
    return program.instructions.withUnsafeBufferPointer {{ words in
        benchmark_consume(words.baseAddress, UInt32(words.count), UInt32(program.wrapTarget),
                          UInt32(program.wrap), UInt32(program.usedGPIORanges),
                          UInt32(program.fifoRequirements.rawValue), UInt32(program.sideSet?.bits ?? 0), input)
    }}
}}

@_cdecl("benchmark_label_count")
public func benchmarkLabelCount(_ storage: UnsafeRawPointer) -> UInt32 {{
    UInt32(storage.assumingMemoryBound(to: PIOProgramData.self).pointee.labels.count)
}}

@_cdecl("benchmark_entry")
public func benchmarkEntry(_ storage: UnsafeRawPointer) -> Int32 {{
    let program = storage.assumingMemoryBound(to: PIOProgramData.self).pointee
    return {entry}
}}

@_cdecl("benchmark_destroy")
public func benchmarkDestroy(_ storage: UnsafeMutableRawPointer) {{
    storage.assumingMemoryBound(to: PIOProgramData.self).deinitialize(count: 1)
}}
"""


def software_math_link(command):
    """Keep malloc/free wrappers, but use real libgcc ARM AEABI implementations.

    RP2350 DCP coprocessor instructions are not supported by this CPU emulator.
    Removing these linker redirects does not replace guest functions with host
    shortcuts: all software helpers execute and are counted as ARM code.
    """
    return [part for part in command if not part.startswith("-Wl,--wrap=__aeabi_")]


def build(case, optimization, args, words, extra):
    original = args.firmware_report / f"{optimization}-all-{case}-function-sections"
    directory = args.output / f"{optimization}-{case}"
    directory.mkdir(parents=True, exist_ok=True)
    command = json.loads((original / "compile-command.json").read_text())
    old_source = next(part for part in command if part.endswith("/probe.swift"))
    old_module_dir = str(pathlib.Path(old_source).parent.parent)
    swift = directory / "probe.swift"
    swift.write_text(instruction_source(case, words, extra))
    object_ = directory / "probe.o"
    command = [str(swift) if part == old_source else str(args.output) if part == old_module_dir else part for part in command]
    command[command.index("-o") + 1] = str(object_)
    (directory / "compile-command.json").write_text(json.dumps(command, indent=2) + "\n")
    run(command, cwd=args.cmake_build)
    ir_command = ["-emit-ir" if part == "-emit-object" else part for part in command]
    ir_command[ir_command.index("-o") + 1] = str(directory / "probe.ll")
    run(ir_command, cwd=args.cmake_build)

    original_link = json.loads((original / "link-command.json").read_text())
    compiler = original_link[0]
    driver = args.output / "driver.o"
    driver_command = [compiler, "-x", "c", "-mcpu=cortex-m33", "-mthumb", "-march=armv8-m.main+fp+dsp",
                      "-mfloat-abi=softfp", "-mcmse", "-O2", "-ffunction-sections", "-fdata-sections",
                      "-I", str(HERE), "-c", str(HERE / "InstructionDriver.c"), "-o", str(driver)]
    (args.output / "driver-compile-command.json").write_text(json.dumps(driver_command, indent=2) + "\n")
    run(driver_command)
    link = software_math_link(original_link)
    link = [str(object_) if part == str(original / "probe.o") else
            str(driver) if part == str(args.firmware_report / "driver.o") else
            f"-Wl,-Map={directory / 'benchmark.map'}" if part.startswith("-Wl,-Map=") else part
            for part in link if "-runtime-support" not in part]
    elf = directory / "benchmark.elf"
    link[link.index("-o") + 1] = str(elf)
    link += ["-Wl,--undefined=" + name for name in EXPORTS]
    (directory / "link-command.json").write_text(json.dumps(link, indent=2) + "\n")
    run(link, cwd=args.cmake_build)
    (directory / "disassembly.txt").write_text(run(["xcrun", "llvm-objdump", "-d", "--no-show-raw-insn", elf]))
    (directory / "symbols.txt").write_text(run(["xcrun", "swift-demangle", "--compact"], input=run(["xcrun", "llvm-nm", elf])))
    return elf, compiler


def measure(image, case, input_, warm_runs, base, extra, dynamic):
    machine = Machine(image)
    storage_size = machine.initialize()
    samples = []
    for repetition in range(warm_runs + 1):
        machine.cpu.mem_write(machine.storage, bytes([0xa5]) * machine.STORAGE_CAPACITY)
        result = machine.call("benchmark_path", input_, machine.storage, track_path=True)
        if result["r0"] != 1:
            raise ExecutionError(f"Construction failed for {case}, input {input_}")
        expected = digest(case, "all", input_, base, extra, dynamic)
        verified = machine.call("benchmark_verify", machine.storage, input_)
        checksum = verified["r0"] | verified["r1"] << 32
        if checksum != expected:
            raise ExecutionError(f"PIO words/metadata mismatch: {case}, input {input_}: {checksum} != {expected}")
        labels = machine.call("benchmark_label_count", machine.storage)["r0"]
        captured = case_details(case)["captured_entrypoint"]
        if labels != int(captured):
            raise ExecutionError(f"Captured label count mismatch: {case}: {labels}")
        lookup = machine.call("benchmark_entry", machine.storage)
        expected_entry = 7 if captured else 0xffffffff
        if lookup["r0"] != expected_entry:
            raise ExecutionError(f"Captured entrypoint mismatch: {case}: {lookup['r0']}")
        descriptor = result["descriptor"]
        expected_words = list(dynamic[input_] if case.removesuffix("_captured").endswith("_dynamic") else base)
        if case.removesuffix("_captured").endswith("_operand"):
            expected_words[3] = expected_words[3] & ~31 | input_ & 31
        if descriptor != {"words": expected_words, "count": 8, "origin": -1, "version": 0, "gpio": 0}:
            raise ExecutionError(f"SDK descriptor mismatch: {case}, input {input_}: {descriptor}")
        guard = bytes(machine.cpu.mem_read(machine.storage + storage_size, machine.STORAGE_CAPACITY - storage_size))
        if guard != bytes([0xa5]) * len(guard):
            raise ExecutionError("Program construction overwrote caller storage")
        samples.append({"input": input_, "phase": "first_use" if repetition == 0 else "warm",
                        "repetition": repetition, "to_data": result["to_data"], "to_sdk": result["to_sdk"],
                        "descriptor_increment": result["to_sdk"] - result["to_data"],
                        "entry_lookup": lookup["instructions"] if captured else None,
                        "verified_checksum": checksum})
        machine.call("benchmark_destroy", machine.storage)
    return {"samples": samples, "storage_size": storage_size, "bootstrap": machine.bootstrap,
            "sio_reads": {f"{offset:#x}/{size}": count for (offset, size), count in machine.sio_reads.items()}}


def summarize(samples):
    result = {}
    for phase in ("first_use", "warm"):
        selected = [sample for sample in samples if sample["phase"] == phase]
        result[phase] = {}
        for key in ("to_data", "to_sdk", "descriptor_increment", "entry_lookup"):
            values = [sample[key] for sample in selected if sample[key] is not None]
            result[phase][key] = ({"min": min(values), "median": statistics.median(values), "max": max(values)}
                                  if values else None)
    return result


def format_range(value):
    if value is None:
        return "—"
    return str(value["min"]) if value["min"] == value["max"] else f"{value['min']}–{value['max']} (median {value['median']:g})"


def write_summary(report, output):
    lines = ["# Executed ARM instruction counts", "", report["method"], "",
             "All cells count dynamically executed guest instructions, not cycles or static code size.", "",
             "| Case | First use: data ready | First use: SDK ready | Warm: data ready | Warm: SDK ready | Warm entry lookup (separate) |",
             "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for row in report["results"]:
        stats = row["counts"]
        values = [stats[phase][key] for phase, key in (("first_use", "to_data"), ("first_use", "to_sdk"),
                  ("warm", "to_data"), ("warm", "to_sdk"), ("warm", "entry_lookup"))]
        lines.append("| " + row["case"] + " | " + " | ".join(map(format_range, values)) + " |")
    lines += ["", "## Scope and limits", ""] + ["- " + limit for limit in report["limits"]]
    (output / "summary.md").write_text("\n".join(lines) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firmware-report", type=pathlib.Path, default=ROOT / ".build/benchmarks/complete-matrix-firmware-common")
    parser.add_argument("--cmake-build", type=pathlib.Path, default=ROOT / "Examples/PicoAudio/.build/plugins/FinalizeBinaryPlugin/outputs/CMakeHarness/build_pico2")
    parser.add_argument("--pioasm", type=pathlib.Path, default=ROOT / ".build/pioasm-reference/build/pioasm")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / ".build/benchmarks/instruction-count-arm")
    parser.add_argument("--cases", nargs="+", choices=PAIRED_CASES, default=PAIRED_CASES)
    parser.add_argument("--optimization", choices=["O", "Osize"], default="O")
    parser.add_argument("--inputs", type=int, nargs="+", default=list(range(64)))
    parser.add_argument("--warm-runs", type=int, default=3)
    parser.add_argument("--skip-build", action="store_true", help="Reuse this output directory's already-built instruction probes")
    args = parser.parse_args()
    if args.warm_runs < 1 or any(value not in range(64) for value in args.inputs):
        parser.error("Use positive warm runs and inputs in 0...63")
    for field in ("firmware_report", "cmake_build", "pioasm", "output"):
        setattr(args, field, getattr(args, field).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "module.modulemap").write_text(
        f'module BenchmarkSupport {{ header "{HERE / "Support.h"}" export * }}\n'
        f'module InstructionSupport {{ header "{HERE / "InstructionSupport.h"}" export * }}\n')
    reference = args.output / "reference.json"
    run([args.pioasm, "-o", "json", HERE / "Programs.pio", reference])
    programs = {item["name"]: [int(word["hex"], 16) for word in item["instructions"]]
                for item in json.loads(reference.read_text())["programs"]}
    base, extra = programs["bench_base"], programs["bench_extra"]
    dynamic = dynamic_reference(args.pioasm, args.output, args.cases)
    compiler = json.loads((args.firmware_report / f"{args.optimization}-all-{args.cases[0]}-function-sections/link-command.json").read_text())[0]
    template = args.firmware_report / f"{args.optimization}-all-{args.cases[0]}-function-sections"
    swift_compiler = json.loads((template / "compile-command.json").read_text())[0]
    original_link = json.loads((template / "link-command.json").read_text())
    sdk_archive = next(pathlib.Path(part) for part in original_link if part.endswith("/sdk-runtime.a"))
    calibration = args.output / "calibration.elf"
    run([compiler, "-x", "assembler-with-cpp", "-mcpu=cortex-m33", "-mthumb", "-nostdlib",
         "-Ttext=0x10001000", "-Wl,-e,calibration_plain", HERE / "InstructionCalibration.S", "-o", calibration])
    calibration_results = calibrate(calibration)
    print("Instruction-counter calibration passed (loops, calls, both IT paths, memory, faults, guest errors).", flush=True)
    import unicorn
    report = {"timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "emulator": "Unicorn " + unicorn.__version__, "cpu": "Cortex-M33", "core_count": 1,
              "optimization": args.optimization, "inputs": args.inputs, "warm_runs": args.warm_runs,
              "swift_compiler": run([swift_compiler, "--version"]).strip(),
              "linker_toolchain": run([compiler, "--version"]).splitlines()[0],
              "sdk_runtime_archive": str(sdk_archive),
              "sdk_runtime_archive_sha256": hashlib.sha256(sdk_archive.read_bytes()).hexdigest(),
              "software_math_unwrapped_symbols": [part.split("=", 1)[1] for part in original_link
                                                   if part.startswith("-Wl,--wrap=__aeabi_")],
              "entropy_provider": "Benchmark-only deterministic ARM _getentropy; complete newlib arc4random and Swift hash seeding still execute",
              "git_head": run(["git", "rev-parse", "HEAD"], cwd=ROOT).strip(),
              "git_status": run(["git", "status", "--short"], cwd=ROOT),
              "calibration": calibration_results,
              "method": f"A: first instruction of benchmark_path. Intermediate: return from benchmark_construct with an owning PIOProgramData in caller storage. B: entry to benchmark_ready with the real withCProgram SDK descriptor, before executing the callback. Single Cortex-M33; interrupts masked; all callees counted. Each input starts with a fresh initialized image, then {args.warm_runs} repeated construct/destroy runs reuse that image.",
              "limits": [
                  "Emulated architectural instruction counts, not wall time, clock cycles, or a hardware-retired-instruction PMU reading.",
                  "RP2350-specific AEABI floating-point linker wrappers are disabled: actual libgcc software helpers execute in the guest instead of unsupported DCP coprocessor code. These are not exact native-DCP Pico 2 instruction counts.",
                  "A benchmark-only deterministic _getentropy implementation replaces the SDK's failing weak entropy stub. It executes as counted guest code; full newlib arc4random/Swift hash initialization is retained. This is not a production/security entropy source or a measurement of real hardware RNG latency.",
                  "The real CPicoSDK allocator, newlib heap, ARC helpers, software spinlocks and mutex implementations are retained and execute normally; no allocator is replaced by a host shortcut.",
                  "Only SIO_CPUID is modelled, as core 0. Every other MMIO access, CPU fault, or guest abort/assert/signal path invalidates the run. No asynchronous interrupts, second core, contention, flash/cache timing, or peripherals are simulated.",
                  "Memory sections and the real SDK spinlock/mutex initializers run before A. First-use means first program construction after this minimal runtime setup, not power-on-to-ready or full board boot.",
                  "Counts include the C/Swift benchmark ABI, materializing the complete owned data value, and SDK preparation. They are raw counts, not empty-baseline-subtracted or guaranteed to match a differently inlined application call site.",
                  "The result remains alive at B. Verification, result destruction and separately measured captured-entry lookup are excluded from readiness counts; destruction of intermediate construction temporaries is included.",
                  "IT itself is counted; instructions with failed IT predicates are not executed and are not counted. Every loop iteration and executed callee instruction is counted.",
                  "All samples must match real pioasm words, program metadata, SDK descriptor and captured label count/offset. No PIO loading, SM claiming/configuration/enabling, or PIO-machine execution is measured.",
                  "Compiler/library/heap layout and input affect counts. First-use is measured separately for every input; warmed ranges include every recorded repeat, not only the fastest one."],
              "results": []}
    for case in args.cases:
        if args.skip_build:
            elf = args.output / f"{args.optimization}-{case}/benchmark.elf"
        else:
            elf, _ = build(case, args.optimization, args, base, extra)
        image = Image.load(elf)
        samples = []
        for input_ in args.inputs:
            measured = measure(image, case, input_, args.warm_runs, base, extra, dynamic)
            samples += measured["samples"]
        result = {"case": case, **case_details(case), "elf": str(elf),
                  "entrypoint_lookup_measured_separately": case_details(case)["captured_entrypoint"],
                  "elf_sha256": hashlib.sha256(elf.read_bytes()).hexdigest(),
                  "probe_source_sha256": hashlib.sha256(elf.with_name("probe.swift").read_bytes()).hexdigest(),
                  "counts": summarize(samples), "samples": samples,
                  "program_storage_bytes": measured["storage_size"], "bootstrap": measured["bootstrap"]}
        report["results"].append(result)
        (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        write_summary(report, args.output)
        print(f"{case:26s} first SDK={format_range(result['counts']['first_use']['to_sdk'])}; warm SDK={format_range(result['counts']['warm']['to_sdk'])}", flush=True)
    print(args.output / "report.json", flush=True)


if __name__ == "__main__":
    main()
