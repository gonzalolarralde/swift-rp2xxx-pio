#!/usr/bin/env python3
"""Link benchmark probes with an existing CPicoSDK Ninja firmware harness.

Reuses its SDK startup, C objects, libraries, memory map and garbage collection.
Replaces the application with the benchmark driver and an SDK-only archive. Every output is
redirected to .build/benchmarks; no firmware/example artifact is overwritten and
no post-build, programming, or flashing command is executed.
"""
import argparse
import json
import pathlib
import re
import shlex
import tempfile

from run import CASES, HERE, ROOT, case_details, run


def sdk_objects(paths):
    """Allow only the allocator/SDK support, never application or PIO objects.

    Embedded Swift emits weak standard-library specializations into application
    objects. Linking the original application archive can silently pull those
    entire objects back in to satisfy a runtime reference, contaminating size.
    """
    return [path for path in paths if path.parent.name in {"CPicoSDK.build", "CShims.build"}]


def sdk_archive(libraries, module, compiler, output, cmake, section_sdk=False):
    originals = [part for part in libraries if pathlib.Path(part).name == f"lib{module}.a"]
    if len(originals) != 1:
        raise ValueError("Expected exactly one Swift application archive")
    original = (cmake / originals[0]).resolve()
    filelist = original.parent / f"{module}.product/Objects.LinkFileList"
    selected = sdk_objects([pathlib.Path(part) for part in shlex.split(filelist.read_text())])
    if not selected or not all(path.is_file() for path in selected):
        raise ValueError("Missing SDK runtime objects; rebuild the firmware consumer first")
    if section_sdk:
        from embedded import compiler_flags
        description = json.loads((original.parent / "description.json").read_text())
        command = next(item for item in description["swiftCommands"].values() if item["moduleName"] == "CPicoSDK")
        # Re-emit the SDK's own sources, never the application's, as a WMO
        # object with independently collectable functions. No source is edited.
        object_ = output / "sectioned-sdk.o"
        compile_ = [command["executable"], "-module-name", "CPicoSDK", "-I", command["importPath"],
                    *compiler_flags(command, "O"), "-Xfrontend", "-function-sections",
                    *command["sources"], "-emit-object", "-o", str(object_)]
        run(compile_, cwd=cmake)
        (output / "sdk-compile-command.json").write_text(json.dumps(compile_, indent=2))
        selected = [object_, *[path for path in selected if path.parent.name == "CShims.build"]]
    archive = output / "sdk-runtime.a"
    archiver = str(pathlib.Path(compiler[0]).with_name("arm-none-eabi-ar"))
    # Build a fresh archive so a previous run cannot leave obsolete members.
    with tempfile.TemporaryDirectory(prefix="sdk-archive-", dir=output) as temporary:
        fresh = pathlib.Path(temporary) / archive.name
        run([archiver, "rcs", fresh, *selected])
        fresh.replace(archive)
    (output / "sdk-runtime-objects.json").write_text(json.dumps(list(map(str, selected)), indent=2))
    return [str(archive) if part == originals[0] else part for part in libraries]


def ram_sections(size_output):
    # Pico SRAM (including X/Y scratch banks). Include RAM-resident code and
    # vectors: Berkeley `data + bss` alone misses executable .data sections.
    return {name: int(size) for name, size, address in re.findall(
        r"^(\S+)\s+(\d+)\s+(\d+)\s*$", size_output, re.M)
        if 0x20000000 <= int(address) < 0x21000000}


def add_baseline_deltas(results):
    """Compare only matched optimization, consumption and stripping settings."""
    def key(result):
        return result["optimization"], result["consumption"], result["function_sections"]
    empty = {key(result): result for result in results if result["case"] == "empty"}
    for result in results:
        baseline = empty.get(key(result))
        result["flash_over_empty_bytes"] = result["flash_image_bytes"] - baseline["flash_image_bytes"] if baseline else None
        result["static_sram_over_empty_bytes"] = result["static_sram_bytes"] - baseline["static_sram_bytes"] if baseline else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cmake-build", type=pathlib.Path, required=True)
    parser.add_argument("--module", required=True)
    parser.add_argument("--probes", type=pathlib.Path, default=ROOT / ".build/benchmarks/armv7em-none-none-eabi")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / ".build/benchmarks/firmware")
    parser.add_argument("--cases", nargs="+", choices=CASES, default=CASES)
    parser.add_argument("--optimizations", nargs="+", choices=["O", "Osize"], default=["O", "Osize"])
    parser.add_argument("--consumption", nargs="+", choices=["all", "words", "unused"], default=["all", "unused"])
    parser.add_argument("--function-sections", action="store_true", help="Also test separately emitted Swift functions with the SDK's --gc-sections linker")
    parser.add_argument("--sdk-function-sections", action="store_true",
                        help="Re-emit the SDK Swift sources with -O, WMO and function sections into benchmark output only")
    args = parser.parse_args()
    cmake = args.cmake_build.resolve()
    probes = args.probes.resolve()
    probe_report = json.loads((probes / "report.json").read_text())
    runtime_profile = probe_report.get("runtime_profile", "none")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    ninja = (cmake / "build.ninja").read_text()
    match = re.search(r"^build " + re.escape(args.module) + r"\.elf[^\n]*: (\S+) ([^\n]+)\n((?:  [^\n]*\n)+)", ninja, re.M)
    if not match: parser.error("Expected an existing CPicoSDK Ninja executable link rule")
    rule, inputs, settings = match.groups()
    settings = dict(re.findall(r"^  (\w+) = (.*)$", settings, re.M))
    rules = (cmake / "CMakeFiles/rules.ninja").read_text()
    compiler = re.search(r"^rule " + re.escape(rule) + r"\n  command = \$PRE_LINK && (.+?) \$FLAGS", rules, re.M)
    if not compiler: parser.error("Unsupported Ninja linker rule")
    compiler = shlex.split(compiler[1])
    objects = shlex.split(inputs.split(" |", 1)[0])
    flags = shlex.split(settings["FLAGS"])
    link_flags = [flag for flag in shlex.split(settings["LINK_FLAGS"]) if not flag.startswith("-Wl,-Map=")]
    libraries = shlex.split(settings.get("LINK_LIBRARIES", ""))
    if any("$" in part for part in objects + flags + link_flags + libraries):
        parser.error("Unexpanded Ninja variables are not supported; no link was attempted")
    libraries = sdk_archive(libraries, args.module, compiler, output, cmake,
                            **({"section_sdk": True} if args.sdk_function_sections else {}))
    driver = output / "driver.o"
    # Compile C with the same target architecture/ABI flags as the SDK linker.
    run([*compiler, *flags, "-x", "c", "-DBENCH_FIRMWARE", *(["-DBENCH_RUNTIME_SUPPORT"] if runtime_profile != "none" else []), "-ffunction-sections", "-fdata-sections",
         "-c", HERE / "Driver.c", "-o", driver], cwd=cmake)
    report = {"cmake_build": str(cmake), "module": args.module,
              "runtime_profile": runtime_profile,
              "sdk_function_sections": args.sdk_function_sections,
              "limits": ["Linked Pico firmware size only; these executables were not flashed or timed on a board.",
                         "SDK startup/stdio and compiler runtimes are included; compare against empty and C baselines.",
                         "The original application's archive is replaced with CPicoSDK/CShims objects only; application and PIO package objects are excluded.",
                         "Function-sections is a benchmark configuration, not a change to the library or firmware build defaults.",
                         "Static SRAM includes RAM-resident code/vectors/data but excludes .heap/.stack_dummy reservations, dynamic heap use and maximum stack depth."], "results": []}
    for optimization in args.optimizations:
        for consumption in args.consumption:
            for case in args.cases:
                name = f"{optimization}-{consumption}-{case}"
                original = probes / name
                for sections in ([False, True] if args.function_sections else [False]):
                    directory = output / (name + ("-function-sections" if sections else ""))
                    directory.mkdir(exist_ok=True)
                    object_ = original / "probe.o"
                    support = []
                    if runtime_profile != "none":
                        support_directory = probes / f"{optimization}-runtime-support"
                        support_object = support_directory / "probe.o"
                        if sections:
                            support_output = output / f"{optimization}-runtime-support-function-sections"
                            support_output.mkdir(exist_ok=True)
                            support_command = json.loads((support_directory / "compile-command.json").read_text())
                            support_command[support_command.index("-o") + 1] = str(support_output / "probe.o")
                            support_command += ["-Xfrontend", "-function-sections"]
                            saved = support_output / "compile-command.json"
                            if not saved.exists() or json.loads(saved.read_text()) != support_command or not (support_output / "probe.o").exists() or (support_output / "probe.o").stat().st_mtime < support_object.stat().st_mtime:
                                run(support_command, cwd=cmake)
                            saved.write_text(json.dumps(support_command, indent=2))
                            support_object = support_output / "probe.o"
                        support = [str(support_object)]
                    if sections:
                        command = json.loads((original / "compile-command.json").read_text())
                        command[command.index("-o") + 1] = str(directory / "probe.o")
                        command += ["-ffunction-sections", "-fdata-sections"] if case == "pioasm_c" else ["-Xfrontend", "-function-sections"]
                        command_file = directory / "compile-command.json"
                        cached_command = json.loads(command_file.read_text()) if command_file.exists() else None
                        if cached_command != command or not (directory / "probe.o").exists() or (directory / "probe.o").stat().st_mtime < object_.stat().st_mtime:
                            run(command, cwd=cmake)
                        command_file.write_text(json.dumps(command, indent=2))
                        object_ = directory / "probe.o"
                    binary = directory / "benchmark.elf"
                    link = [*compiler, *flags, "-Wl,--build-id=none", *link_flags,
                            "-Wl,-Map=" + str(directory / "benchmark.map"), *objects,
                            str(object_), str(driver), *support, "-o", str(binary), *libraries]
                    (directory / "link-command.json").write_text(json.dumps(link, indent=2))
                    run(link, cwd=cmake)
                    objcopy = str(pathlib.Path(compiler[0]).with_name("arm-none-eabi-objcopy"))
                    flash = directory / "benchmark.bin"
                    run([objcopy, "-O", "binary", binary, flash])
                    sizes = run(["xcrun", "llvm-size", "--format=berkeley", binary])
                    (directory / "size.txt").write_text(sizes)
                    values = sizes.splitlines()[-1].split()
                    text, data, bss = map(int, values[:3])
                    section_sizes = run(["xcrun", "llvm-size", "--format=sysv", binary])
                    (directory / "sections.txt").write_text(section_sizes)
                    ram = ram_sections(section_sizes)
                    symbols = run(["xcrun", "swift-demangle", "--compact"], input=run(["xcrun", "llvm-nm", binary]))
                    (directory / "symbols.txt").write_text(symbols)
                    if args.module + "." in symbols:
                        raise RuntimeError("Original application code was pulled into the benchmark; refusing to report contaminated sizes")
                    result = {"case": case, **case_details(case), "optimization": optimization, "consumption": consumption,
                              "function_sections": sections, "flash_image_bytes": flash.stat().st_size,
                              "berkeley_text_bytes": text, "data_bytes": data, "bss_bytes": bss,
                              "sram_sections": ram,
                              "static_sram_bytes": sum(size for name, size in ram.items() if name not in {".heap", ".stack_dummy"}),
                              "assembler_retained": "PIOAssembler.assemble(" in symbols or "PIOAssembly.assemble(" in symbols,
                              "encoder_retained": "PIOEncoder.encode(" in symbols,
                              "validation_wrapper_retained": "PIOAssembler._validated(" in symbols,
                              "unicode_helpers_retained": "Swift.String.hash(into:" in symbols,
                              "symbols_path": str(directory / "symbols.txt")}
                    report["results"].append(result)
                    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
                    print(f"{name:40s} sections={sections!s:5s} flash={result['flash_image_bytes']:7d} B  static SRAM={result['static_sram_bytes']:6d} B", flush=True)
    add_baseline_deltas(report["results"])
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = ["# Linked Pico firmware size", "", f"Runtime profile: `{runtime_profile}`. SDK Swift function sections: `{args.sdk_function_sections}`.", "",
             "| Optimization | Consumption | Case | Function sections | Flash image bytes | Flash above matching empty | Static SRAM bytes |",
             "|---|---|---|---|---:|---:|---:|"]
    for result in report["results"]:
        delta = result["flash_over_empty_bytes"]
        lines.append(f"| {result['optimization']} | {result['consumption']} | {result['case']} | {result['function_sections']} | {result['flash_image_bytes']} | {delta if delta is not None else 'not measured'} | {result['static_sram_bytes']} |")
    lines += ["", "## Limits", ""] + ["- " + limit for limit in report["limits"]]
    (output / "summary.md").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
