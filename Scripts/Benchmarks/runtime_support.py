"""Shared, opt-in runtime baselines. They are not assumed universal costs."""
import json

from run import HERE, run

PROFILES = ("none", "allocation", "strings", "collections", "common")


def compile_support(profile, optimization, output, compiler, arguments, cwd=None):
    if profile == "none":
        return None
    directory = output / f"{optimization}-runtime-support"
    directory.mkdir(exist_ok=True)
    object_ = directory / "probe.o"
    command = [*compiler, "-module-name", "PIOBenchRuntimeSupport", *arguments,
               "-D", "BENCH_SUPPORT_" + profile.upper(), HERE / "RuntimeSupport.swift"]
    run([*command, "-emit-ir", "-o", directory / "probe.ll"], cwd=cwd)
    command += ["-emit-object", "-o", object_]
    run(command, cwd=cwd)
    (directory / "compile-command.json").write_text(json.dumps(list(map(str, command)), indent=2))
    return object_
