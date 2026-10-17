#!/usr/bin/env python3
"""Reproducible, isolated host benchmarks against real pioasm output.

All generated sources, executables, disassembly, maps, and reports live under
.build/benchmarks. Does not modify package sources, install tools, or flash a board.
"""
import argparse
import datetime
import json
import pathlib
import platform
import re
import shutil
import statistics
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
CASES = ["empty", "empty_swift", "pioasm_c", "pioasm_swift", "constpio", "pio", "native",
         "reference_operand", "pio_operand", "native_operand", "reference_side",
         "pio_side", "pio_side_labels", "native_side", "reference_branch",
         "pio_branch", "native_branch", "constpio_stored", "pio_stored", "constpio_captured",
         "pio_captured", "native_captured", "pio_operand_captured", "native_operand_captured",
         "pio_dynamic", "native_dynamic", "pio_dynamic_captured", "native_dynamic_captured"]
DYNAMIC_KINDS = ("out", "jmp", "out", "set", "out", "jmp", "out", "set")
BODY = """
    Out(.pins, 1).sideSet(value: 2)
    Jmp(.xDecrement, to: 0).sideSet(value: SIDE)
    Out(.pins, 1).sideSet(value: 0)
    Set(.x, OPERAND).sideSet(value: 1)
    EXTRA
    Out(.pins, 1).sideSet(value: 0)
    Jmp(.xDecrement, to: TARGET).sideSet(value: 1)
    Out(.pins, 1).sideSet(value: 2)
    ENTRY
    Set(.x, 14).sideSet(value: 3)
"""


def run(command, **kwargs):
    result = subprocess.run([str(part) for part in command], text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"Command failed: {' '.join(map(str, command))}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def case_details(case):
    variant = case.removesuffix("_captured")
    return {"captured_entrypoint": case.endswith("_captured"),
            "entrypoint_offset": 7 if case.endswith("_captured") else None,
            "entrypoint_lookup_consumed": False,
            "all_dynamic_instruction_values": variant.endswith("_dynamic"),
            "runtime_opcode_selection": False}


def dynamic_body():
    """Fixed instruction kinds/count; every operand, side value and delay varies."""
    lines = []
    for index, kind in enumerate(DYNAMIC_KINDS):
        if index == 7:
            lines.append("    ENTRY")
        value = f"Int((input &+ {index}) & {7 if kind == 'jmp' else 31})"
        instruction = {"out": f"Out(.pins, {value} + 1)",
                       "jmp": f"Jmp(.xDecrement, to: {value})",
                       "set": f"Set(.x, {value})"}[kind]
        lines.append(f"    {instruction}.sideSet(value: Int(((input >> 2) &+ {index}) & 3)).delay(Int(((input >> 3) &+ {index}) & 7))")
    return "\n".join(lines)


def dynamic_reference_source():
    """Generate independent pioasm input for the complete 64-value domain."""
    lines = []
    for value in range(64):
        lines += [f".program dynamic_{value}", ".side_set 2"]
        for index, kind in enumerate(DYNAMIC_KINDS):
            operand = (value + index) & (7 if kind == "jmp" else 31)
            instruction = {"out": f"out pins, {operand + 1}",
                           "jmp": f"jmp x--, {operand}",
                           "set": f"set x, {operand}"}[kind]
            lines.append(f"{instruction} side {((value >> 2) + index) & 3} [{((value >> 3) + index) & 7}]")
    return "\n".join(lines) + "\n"


def dynamic_reference(pioasm, output, cases):
    if not any(case_details(case)["all_dynamic_instruction_values"] for case in cases):
        return None
    source = output / "DynamicPrograms.pio"
    source.write_text(dynamic_reference_source())
    reference = output / "dynamic-reference.json"
    run([pioasm.resolve(), "-o", "json", source, reference])
    return {int(program["name"].split("_")[-1]): [int(word["hex"], 16) for word in program["instructions"]]
            for program in json.loads(reference.read_text())["programs"]}


def source(case, words, extra_words):
    if case.startswith("empty"):
        return '@_cdecl("benchmark_step") public func benchmarkStep(_ input: UInt32) -> UInt64 { UInt64(input) }\n'
    variant = case.removesuffix("_captured")
    body = dynamic_body() if variant.endswith("_dynamic") else BODY
    body = body.replace("SIDE", "Int(input & 3)" if variant.endswith("side") or case == "pio_side_labels" else "3")
    body = body.replace("OPERAND", "Int(input & 31)" if variant.endswith("operand") else "14")
    body = body.replace("EXTRA", "if input & 1 != 0 { Nop().sideSet(value: 0) }" if variant.endswith("branch") else "")
    body = body.replace("TARGET", "input & 1 != 0 ? 5 : 4" if variant.endswith("branch") else "4")
    body = body.replace("ENTRY", "Label(entry)" if case.endswith("_captured") else "")
    if case == "pio_side_labels":
        body = "@PIOLabel var loop1\n@PIOLabel var loop0\nLabel(loop1)\n" + body
        body = body.replace("to: 0", "to: loop1").replace("to: 4", "to: loop0")
        body = body.replace("    Out(.pins, 1).sideSet(value: 0)\n    Jmp", "    Label(loop0)\n    Out(.pins, 1).sideSet(value: 0)\n    Jmp")
    kind = "#constPIO" if case.startswith("constpio") else "#pio"
    expression = f"{kind}(sideSet: .init(bits: 2)) {{\n{body}}}"
    if case.startswith("native"):
        expression = f"PIOAssembler.assemble(options: .init(sideSet: .init(bits: 2))) {{\n{body}}}"
    expression = ("" if kind == "#constPIO" and not case.startswith("native") else "try ") + expression
    globals_ = "let entry = PIOLabelHandle()\n" if case.endswith("_captured") else ""
    make = "return " + expression
    if case.endswith("stored"):
        globals_ += f"private let stored: PIOProgramData = {{ () -> PIOProgramData in\n do {{ return {expression} }} catch {{ fatalError() }}\n}}()\n" if kind == "#pio" else f"private let stored = {expression}\n"
        make = "return stored"
    if case == "pioasm_swift" or case.startswith("reference_"):
        initial = f"{extra_words} : {words}" if case == "reference_branch" else str(words)
        initial = "input & 1 != 0 ? " + initial if case == "reference_branch" else initial
        change = ""
        if case == "reference_operand": change = "words[3] = (words[3] & ~UInt16(31)) | UInt16(input & 31)"
        if case == "reference_side": change = "words[1] = (words[1] & ~UInt16(0x1800)) | UInt16(input & 3) << 11"
        make = f"""{'var' if change else 'let'} words: [UInt16] = {initial}
        {change}
        return PIOProgramData(instructions: words, sideSet: .init(bits: 2), wrap: words.count - 1)"""
    capture_check = """#if BENCH_HOST_CHECKS
@_cdecl("benchmark_verify_capture")
public func benchmarkVerifyCapture() {
    for input in UInt32(0)..<64 {
        do {
            let program = try makeProgram(input)
            precondition(program.labels[entry] == 7 && program.labels.count == 1)
        } catch { preconditionFailure("Captured-entry fixture failed to assemble") }
    }
}
#endif
""" if case.endswith("_captured") else ""
    return f"""import RP2xxxPIO
import BenchmarkSupport
{globals_}
private func makeProgram(_ input: UInt32) throws(PIOAssemblyError) -> PIOProgramData {{
    {make}
}}
{capture_check}
@_cdecl("benchmark_step")
@inline(never)
public func benchmarkStep(_ input: UInt32) -> UInt64 {{
    do {{
        let program = try makeProgram(input)
        #if BENCH_UNUSED
        _ = program
        return UInt64(input)
        #else
        return program.instructions.withUnsafeBufferPointer {{ words in
            #if BENCH_WORDS
            benchmark_consume(words.baseAddress, UInt32(words.count), 0, 0, 0, 0, 0, input)
            #else
            benchmark_consume(words.baseAddress, UInt32(words.count), UInt32(program.wrapTarget),
                              UInt32(program.wrap), UInt32(program.usedGPIORanges),
                              UInt32(program.fifoRequirements.rawValue), UInt32(program.sideSet?.bits ?? 0), input)
            #endif
        }}
        #endif
    }} catch {{ return UInt64.max }}
}}
"""


def digest(case, consumption, input_, base, extra, dynamic_words=None):
    if case.startswith("empty") or consumption == "unused": return input_
    variant = case.removesuffix("_captured")
    if variant.endswith("_dynamic"):
        if dynamic_words is None:
            raise ValueError("All-dynamic cases require independently assembled pioasm words")
        words = list(dynamic_words[input_ & 63])
    else:
        words = list(extra if variant.endswith("branch") and input_ & 1 else base)
    if variant.endswith("operand"): words[3] = words[3] & ~31 | input_ & 31
    if variant.endswith("side") or case == "pio_side_labels": words[1] = words[1] & ~0x1800 | (input_ & 3) << 11
    fields = [len(words), 0, len(words) - 1, 0, 0, 2] if consumption == "all" else [len(words), 0, 0, 0, 0, 0]
    hash_ = input_
    for value in words + fields: hash_ = (hash_ * 33 + value) & ((1 << 64) - 1)
    return hash_


def inspect(binary, output):
    assembly = run(["xcrun", "llvm-objdump", "-d", "--no-show-raw-insn", binary])
    (output / "disassembly.txt").write_text(assembly)
    functions = {}
    current = None
    for line in assembly.splitlines():
        label = re.match(r"^[0-9a-f]+ <(.+)>:$", line)
        if label:
            current = label[1]
            functions[current] = []
        elif current and re.match(r"^\s*[0-9a-f]+:\s+\w", line):
            functions[current].append(line)
    root = "_benchmark_step" if "_benchmark_step" in functions else "benchmark_step"
    pending, seen = [root], set()
    while pending:
        name = pending.pop()
        if name in seen or name not in functions: continue
        seen.add(name)
        for line in functions[name]:
            # Do not mistake an address-forming instruction's nearest symbol
            # annotation for a call edge. Indirect calls remain unaccounted for.
            if not re.search(r":\s+(?:b(?:\.[a-z]+)?|bl|blr|br|cbz|cbnz|tbz|tbnz)\s", line): continue
            for target in re.findall(r"<([^>]+)>", line):
                target = target.split("+0x")[0]
                if target in functions and target not in seen: pending.append(target)
    sizes = run(["xcrun", "size", "-m", binary])
    (output / "sections.txt").write_text(sizes)
    sections = {name: int(size) for name, size in re.findall(r"Section (\S+):\s+(\d+)", sizes)}
    symbols = run(["xcrun", "nm", "-j", binary])
    demangled = run(["xcrun", "swift-demangle", "--compact"], input=symbols)
    (output / "symbols.txt").write_text(demangled)
    stripped = output / "benchmark.stripped"
    shutil.copyfile(binary, stripped)
    run(["xcrun", "strip", "-S", "-x", stripped])
    return {
        "file_bytes": binary.stat().st_size, "stripped_file_bytes": stripped.stat().st_size,
        "sections": sections, "text_bytes": sections.get("__text", 0),
        "image_static_instructions": sum(map(len, functions.values())),
        "step_direct_reachable_static_instructions": sum(len(functions[name]) for name in seen),
        "step_direct_reachable_functions": sorted(seen),
        "assembler_retained": "PIOAssembler.assemble(" in demangled or "PIOAssembly.assemble(" in demangled,
        "encoder_retained": "PIOEncoder.encode(" in demangled,
        "builder_retained": "PIOBuilder.build" in demangled,
        "allocation_symbol_references": sorted({line for line in demangled.splitlines()
            if re.search(r"swift_(alloc|slowAlloc)|(?:^|_)malloc|calloc|realloc", line)}),
        "dynamic_libraries": run(["xcrun", "otool", "-L", binary]).splitlines()[1:],
    }


def write_summary(report, output):
    lines = ["# Host benchmark results", "", f"Machine: {report['processor']}", "", report["method"], "",
             "| Optimization | Consumption | Case | Median ns/call | Text bytes | Stripped file bytes | Assembler retained |",
             "|---|---|---|---:|---:|---:|---|"]
    for item in report["results"]:
        lines.append(f"| {item['optimization']} | {item['consumption']} | {item['case']} | {item['median_ns']:.2f} | {item['text_bytes']} | {item['stripped_file_bytes']} | {item['assembler_retained']} |")
    lines += ["", "## Limits", ""] + ["- " + limit for limit in report["limits"]]
    (output / "summary.md").write_text("\n".join(lines) + "\n")


def retime(output, iterations, processes):
    report = json.loads((output / "report.json").read_text())
    report["retimed_at_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    report["timing_processes"] = processes
    report["method"] += f" Retimed existing binaries in {processes} processes each, without harness compilation; adaptive minimum 20 ms target per sample (capped at 5M iterations)."
    for item in report["results"]:
        directory = output / f"{item['optimization']}-{item['consumption']}-{item['case']}"
        count = max(iterations, min(5000000, int(20000000 / max(item["median_ns"], 1))))
        measurements = [json.loads(run([directory / "benchmark", str(count)])) for _ in range(processes)]
        samples = [sample for measurement in measurements for sample in measurement["samples_ns_per_call"]]
        item.update({"median_ns": statistics.median(samples), "min_ns": min(samples), "max_ns": max(samples),
                     "samples_ns_per_call": samples, "timing_iterations": count,
                     "cold_first_call_ns": statistics.median(m["cold_first_call_ns"] for m in measurements),
                     "cold_first_calls_ns": [m["cold_first_call_ns"] for m in measurements],
                     "peak_rss_bytes": max(m["peak_rss_bytes"] for m in measurements),
                     "checksum": measurements[0]["checksum"]})
        if len({m["checksum"] for m in measurements}) != 1: raise RuntimeError("Checksum changed between timing processes")
        item.update(inspect(directory / "benchmark", directory))
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"{item['optimization']:5s} {item['consumption']:6s} {item['case']:20s} {item['median_ns']:10.2f} ns", flush=True)
    write_summary(report, output)


def main():
    from runtime_support import PROFILES, compile_support
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pioasm", type=pathlib.Path, default=ROOT / ".build/pioasm-reference/build/pioasm")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / ".build/benchmarks/host")
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    parser.add_argument("--optimizations", nargs="+", choices=["O", "Osize", "Onone"], default=["O", "Osize"])
    parser.add_argument("--consumption", nargs="+", choices=["all", "words", "unused"], default=["all", "words", "unused"])
    parser.add_argument("--iterations", type=int, default=100000)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--runtime-profile", choices=PROFILES, default="none",
                        help="Keep shared runtime support live, initialized before timing; use the same profile for empty and PIO cases")
    parser.add_argument("--retime", action="store_true", help="Measure existing report binaries without compiling; ignore matrix-selection options")
    parser.add_argument("--timing-processes", type=int, default=3, help="Fresh timing processes per binary with --retime")
    args = parser.parse_args()
    if platform.system() != "Darwin": parser.error("This initial harness uses macOS tooling; it does not report on-device timings.")
    if args.iterations <= 0 or args.timing_processes <= 0: parser.error("Iteration and process counts must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if args.retime:
        retime(output, args.iterations, args.timing_processes)
        return
    if not args.skip_build:
        print("Building optimized host modules...", flush=True)
        run(["swift", "build", "-c", "release"], cwd=ROOT)
    build = pathlib.Path(run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=ROOT).strip())
    objects = sorted((build / "RP2xxxPIOCore.build").glob("*.o")) + sorted((build / "ConstExpr.build").glob("*.o"))
    if not objects or not (build / "RP2xxxPIOMacros-tool").exists(): parser.error("Missing release modules; run without --skip-build")
    reference = output / "reference.json"
    run([args.pioasm.resolve(), "-o", "json", HERE / "Programs.pio", reference])
    reference_data = json.loads(reference.read_text())
    programs = {item["name"]: item for item in reference_data["programs"]}
    words = [int(item["hex"], 16) for item in programs["bench_base"]["instructions"]]
    extra = [int(item["hex"], 16) for item in programs["bench_extra"]["instructions"]]
    dynamic_words = dynamic_reference(args.pioasm, output, args.cases)
    (output / "module.modulemap").write_text(f'module BenchmarkSupport {{ header "{HERE / "Support.h"}" export * }}\n')
    driver = output / "driver.o"
    run(["xcrun", "clang", "-O2", *(["-DBENCH_RUNTIME_SUPPORT"] if args.runtime_profile != "none" else []),
         "-c", HERE / "Driver.c", "-o", driver])
    report = {
        "timestamp_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "machine": platform.platform(), "processor": run(["sysctl", "-n", "machdep.cpu.brand_string"]).strip(),
        "swift": run(["xcrun", "swiftc", "--version"]).strip(),
        "git_head": run(["git", "rev-parse", "HEAD"], cwd=ROOT).strip(),
        "git_status": run(["git", "status", "--short"], cwd=ROOT),
        "runtime_profile": args.runtime_profile,
        "pioasm": str(args.pioasm.resolve()), "reference": reference_data,
        "dynamic_reference": dynamic_words,
        "iterations": args.iterations, "library_optimization": "SwiftPM release (-O)",
        "method": "Isolated executables; separate C sink; no LTO; seven warmed samples; per-process cold first call; dead stripping enabled.",
        "limits": ["Host wall time, not RP2040/RP2350 cycles or PIO execution speed.",
                   "Instruction counts are static disassembly counts, not executed instructions. Direct reachability misses indirect and dylib calls.",
                   "File sizes are macOS executables, not firmware flash use; dynamic-library sizes are excluded.",
                   "Peak RSS is process-wide. Allocation symbol references are not allocation counts.",
                   "Cold first call includes timer overhead and lazy runtime initialization; not process launch time.",
                   "Dynamic reference baselines patch/select pioasm output; pioasm itself is not a runtime assembler.",
                   "Valid input domain is masked identically in all dynamic cases; invalid-input timings are not measured.",
                   "Captured-entry lookup is checked in a separate verification executable, not in measured binaries or timing intervals.",
                   "An optional runtime profile initializes before verification/timing, including the cold first PIO call; its initialization cost is not timed."],
        "results": [],
    }
    imports = ["-I", build / "Modules", "-I", output,
               "-load-plugin-executable", f"{build / 'RP2xxxPIOMacros-tool'}#RP2xxxPIOMacros"]
    for optimization in args.optimizations:
        support = compile_support(args.runtime_profile, optimization, output, ["xcrun", "swiftc"],
                                  ["-" + optimization, "-whole-module-optimization", "-parse-as-library", "-swift-version", "6", *imports])
        for consumption in args.consumption:
            for case in args.cases:
                directory = output / f"{optimization}-{consumption}-{case}"
                directory.mkdir(exist_ok=True)
                binary = directory / "benchmark"
                object_ = directory / "probe.o"
                defines = ["-D", "BENCH_" + consumption.upper()]
                if case == "pioasm_c":
                    csource = directory / "probe.c"
                    call = "return input;" if consumption == "unused" else f"return benchmark_consume(words, {len(words)}, 0, {len(words) - 1 if consumption == 'all' else 0}, 0, 0, {2 if consumption == 'all' else 0}, input);"
                    csource.write_text(f'#include "Support.h"\nstatic const uint16_t words[] = {{{", ".join(map(str, words))}}};\nuint64_t benchmark_step(uint32_t input) {{ {call} }}\n')
                    run(["xcrun", "clang", "-Os" if optimization == "Osize" else "-O0" if optimization == "Onone" else "-O2",
                         "-I", HERE, "-c", csource, "-o", object_])
                    link = ["xcrun", "swiftc" if support else "clang", object_, driver]
                else:
                    swift = directory / "probe.swift"
                    swift.write_text(source(case, words, extra))
                    compile_ = ["xcrun", "swiftc", "-" + optimization, "-whole-module-optimization", "-parse-as-library",
                                "-swift-version", "6", "-module-name", "PIOBenchConsumer", *defines, *imports, swift]
                    (directory / "compile-command.json").write_text(json.dumps(list(map(str, compile_)), indent=2))
                    run([*compile_, "-emit-object", "-o", object_])
                    run([*compile_, "-emit-ir", "-o", directory / "probe.ll"])
                    link = ["xcrun", "swiftc", object_, driver, *([] if case == "empty_swift" else objects)]
                swift_link = case != "pioasm_c" or support is not None
                link_flags = [*([support] if support else []), "-Xlinker" if swift_link else "-Wl,-dead_strip", *(["-dead_strip"] if swift_link else [])]
                run([*link, *link_flags, "-o", binary])
                actual = [int(value) for value in run([binary, "--verify"]).splitlines()]
                expected = [digest(case, consumption, index, words, extra, dynamic_words) for index in range(64)]
                if actual != expected: raise RuntimeError(f"Correctness check failed: {directory}\nactual={actual}\nexpected={expected}")
                if case_details(case)["captured_entrypoint"]:
                    check_object = directory / "verify-probe.o"
                    check_binary = directory / "benchmark-verify"
                    check_compile = [*compile_, "-D", "BENCH_HOST_CHECKS", "-emit-object", "-o", check_object]
                    (directory / "verify-compile-command.json").write_text(json.dumps(list(map(str, check_compile)), indent=2))
                    run(check_compile)
                    run(["xcrun", "swiftc", check_object, driver, *objects, *link_flags, "-o", check_binary])
                    checked = [int(value) for value in run([check_binary, "--verify"]).splitlines()]
                    if checked != expected: raise RuntimeError(f"Captured-entry correctness check failed: {directory}")
                measurement = json.loads(run([binary, str(args.iterations)]))
                samples = measurement["samples_ns_per_call"]
                result = {"case": case, **case_details(case), "optimization": optimization, "consumption": consumption,
                          "median_ns": statistics.median(samples), "min_ns": min(samples), "max_ns": max(samples),
                          **measurement, **inspect(binary, directory)}
                report["results"].append(result)
                (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
                print(f"{optimization:5s} {consumption:6s} {case:20s} {result['median_ns']:10.2f} ns  text={result['text_bytes']:7d} B  assembler={result['assembler_retained']}", flush=True)
    write_summary(report, output)
    print(output / "report.json", flush=True)


if __name__ == "__main__":
    main()
