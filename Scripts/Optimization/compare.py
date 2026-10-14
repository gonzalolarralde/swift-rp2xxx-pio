#!/usr/bin/env python3
"""Compile actual macros and CPicoSDK-generated Swift using firmware build flags.

Requires an existing release build of Examples/Firmware for the selected triple.
Creates only diagnostic build outputs; never links, loads, or flashes firmware.
"""
import argparse
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--triple", default="armv6m-none-none-eabi")
parser.add_argument("--macro-plugin", type=pathlib.Path, help="Override the PIO host plugin while iterating on code generation")
parser.add_argument("--require-local-equivalence", action="store_true", help="Fail unless constant local programs match the reference LLVM bodies")
parser.add_argument("--require-specialized-setup", action="store_true", help="Check setup equivalence, reporting but excluding releases of constant program storage")
args = parser.parse_args()
firmware = ROOT / "Examples/Firmware"
description = json.loads((firmware / ".build" / args.triple / "release/description.json").read_text())
command = next(value for value in description["swiftCommands"].values() if value["moduleName"] == "PIOFirmware")
output = ROOT / ".build/optimization-comparison" / args.triple
output.mkdir(parents=True, exist_ok=True)
cpico = firmware / ".build/checkouts/CPicoSDK/Sources/PIOASM/pioasm-swift"
generator = output / "pioasm-swift"
subprocess.run(["/usr/bin/xcrun", "swiftc", "-O", "-parse-as-library",
                str(cpico / "CompiledSource.swift"), str(cpico / "pioasm-swift.swift"),
                "-o", str(generator)], check=True)
reference = output / "Reference.swift"
subprocess.run([str(generator), str(ROOT / ".build/pioasm-reference/build/pioasm"),
                str(ROOT / "Scripts/Optimization/Programs.pio"), str(reference)], check=True)

# The pinned upstream pioasm JSON can contain an oversized fractional clock
# byte (also covered by the SDK differential tests). Its C output narrows this
# to uint8_t implicitly; Swift rejects the literal. Make exactly that narrowing
# explicit in the generated diagnostic copy, without changing the call list.
text = reference.read_text()
text, narrowings = re.subn(
    r"sm_config_set_clkdiv_int_frac\(&c, (\d+), (\d+)\)",
    lambda match: f"sm_config_set_clkdiv_int_frac(&c, {match[1]}, UInt8(truncatingIfNeeded: {match[2]}))",
    text,
)
reference.write_text(text)
print(f"Applied SDK-equivalent UInt8 narrowing to {narrowings} reference clock literal(s)", flush=True)

# Reuse the actual firmware compiler, SDK include paths, traits, optimization,
# Embedded mode, and separately built library modules. Drop only build outputs,
# diagnostics formatting, and parallelism flags unsuitable for a single output.
drop_single = {"-serialize-diagnostics", "-parseable-output", "-emit-objc-header", "-g"}
drop_pair = {"-emit-objc-header-path", "-num-threads"}
flags = []
source = iter(command["otherArguments"])
for flag in source:
    if flag in drop_pair:
        next(source)
    elif flag in drop_single or flag.startswith("-j") or flag.startswith("-debug-info-format="):
        continue
    elif flag == "-Xcc":
        value = next(source)
        if value != "-g":
            flags += [flag, value]
    elif args.macro_plugin and flag.endswith("#RP2xxxPIOMacros"):
        flags.append(str(args.macro_plugin.resolve()) + "#RP2xxxPIOMacros")
    else:
        flags.append(flag)
base = [command["executable"], "-module-name", "PIOOptimizationComparison",
        "-I", command["importPath"], *flags,
        str(reference), str(ROOT / "Scripts/Optimization/Probes.swift")]
for kind, extension in [("-emit-ir", "ll"), ("-emit-assembly", "s"), ("-emit-object", "o")]:
    subprocess.run([*base, kind, "-o", str(output / ("comparison." + extension))], check=True, cwd=firmware)

# Compare actual Swift function bodies, not the trivial @_cdecl entry thunks.
# Keep stored-value probes in the report: their lazy global initialization and
# runtime metadata validation must not be mistaken for constant local setup.
ir = (output / "comparison.ll").read_text()
functions = dict(re.findall(r'^define[^\n]*@"([^"\n]+)"[^\n]*\{\n(.*?)^\}', ir, re.M | re.S))
names = ["macroDefaultLocal", "macroDefaultStored", "pioasmDefault",
         "macroConfiguredLocal", "macroConfiguredStored", "pioasmConfigured"]
report = {"triple": args.triple, "reference_clock_narrowings": narrowings, "functions": {}}
bodies = {}
setup_bodies = {}
def normalize(body):
    identifiers = {"%0": "%arg0", "%1": "%arg1"}
    def identifier(match):
        value = match[0]
        if value not in identifiers:
            identifiers[value] = f"%value{len(identifiers)}"
        return identifiers[value]
    normalized = []
    for line in body.splitlines():
        line = line.split(";", 1)[0].strip()
        if line and not line.endswith(":"):
            normalized.append(re.sub(r'%[-a-zA-Z$._0-9]+', identifier, line))
    return "\n".join(normalized)

for name in names:
    symbol, body = next((symbol, body) for symbol, body in functions.items()
                        if f"{len(name)}{name}" in symbol and symbol.endswith("GtF"))
    calls = re.findall(r'\b(?:call|invoke)\b[^\n]*@(?:"([^"\n]+)"|([^\s(]+))', body)
    calls = [quoted or plain for quoted, plain in calls if not (quoted or plain).startswith("llvm.")]
    # Do not conceal whole-wrapper overhead. Record it separately and make a
    # second, explicitly narrower comparison of configuration arithmetic/stores.
    # Only releases of statically named storage are eligible for this exclusion.
    setup_body, releases = re.subn(r'^\s*tail call void @swift_release\(ptr nonnull @[^\n]*\n', '', body, flags=re.M)
    report["functions"][name] = {"symbol": symbol, "calls": calls,
        "constant_storage_releases": releases,
        "conditional_branches": len(re.findall(r'^\s*br i1\b', body, re.M))}
    bodies[name] = normalize(body)
    setup_bodies[name] = normalize(setup_body)
report["local_equivalence"] = {
    "default": bodies["macroDefaultLocal"] == bodies["pioasmDefault"],
    "configured": bodies["macroConfiguredLocal"] == bodies["pioasmConfigured"],
}
report["local_setup_equivalence_excluding_constant_storage_releases"] = {
    "default": setup_bodies["macroDefaultLocal"] == setup_bodies["pioasmDefault"],
    "configured": setup_bodies["macroConfiguredLocal"] == setup_bodies["pioasmConfigured"],
}
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
for name, result in report["functions"].items():
    print(f"{name}: {len(result['calls'])} calls ({result['constant_storage_releases']} constant-storage releases), {result['conditional_branches']} conditional branches")
print("Identical normalized LLVM bodies (local):", report["local_equivalence"])
print("Identical setup after excluding the reported constant-storage releases:", report["local_setup_equivalence_excluding_constant_storage_releases"])
print(output)
if args.require_local_equivalence and not all(report["local_equivalence"].values()):
    raise SystemExit("Constant local configuration differs from the pioasm reference; inspect report.json and comparison.ll")
if args.require_specialized_setup and not all(report["local_setup_equivalence_excluding_constant_storage_releases"].values()):
    raise SystemExit("Specialized setup differs from pioasm even after excluding constant-storage releases; inspect report.json and comparison.ll")
