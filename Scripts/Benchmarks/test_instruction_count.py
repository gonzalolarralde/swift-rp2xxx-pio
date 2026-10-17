"""Unit tests plus optional real ARM execution tests using the pinned venv."""
import importlib.util
import pathlib
import shutil
import subprocess
import tempfile
import unittest

AVAILABLE = all(importlib.util.find_spec(name) for name in ("unicorn", "elftools"))
if AVAILABLE:
    from instruction_count import instruction_source, software_math_link, summarize
    from instruction_emulator import Image, Machine, ExecutionError, calibrate

HERE = pathlib.Path(__file__).resolve().parent


@unittest.skipUnless(AVAILABLE, "Use requirements-instructions.txt environment for ARM counter tests")
class InstructionHarnessTests(unittest.TestCase):
    def test_software_math_keeps_real_allocator_wrappers(self):
        command = ["gcc", "-Wl,--wrap=malloc", "-Wl,--wrap=free", "-Wl,--wrap=calloc",
                   "-Wl,--wrap=realloc", "-Wl,--wrap=__aeabi_ui2d", "-Wl,--wrap=__aeabi_dmul", "probe.o"]
        self.assertEqual(software_math_link(command), command[:5] + ["probe.o"])

    def test_source_keeps_program_alive_and_uses_real_sdk_adapter(self):
        value = instruction_source("pio_dynamic_captured", [1] * 8, [2] * 9)
        self.assertIn("initialize(to: try makeProgram(input))", value)
        self.assertIn(".pointee.withCProgram", value)
        self.assertIn("benchmark_ready(UnsafeRawPointer(descriptor))", value)
        self.assertIn("return Int32(program.labels[entry] ?? -1)", value)
        self.assertIn("deinitialize(count: 1)", value)
        self.assertNotIn('@_cdecl("benchmark_step")', value)
        self.assertEqual(value.count("Label(entry)"), 1)

    def test_summary_keeps_first_use_and_every_warm_repeat_separate(self):
        samples = [{"phase": phase, "to_data": data, "to_sdk": data + 5,
                    "descriptor_increment": 5, "entry_lookup": None}
                   for phase, data in [("first_use", 100), ("first_use", 102), ("warm", 20), ("warm", 30), ("warm", 25)]]
        result = summarize(samples)
        self.assertEqual(result["first_use"]["to_sdk"], {"min": 105, "median": 106, "max": 107})
        self.assertEqual(result["warm"]["to_data"], {"min": 20, "median": 25, "max": 30})
        self.assertIsNone(result["warm"]["entry_lookup"])


@unittest.skipUnless(AVAILABLE and shutil.which("xcrun"), "ARM execution tests need pinned dependencies and clang")
class CounterExecutionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix="pio-instruction-tests-")
        cls.elf = pathlib.Path(cls.directory.name) / "calibration.elf"
        # LLVM's bundled linker availability varies; the project ARM toolchain
        # is resolved from a previously prepared benchmark link command.
        import json
        template = HERE.parents[1] / ".build/benchmarks/complete-matrix-firmware-common/O-all-constpio-function-sections/link-command.json"
        if not template.exists():
            raise unittest.SkipTest("Prepare the Embedded benchmark link harness first")
        compiler = json.loads(template.read_text())[0]
        subprocess.run([compiler, "-x", "assembler-with-cpp", "-mcpu=cortex-m33", "-mthumb", "-nostdlib",
                        "-Ttext=0x10001000", "-Wl,-e,calibration_plain", HERE / "InstructionCalibration.S", "-o", cls.elf],
                       check=True, capture_output=True)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_known_counts_and_fault_rejection(self):
        values = calibrate(self.elf)
        self.assertEqual(values["loop"]["observed"], 18)
        self.assertEqual(values["calls"]["observed"], 5)
        self.assertEqual(values["cond_true"]["observed"], 5)
        self.assertEqual(values["cond_false"]["observed"], 5)
        self.assertTrue(values["fault"]["rejected"])
        self.assertTrue(values["unknown_mmio"]["rejected"])
        self.assertTrue(values["guest_error"]["rejected"])

    def test_instruction_budget_does_not_produce_a_partial_success(self):
        with self.assertRaisesRegex(ExecutionError, "instruction budget exhausted"):
            Machine(Image.load(self.elf)).call("calibration_loop", max_instructions=4)
