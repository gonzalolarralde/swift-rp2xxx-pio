#!/usr/bin/env python3
"""Compare protocol/native configuration with actual CPicoSDK-generated Swift.

Requires an existing release build of a separate CPicoSDK consumer package.
Creates only diagnostic build outputs; never links, loads, or flashes firmware.
"""
import argparse
import json
import pathlib
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--firmware-package", type=pathlib.Path, required=True,
                    help="A separate CPicoSDK consumer package with an existing release build")
parser.add_argument("--module", required=True, help="The consumer's Swift module that imports RP2xxxPIO with SDKInterop")
parser.add_argument("--triple", default="armv6m-none-none-eabi")
parser.add_argument("--macro-plugin", type=pathlib.Path, help="Override the PIO host plugin while iterating on code generation")
parser.add_argument("--require-protocol-equivalence", action="store_true",
                    help="Fail unless both stored-code protocol probes match the reference LLVM bodies exactly")
args = parser.parse_args()
firmware = args.firmware_package.resolve()
description = json.loads((firmware / ".build" / args.triple / "release/description.json").read_text())
command = next(value for value in description["swiftCommands"].values() if value["moduleName"] == args.module)
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
functions = {
    quoted or plain: body
    for quoted, plain, body in re.findall(
        r'^define[^\n]*?@(?:"([^"\n]+)"|([^\s(]+))[^\n]*\{\n(.*?)^\}', ir, re.M | re.S
    )
}
names = ["nativeDefaultLocal", "protocolDefaultStored", "protocolDefaultComputed", "pioasmDefault",
         "nativeConfiguredLocal", "protocolConfiguredStored", "protocolConfiguredComputed", "pioasmConfigured"]
report = {"triple": args.triple, "reference_clock_narrowings": narrowings, "functions": {}}
bodies = {}
setup_bodies = {}
def call_summary(body):
    # Match the callee, not a function address passed as an argument to it.
    calls = re.findall(r'\b(?:call|invoke)\b[^\n]*?(?:@"([^"\n]+)"|@([^\s(]+)|(%[-a-zA-Z$._0-9]+))\(', body)
    return {
        "calls": [quoted or plain for quoted, plain, indirect in calls
                  if not indirect and not (quoted or plain).startswith("llvm.")],
        "indirect_calls": [indirect for _, _, indirect in calls if indirect],
        "conditional_branches": len(re.findall(r'^\s*br i1\b', body, re.M)),
        "switches": len(re.findall(r'^\s*switch\b', body, re.M)),
    }

def referenced_helpers(root):
    # Include function addresses passed to shared/merged helpers as well as
    # direct calls. These are reachable code bodies, not dynamic execution counts.
    seen = {root}
    pending = [root]
    while pending:
        current = pending.pop()
        references = re.findall(r'@(?:"([^"\n]+)"|([^\s(,]+))', functions[current])
        for quoted, plain in references:
            symbol = quoted or plain
            if symbol in functions and symbol not in seen:
                seen.add(symbol)
                pending.append(symbol)
    return sorted(seen - {root})

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
    # Do not conceal whole-wrapper overhead. Record it separately and make a
    # second, explicitly narrower comparison of configuration arithmetic/stores.
    # Only releases of statically named storage are eligible for this exclusion.
    setup_body, releases = re.subn(r'^\s*tail call void @swift_release\(ptr nonnull @[^\n]*\n', '', body, flags=re.M)
    report["functions"][name] = {"symbol": symbol, **call_summary(body),
        "constant_storage_releases": releases,
        "referenced_helpers": referenced_helpers(symbol)}
    bodies[name] = normalize(body)
    setup_bodies[name] = normalize(setup_body)
comparisons = {
    "native_local": ["nativeDefaultLocal", "nativeConfiguredLocal"],
    "protocol_stored": ["protocolDefaultStored", "protocolConfiguredStored"],
    "protocol_computed": ["protocolDefaultComputed", "protocolConfiguredComputed"],
}
for key, source_bodies in [("equivalence", bodies), ("setup_equivalence_excluding_constant_storage_releases", setup_bodies)]:
    report[key] = {
        kind: {"default": source_bodies[default] == source_bodies["pioasmDefault"],
               "configured": source_bodies[configured] == source_bodies["pioasmConfigured"]}
        for kind, (default, configured) in comparisons.items()
    }
helpers = {symbol for result in report["functions"].values() for symbol in result["referenced_helpers"]}
report["helper_functions"] = {symbol: call_summary(functions[symbol]) for symbol in sorted(helpers)}
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
for name, result in report["functions"].items():
    print(f"{name}: {len(result['calls'])} direct calls, {len(result['indirect_calls'])} indirect calls, "
          f"{result['conditional_branches']} conditional branches, {len(result['referenced_helpers'])} referenced helper bodies "
          f"({result['constant_storage_releases']} direct constant-storage releases)")
print("Identical normalized LLVM bodies:", report["equivalence"])
print("Identical setup after excluding the reported constant-storage releases:", report["setup_equivalence_excluding_constant_storage_releases"])
print(output)
if args.require_protocol_equivalence and not all(report["equivalence"]["protocol_stored"].values()):
    raise SystemExit("Stored-code protocol configuration differs from pioasm; inspect report.json and comparison.ll")
