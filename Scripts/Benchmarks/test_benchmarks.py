import pathlib
import json
import re
import tempfile
import unittest
from unittest.mock import patch

from embedded import compiler_flags
from link_firmware import add_baseline_deltas, ram_sections, sdk_objects
from run import CASES, case_details, digest, dynamic_reference_source, source
from runtime_support import PROFILES, compile_support


class BenchmarkHarnessTests(unittest.TestCase):
    def test_captured_cases_have_exactly_one_matching_entry_at_offset_seven(self):
        cases = ["constpio", "pio", "native", "pio_operand", "native_operand", "pio_dynamic", "native_dynamic"]
        for case in cases:
            with self.subTest(case=case):
                plain = source(case, [1] * 8, [2] * 9)
                captured = source(case + "_captured", [1] * 8, [2] * 9)
                self.assertIn(case + "_captured", CASES)
                self.assertNotIn("Label(entry)", plain)
                self.assertEqual(captured.count("Label(entry)"), 1)
                self.assertEqual(captured.count("let entry = PIOLabelHandle()"), 1)
                self.assertEqual(case_details(case + "_captured")["entrypoint_offset"], 7)
                body = captured.split("return ", 1)[1].split("Label(entry)", 1)[0]
                self.assertEqual(len(re.findall(r"^\s*(?:Out|Set|Jmp)\(", body, re.M)), 7)
                self.assertIn('program.labels[entry] == 7 && program.labels.count == 1', captured)

    def test_all_dynamic_cases_vary_every_instruction_operand_side_and_delay(self):
        for case in ["pio_dynamic", "native_dynamic", "pio_dynamic_captured", "native_dynamic_captured"]:
            value = source(case, [1] * 8, [2] * 9)
            self.assertEqual(value.count(".sideSet(value: Int("), 8)
            self.assertEqual(value.count(".delay(Int("), 8)
            self.assertEqual(value.count("Int((input &+"), 8)
            self.assertTrue(case_details(case)["all_dynamic_instruction_values"])
            with self.assertRaises(ValueError):
                digest(case, "all", 0, [1] * 8, [2] * 9)
            self.assertEqual(digest(case, "unused", 19, [1] * 8, [2] * 9), 19)

    def test_all_dynamic_oracle_covers_full_input_period(self):
        value = dynamic_reference_source()
        self.assertEqual(value.count(".program dynamic_"), 64)
        self.assertEqual(value.count(" side "), 64 * 8)
        self.assertIn("out pins, 1 side 0 [0]", value)
        self.assertIn(".program dynamic_63\n", value)

    def test_captured_cases_preserve_word_and_metadata_oracles(self):
        for case in ["constpio", "pio", "native", "pio_operand", "native_operand", "pio_dynamic", "native_dynamic"]:
            for input_ in range(64):
                dynamic = {input_: [input_] * 8}
                self.assertEqual(digest(case, "all", input_, [1] * 8, [2] * 9, dynamic),
                                 digest(case + "_captured", "all", input_, [1] * 8, [2] * 9, dynamic))

    def test_deltas_use_only_matching_empty_baselines_and_allow_negative_values(self):
        results = [
            {"case": case, "optimization": opt, "consumption": consumption, "function_sections": sections,
             "flash_image_bytes": flash, "static_sram_bytes": ram}
            for case, opt, consumption, sections, flash, ram in [
                ("empty", "O", "all", True, 100, 20), ("pioasm_c", "O", "all", True, 96, 16),
                ("empty", "O", "all", False, 900, 100), ("pio", "O", "all", False, 950, 120),
                ("pio", "Osize", "all", True, 110, 20), ("pio", "O", "unused", True, 110, 20)]]
        add_baseline_deltas(results)
        self.assertEqual([row["flash_over_empty_bytes"] for row in results], [0, -4, 0, 50, None, None])
        self.assertEqual(results[1]["static_sram_over_empty_bytes"], -4)

    def test_no_runtime_profile_adds_no_object_or_compile(self):
        with patch("runtime_support.run") as compile_:
            self.assertIsNone(compile_support("none", "O", pathlib.Path("/unused"), [], []))
            compile_.assert_not_called()

    def test_each_runtime_profile_is_separately_compiled_and_records_its_flags(self):
        for profile in PROFILES[1:]:
            with self.subTest(profile=profile), tempfile.TemporaryDirectory() as temporary, patch("runtime_support.run") as compile_:
                output = pathlib.Path(temporary)
                object_ = compile_support(profile, "Osize", output, ["swiftc"], ["-Osize", "-I", "modules"])
                command = json.loads((object_.parent / "compile-command.json").read_text())
                self.assertIn("BENCH_SUPPORT_" + profile.upper(), command)
                self.assertIn("-Osize", command)
                self.assertIn("PIOBenchRuntimeSupport", command)
                self.assertEqual(compile_.call_count, 2)

    def test_original_application_and_pio_objects_never_enter_sdk_archive(self):
        paths = [pathlib.Path("/build") / directory / "Object.o" for directory in [
            "CPicoSDK.build", "CShims.build", "PicoAudio.build", "RP2xxxPIOCore.build",
            "RP2xxxPIOSDK.build", "ConstExpr.build", "AnotherApplication.build"]]
        self.assertEqual(sdk_objects(paths), paths[:2])

    def test_sram_counts_executable_data_and_vectors_not_flash(self):
        sections = ram_sections("""section size addr
.text 1024 268435456
.ram_vector_table 272 536870912
.data 8192 536871184
.bss 2256 536879416
.heap 2048 536881672
.scratch_x 12 537395200
.debug_info 1000 0
""")
        self.assertEqual(sections, {".ram_vector_table": 272, ".data": 8192,
                                   ".bss": 2256, ".heap": 2048, ".scratch_x": 12})

    def test_consumer_flags_replace_optimization_and_remove_debug_outputs(self):
        flags = compiler_flags({"otherArguments": ["-O", "-g", "-j8", "-num-threads", "8",
            "-emit-objc-header", "-emit-objc-header-path", "/tmp/header.h",
            "-Xcc", "-g", "-Xcc", "-mcpu=cortex-m33", "-enable-experimental-feature", "Embedded"]}, "Osize")
        self.assertEqual(flags, ["-Xcc", "-mcpu=cortex-m33", "-enable-experimental-feature", "Embedded", "-Osize"])

    def test_every_swift_probe_has_an_observable_c_entry(self):
        for case in CASES:
            if case != "pioasm_c":
                self.assertIn('@_cdecl("benchmark_step")', source(case, [1] * 8, [2] * 9))

    def test_dynamic_sources_and_references_vary_the_same_domains(self):
        base, extra = [1] * 8, [2] * 9
        for dimension, mask in [("operand", 31), ("side", 3), ("branch", 1)]:
            for prefix in ["pio_", "native_"]:
                self.assertIn(f"input & {mask}", source(prefix + dimension, base, extra))
            for input_ in range(64):
                self.assertEqual(digest("reference_" + dimension, "all", input_, base, extra),
                                 digest("pio_" + dimension, "all", input_, base, extra))
        self.assertNotEqual(digest("pio_operand", "all", 1, base, extra),
                            digest("pio_operand", "all", 2, base, extra))
        self.assertEqual(digest("pio_branch", "unused", 19, base, extra), 19)


if __name__ == "__main__":
    unittest.main()
