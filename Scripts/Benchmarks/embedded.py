#!/usr/bin/env python3
"""Inspect isolated Embedded Swift probes using a real consumer's build flags.

Reports compiler-emitted ARM code/data and retained helpers, not board timings
or complete firmware size. Requires an up-to-date release consumer build.
"""
import argparse
import json
import pathlib
import re
import time

from run import CASES, HERE, ROOT, case_details, dynamic_reference, run, source
from runtime_support import PROFILES, compile_support


def compiler_flags(command, optimization):
    drop_single = {"-serialize-diagnostics", "-parseable-output", "-emit-objc-header", "-g", "-O", "-Osize", "-Onone"}
    drop_pair = {"-emit-objc-header-path", "-num-threads"}
    result = []
    arguments = iter(command["otherArguments"])
    for flag in arguments:
        if flag in drop_pair: next(arguments)
        elif flag in drop_single or flag.startswith("-j") or flag.startswith("-debug-info-format="): continue
        elif flag == "-Xcc":
            value = next(arguments)
            if value != "-g": result += [flag, value]
        else: result.append(flag)
    return result + ["-" + optimization]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firmware-package", type=pathlib.Path, required=True)
    parser.add_argument("--module", required=True)
    parser.add_argument("--triple", default="armv7em-none-none-eabi")
    parser.add_argument("--pioasm", type=pathlib.Path, default=ROOT / ".build/pioasm-reference/build/pioasm")
    parser.add_argument("--output", type=pathlib.Path)
    parser.add_argument("--runtime-profile", choices=PROFILES, default="none")
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    parser.add_argument("--optimizations", nargs="+", choices=["O", "Osize"], default=["O", "Osize"])
    parser.add_argument("--consumption", nargs="+", choices=["all", "words", "unused"], default=["all", "words", "unused"])
    args = parser.parse_args()
    firmware = args.firmware_package.resolve()
    description = json.loads((firmware / ".build" / args.triple / "release/description.json").read_text())
    command = next(item for item in description["swiftCommands"].values() if item["moduleName"] == args.module)
    output = args.output.resolve() if args.output else ROOT / ".build/benchmarks" / args.triple
    output.mkdir(parents=True, exist_ok=True)
    (output / "module.modulemap").write_text(f'module BenchmarkSupport {{ header "{HERE / "Support.h"}" export * }}\n')
    reference = output / "reference.json"
    run([args.pioasm.resolve(), "-o", "json", HERE / "Programs.pio", reference])
    reference_data = json.loads(reference.read_text())
    programs = {program["name"]: [int(item["hex"], 16) for item in program["instructions"]] for program in reference_data["programs"]}
    words, extra = programs["bench_base"], programs["bench_extra"]
    dynamic_words = dynamic_reference(args.pioasm, output, args.cases)
    report = {"triple": args.triple, "compiler": run([command["executable"], "--version"]).strip(),
              "runtime_profile": args.runtime_profile,
              "dynamic_reference": dynamic_words,
              "firmware_package": str(firmware), "source_module": args.module,
              "limits": ["Relocatable probe object sizes, not linked firmware size.",
                         "Static ARM instructions, not executed instruction counts or hardware cycles.",
                         "The external C consumer and allocator implementations are excluded.",
                         "Compile duration includes imports, macro expansion, optimization and object emission; caches affect it.",
                         "C reference is a static word table rendered from pinned pioasm JSON, not a runtime assembler."],
              "results": []}
    for optimization in args.optimizations:
        compile_support(args.runtime_profile, optimization, output, [command["executable"]],
                        ["-I", command["importPath"], "-I", output, *compiler_flags(command, optimization)], cwd=firmware)
        for consumption in args.consumption:
            for case in args.cases:
                directory = output / f"{optimization}-{consumption}-{case}"
                directory.mkdir(exist_ok=True)
                object_ = directory / "probe.o"
                if case == "pioasm_c":
                    input_ = directory / "probe.c"
                    call = "return input;" if consumption == "unused" else f"return benchmark_consume(words, {len(words)}, 0, {len(words) - 1 if consumption == 'all' else 0}, 0, 0, {2 if consumption == 'all' else 0}, input);"
                    input_.write_text(f'#include "Support.h"\nstatic const uint16_t words[] = {{{", ".join(map(str, words))}}};\nuint64_t benchmark_step(uint32_t input) {{ {call} }}\n')
                    compile_ = ["xcrun", "clang", "--target=" + args.triple, "-ffreestanding", "-I", HERE,
                                "-Os" if optimization == "Osize" else "-O2", "-c", input_, "-o", object_]
                else:
                    input_ = directory / "probe.swift"
                    input_.write_text(source(case, words, extra))
                    base = [command["executable"], "-module-name", "PIOBenchConsumer", "-I", command["importPath"],
                            "-I", output, "-D", "BENCH_" + consumption.upper(),
                            *compiler_flags(command, optimization), input_]
                    run([*base, "-emit-ir", "-o", directory / "probe.ll"], cwd=firmware)
                    compile_ = [*base, "-emit-object", "-o", object_]
                (directory / "compile-command.json").write_text(json.dumps(list(map(str, compile_)), indent=2))
                begin = time.perf_counter()
                run(compile_, cwd=firmware)
                compile_seconds = time.perf_counter() - begin
                assembly = run(["xcrun", "llvm-objdump", "-d", "--no-show-raw-insn", object_])
                (directory / "disassembly.txt").write_text(assembly)
                sizes = run(["xcrun", "llvm-size", "--format=sysv", object_])
                (directory / "sections.txt").write_text(sizes)
                sections = {name: int(size) for name, size in re.findall(r"^(\S+)\s+(\d+)\s+\d+\s*$", sizes, re.M) if name != "Total"}
                symbols = run(["xcrun", "swift-demangle", "--compact"], input=run(["xcrun", "llvm-nm", object_]))
                (directory / "symbols.txt").write_text(symbols)
                instructions = [line for line in assembly.splitlines() if re.match(r"^\s*[0-9a-f]+:\s+[a-z]", line)]
                result = {"case": case, **case_details(case), "optimization": optimization, "consumption": consumption,
                          "object_file_bytes": object_.stat().st_size, "sections": sections,
                          "text_bytes": sum(size for name, size in sections.items() if name == ".text" or name.startswith(".text.")),
                          "readonly_data_bytes": sum(size for name, size in sections.items() if name.startswith(".rodata")),
                          "writable_data_bytes": sum(size for name, size in sections.items() if name.startswith(".data")),
                          "bss_bytes": sum(size for name, size in sections.items() if name.startswith(".bss")),
                          "static_instructions": len(instructions), "consumer_object_compile_seconds": compile_seconds,
                          "assembler_retained": "PIOAssembler.assemble(" in symbols or "PIOAssembly.assemble(" in symbols,
                          "encoder_retained": "PIOEncoder.encode(" in symbols,
                          "builder_retained": "PIOBuilder.build" in symbols,
                          "allocation_references": [line for line in symbols.splitlines() if re.search(r"malloc|free|posix_memalign|swift_alloc", line)],
                          "undefined_symbols": [line.strip() for line in symbols.splitlines() if re.match(r"\s*U\s", line)]}
                report["results"].append(result)
                (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
                print(f"{optimization:5s} {consumption:6s} {case:20s} text={result['text_bytes']:6d} B  instructions={result['static_instructions']:5d}  assembler={result['assembler_retained']}", flush=True)
    lines = ["# Embedded code-generation results", "", f"Target: {args.triple}", "",
             "| Optimization | Consumption | Case | Text bytes | Static instructions | Assembler retained |",
             "|---|---|---|---:|---:|---|"]
    for item in report["results"]:
        lines.append(f"| {item['optimization']} | {item['consumption']} | {item['case']} | {item['text_bytes']} | {item['static_instructions']} | {item['assembler_retained']} |")
    lines += ["", "## Limits", ""] + ["- " + limit for limit in report["limits"]]
    (output / "summary.md").write_text("\n".join(lines) + "\n")
    print(output / "report.json", flush=True)


if __name__ == "__main__":
    main()
