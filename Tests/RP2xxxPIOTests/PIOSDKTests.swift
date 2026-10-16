import Foundation
import XCTest

/// Executes the production Swift adapter against the real SDK's pure, inline
/// configuration helpers. The SDK's host platform shim prevents ARM assembly;
/// actual RP2040/RP2350 register definitions and PIO headers remain unchanged.
final class PIOSDKTests: XCTestCase {
    func testSDKConfigurationsAndScopedDescriptorsOnBothPlatforms() throws {
        guard let sdkPath = ProcessInfo.processInfo.environment["PIO_SDK_PATH"] else {
            throw XCTSkip("Set PIO_SDK_PATH to pico-sdk to execute native SDK interop checks")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let oracle = ProcessInfo.processInfo.environment["PIOASM"]
            ?? root.appendingPathComponent(".build/pioasm-reference/build/pioasm").path
        guard FileManager.default.isExecutableFile(atPath: oracle) else {
            throw XCTSkip("Build the pinned pioasm reference first")
        }
        var build = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        while build.path != "/", !FileManager.default.fileExists(atPath: build.appendingPathComponent("Modules").path) {
            build.deleteLastPathComponent()
        }
        if build.path == "/" { build = root.appendingPathComponent(".build/debug").resolvingSymlinksInPath() }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pio-sdk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }

        for platform in ["rp2040", "rp2350"] {
            let directory = temporary.appendingPathComponent(platform)
            try FileManager.default.createDirectory(at: directory.appendingPathComponent("pico"), withIntermediateDirectories: true)
            try "// No board-specific configuration is needed by these pure helpers.\n".write(
                to: directory.appendingPathComponent("pico/config_autogen.h"), atomically: true, encoding: .utf8)
            try Self.versionHeader(sdkPath: sdkPath).write(
                to: directory.appendingPathComponent("pico/version.h"), atomically: true, encoding: .utf8)
            let fixtures = Self.fixtures(extended: platform == "rp2350")
            let input = fixtures.enumerated().map { ".program sample\($0.offset)\n\($0.element.pio)" }.joined(separator: "\n")
            try input.write(to: directory.appendingPathComponent("reference.pio"), atomically: true, encoding: .utf8)
            try run(oracle, ["-o", "c-sdk", "reference.pio", "reference.h"], in: directory)

            let configCases = fixtures.indices.map { "case \($0): return sample\($0)_program_get_default_config(offset);" }.joined(separator: "\n")
            let programCases = fixtures.indices.map { "case \($0): return &sample\($0)_program;" }.joined(separator: "\n")
            let header = """
            #define PICO_\(platform.uppercased()) 1
            #define PICO_ON_DEVICE 0
            #define PICO_NO_HARDWARE 0
            #define PICO_USE_GPIO_COPROCESSOR 0
            #define PICO_NUM_VTABLE_IRQS NUM_IRQS
            #include "\(sdkPath)/src/\(platform)/hardware_regs/include/hardware/platform_defs.h"
            #include <stdlib.h>
            #include "hardware/pio.h"
            #include "hardware/clocks.h"
            #include "reference.h"
            enum { sdk_num_pio_state_machines = NUM_PIO_STATE_MACHINES };
            static inline pio_sm_config sdk_reference_config(unsigned index, unsigned offset) {
                switch (index) { \(configCases) default: abort(); }
            }
            static inline const pio_program_t *sdk_reference_program(unsigned index) {
                switch (index) { \(programCases) default: abort(); }
            }
            """
            try header.write(to: directory.appendingPathComponent("SDK.h"), atomically: true, encoding: .utf8)
            try "module CPicoSDKHeaders { header \"SDK.h\" export * }\n".write(
                to: directory.appendingPathComponent("module.modulemap"), atomically: true, encoding: .utf8)

            // Reuse CPicoSDK's real RP2040 compatibility overload rather than
            // inventing a mock C descriptor initializer for this test.
            var wrapper = """
            @_exported import CPicoSDKHeaders
            // Expose the SDK constant through the host shim: Clang's Swift
            // importer cannot translate this header's nested _u(...) macro.
            public let NUM_PIO_STATE_MACHINES = UInt32(sdk_num_pio_state_machines)

            """
            if platform == "rp2040" {
                let checkout = ProcessInfo.processInfo.environment["CPICOSDK_ROOT"]
                    ?? root.appendingPathComponent(".build/checkouts/CPicoSDK").path
                let source = try String(contentsOfFile: checkout + "/Sources/CPicoSDK/CPicoSDK.swift", encoding: .utf8)
                let start = try XCTUnwrap(source.range(of: "#if Platform_RP2040\n    // RP2040's pio_program_t"))
                let end = try XCTUnwrap(source.range(of: "#endif", range: start.upperBound..<source.endIndex))
                let body = source.index(start.lowerBound, offsetBy: "#if Platform_RP2040\n".count)
                wrapper += String(source[body..<end.lowerBound])
            }
            try wrapper.write(to: directory.appendingPathComponent("CPicoSDK.swift"), atomically: true, encoding: .utf8)

            let sdk = URL(fileURLWithPath: sdkPath)
            var includes = [directory.path, sdk.appendingPathComponent("src/host/pico_platform/include").path]
            for group in [platform, "common", "rp2_common"] {
                let base = sdk.appendingPathComponent("src/\(group)")
                for child in try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                    let include = child.appendingPathComponent("include")
                    if FileManager.default.fileExists(atPath: include.path) { includes.append(include.path) }
                }
            }
            let clangFlags = includes.flatMap { ["-Xcc", "-I\($0)"] }
                + ["-Xcc", "-Wno-int-to-pointer-cast", "-Xcc", "-Wno-constant-conversion"]
            let imports = ["-I", directory.path, "-I", build.appendingPathComponent("Modules").path]
            try run("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-emit-module", "-emit-object",
                "-module-name", "CPicoSDK", "CPicoSDK.swift", "-o", "CPicoSDK.o"] + imports + clangFlags, in: directory)

            let programs = fixtures.map { "try PIOAssembler.assemble(options: .init(\($0.options))) { \($0.swift) }" }.joined(separator: ",\n")
            let configurations = fixtures.enumerated().map { index, fixture in
                let arguments = fixture.configuration.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
                return "try PIOConfiguration(program: programs[\(index)], origin: \(fixture.origin.map(String.init) ?? "nil")\(arguments.isEmpty ? "" : ", " + arguments))"
            }.joined(separator: ",\n")
            let propertyTypes = ["input": "PIOShiftConfiguration?", "output": "PIOShiftConfiguration?",
                "setCount": "Int?", "fifo": "PIOFIFOJoin", "movStatus": "PIOMovStatus?",
                "clockDivider": "Double", "sideSetPinDirections": "Bool", "pins": "PIOPinMapping"]
            let declarations = fixtures.enumerated().map { index, fixture in
                let properties = fixture.configuration.map { name, value in
                    "let \(name): \(propertyTypes[name]!) = \(value)"
                }.joined(separator: "\n")
                return """
                struct Sample\(index): PIOProgram {
                    var code: PIOProgramData { programs[\(index)] }
                    let origin: Int? = \(fixture.origin.map(String.init) ?? "nil")
                    \(properties)
                }
                """
            }.joined(separator: "\n")
            let checks = fixtures.indices.map { "try check(Sample\($0)(), index: \($0))" }.joined(separator: "\n")
            let extendedChecks = platform == "rp2350" ? """
            struct HighPins: PIOProgram {
                var code: PIOProgramData { programs[3] }
                let pins = PIOPinMapping(input: 32, output: 33, set: 34, sideSet: 35, jump: 47)
            }
            var highPins = try HighPins().defaultConfig(offset: 0)
            var nativeHighPins = try PIOConfiguration(program: programs[3],
                pins: .init(input: 32, output: 33, set: 34, sideSet: 35, jump: 47)).defaultConfig(offset: 0)
            var expectedHighPins = pio_get_default_sm_config()
            sm_config_set_wrap(&expectedHighPins, 0, 0)
            sm_config_set_in_pin_base(&expectedHighPins, 32); sm_config_set_out_pin_base(&expectedHighPins, 33)
            sm_config_set_set_pin_base(&expectedHighPins, 34); sm_config_set_sideset_pin_base(&expectedHighPins, 35)
            sm_config_set_jmp_pin(&expectedHighPins, 47)
            let highBytes = withUnsafeBytes(of: &highPins) { Array($0) }
            precondition(highBytes == withUnsafeBytes(of: &expectedHighPins) { Array($0) })
            precondition(highBytes == withUnsafeBytes(of: &nativeHighPins) { Array($0) })
            """ : ""
            let main = """
            import CPicoSDK
            import RP2xxxPIOCore
            let programs: [PIOProgramData] = [\(programs)]
            let configurations: [PIOConfiguration] = [\(configurations)]
            \(declarations)
            func check<P: PIOProgram>(_ instance: P, index: Int) throws {
                let setup = configurations[index]
                let declaredConfiguration = try instance.configuration()
                precondition(declaredConfiguration == setup)
                let program = setup.program
                for offset: UInt32 in [0, 1, 7, 16, 28] {
                    var actual = try setup.defaultConfig(offset: offset)
                    var declared = try instance.defaultConfig(offset: offset)
                    var expected = sdk_reference_config(UInt32(index), offset)
                    let actualBytes = withUnsafeBytes(of: &actual) { Array($0) }
                    let declaredBytes = withUnsafeBytes(of: &declared) { Array($0) }
                    let expectedBytes = withUnsafeBytes(of: &expected) { Array($0) }
                    precondition(actualBytes == expectedBytes, "Config mismatch: \\(index), offset \\(offset)")
                    precondition(declaredBytes == expectedBytes, "Protocol config mismatch: \\(index), offset \\(offset)")
                }
                let reference = sdk_reference_program(UInt32(index))!.pointee
                for _ in 0..<20 {
                    try instance.withCProgram { pointer in
                        let actual = pointer.pointee
                        precondition(actual.length == reference.length)
                        precondition(actual.origin == reference.origin)
                        precondition(actual.pio_version == reference.pio_version)
                        \(platform == "rp2350" ? "precondition(actual.used_gpio_ranges == reference.used_gpio_ranges)" : "")
                        let words = Array(UnsafeBufferPointer(start: actual.instructions, count: Int(actual.length)))
                        let expected = Array(UnsafeBufferPointer(start: reference.instructions, count: Int(reference.length)))
                        precondition(words == expected && words == program.instructions)
                        // Nested borrows keep the outer storage and descriptor
                        // valid; no pointer is returned or used outside its scope.
                        setup.withCProgram { inner in
                            precondition(pointer != inner)
                            precondition(pointer.pointee.instructions[0] == words[0])
                        }
                        precondition(pointer.pointee.instructions[0] == words[0])
                    }
                }
            }
            \(checks)
            // Computed requirements read this instance, not a cached type-level
            // configuration. Dynamic nils preserve SDK defaults.
            struct Runtime: PIOProgram {
                var code: PIOProgramData { programs[0] }
                var input: PIOShiftConfiguration? { nil }
                var requestedClock: Double = 2.5
                var clockDivider: Double { requestedClock }
                let pins = PIOPinMapping(input: 2, output: 3, set: 4, sideSet: 5, jump: 6)
            }
            var runtime = Runtime()
            let independent = runtime
            var dynamic = try runtime.defaultConfig(offset: 7)
            var manual = sdk_reference_config(0, 7)
            sm_config_set_clkdiv_int_frac(&manual, 2, 128)
            sm_config_set_in_pin_base(&manual, 2); sm_config_set_out_pin_base(&manual, 3)
            sm_config_set_set_pin_base(&manual, 4); sm_config_set_sideset_pin_base(&manual, 5)
            sm_config_set_jmp_pin(&manual, 6)
            precondition(withUnsafeBytes(of: &dynamic) { Array($0) } == withUnsafeBytes(of: &manual) { Array($0) })
            do { _ = try Sample0().defaultConfig(offset: 31); fatalError("invalid offset accepted") }
            catch { precondition(error == .invalidConfiguration("loaded wrap addresses exceed instruction memory")) }
            runtime.requestedClock = .nan
            do { _ = try runtime.defaultConfig(offset: 0); fatalError("invalid divider accepted") }
            catch { precondition(error == .invalidConfiguration("clock divider must be finite, at least 1, and less than 65536")) }
            var visited = false
            do { _ = try runtime.withCProgram { _ in visited = true }; fatalError("invalid configuration borrowed") }
            catch { precondition(!visited) }
            var unchanged = try independent.defaultConfig(offset: 7)
            precondition(withUnsafeBytes(of: &unchanged) { Array($0) } == withUnsafeBytes(of: &dynamic) { Array($0) })
            runtime.requestedClock = 3.75
            var changed = try runtime.defaultConfig(offset: 7)
            sm_config_set_clkdiv_int_frac(&manual, 3, 192)
            precondition(withUnsafeBytes(of: &changed) { Array($0) } == withUnsafeBytes(of: &manual) { Array($0) })
            \(extendedChecks)
            try checkPicoAudioHardwareBoundary()
            print("\(platform): \\(programs.count * 5) native + protocol configurations and \\(programs.count * 20) nested protocol/value borrows passed")
            """
            try main.write(to: directory.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
            let objects = try ["ConstExpr", "RP2xxxPIOCore"].flatMap { module in
                try FileManager.default.contentsOfDirectory(at: build.appendingPathComponent("\(module).build"), includingPropertiesForKeys: nil)
                    .filter { $0.pathExtension == "o" }.map(\.path)
            }
            try run("/usr/bin/xcrun", ["swiftc", "-swift-version", "6", "-warnings-as-errors", "-D", "SDKInterop",
                "-load-plugin-executable", "\(build.appendingPathComponent("RP2xxxPIOMacros-tool").path)#RP2xxxPIOMacros",
                "main.swift", root.appendingPathComponent("Sources/RP2xxxPIOSDK/PIOProgram+SDK.swift").path,
                root.appendingPathComponent("Examples/PicoAudio/Sources/PicoAudio/I2S.swift").path,
                root.appendingPathComponent("Examples/PicoAudio/Sources/PicoAudio/PIOHelpers.swift").path,
                root.appendingPathComponent("Tests/RP2xxxPIOTests/Fixtures/PicoAudioHardwareChecks.swift").path,
                "CPicoSDK.o", "-o", "interop-check"] + imports + clangFlags + objects, in: directory)
            try run(directory.appendingPathComponent("interop-check").path, [], in: directory)
        }
    }

    private struct Fixture {
        let pio: String
        let swift: String
        var options: String = ""
        var configuration: [(String, String)] = []
        var origin: Int? = nil
    }

    private static func versionHeader(sdkPath: String) throws -> String {
        let version = try String(contentsOfFile: sdkPath + "/pico_sdk_version.cmake", encoding: .utf8)
        var header = try String(contentsOfFile: sdkPath + "/src/common/pico_base_headers/include/pico/version.h.in", encoding: .utf8)
        var components: [String] = []
        for name in ["MAJOR", "MINOR", "REVISION"] {
            let expression = try NSRegularExpression(pattern: "set\\(PICO_SDK_VERSION_\(name) ([0-9]+)\\)")
            let match = try XCTUnwrap(expression.firstMatch(in: version, range: NSRange(version.startIndex..., in: version)))
            let value = String(version[try XCTUnwrap(Range(match.range(at: 1), in: version))])
            components.append(value)
            header = header.replacingOccurrences(of: "${PICO_SDK_VERSION_\(name)}", with: value)
        }
        return header.replacingOccurrences(of: "${PICO_SDK_VERSION_STRING}", with: components.joined(separator: "."))
    }

    private static func fixtures(extended: Bool) -> [Fixture] {
        var values = [
            Fixture(pio: "nop\njmp 0\n", swift: "Nop(); Jmp(to: 0)"),
            Fixture(pio: """
            .origin 4
            .side_set 2 opt pindirs
            .in 32 left auto 12
            .out 20 left auto 24
            .set 3
            .fifo tx
            .mov_status rxfifo < 9
            .clock_div 12.5
            nop
            .wrap_target
            nop side 3 [2]
            pull
            .wrap
            jmp 1

            """, swift: """
            Nop(); WrapTarget(); Nop().sideSet(value: 3).delay(2); Pull(); Wrap(); Jmp(to: 1)
            """, options: "sideSet: .init(bits: 2, optional: true)", configuration: [
                ("input", ".init(pinCount: 32, right: false, automatic: true, threshold: 12)"),
                ("output", ".init(pinCount: 20, right: false, automatic: true, threshold: 24)"),
                ("setCount", "3"), ("fifo", ".tx"), ("movStatus", ".rxLessThan(9)"),
                ("clockDivider", "12.5"), ("sideSetPinDirections", "true")
            ], origin: 4),
            Fixture(pio: ".fifo rx\n.mov_status txfifo < 7\nnop\n", swift: "Nop()",
                configuration: [("fifo", ".rx"), ("movStatus", ".txLessThan(7)")]),
        ]
        if extended {
            values.append(Fixture(pio: """
            .pio_version 1
            .in 16 right manual 32
            .fifo putget
            .mov_status irq next set 6
            wait 1 gpio 47

            """, swift: "Wait(true, .gpio(47))", options: "version: .rp2350", configuration: [
                ("input", ".init(pinCount: 16)"), ("fifo", ".putGet"), ("movStatus", ".irqSet(6, bank: .next)")]))
            for (pio, swift) in [("txput", "txPut"), ("txget", "txGet")] {
                values.append(Fixture(pio: ".pio_version 1\n.fifo \(pio)\n.mov_status irq prev set 3\nnop\n",
                                      swift: "Nop()", options: "version: .rp2350",
                                      configuration: [("fifo", ".\(swift)"), ("movStatus", ".irqSet(3, bank: .previous)")]))
            }
        }
        return values
    }

    private func run(_ executable: String, _ arguments: [String], in directory: URL) throws {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.currentDirectoryURL = directory; process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) failed:\n\(output)")
        if process.terminationStatus != 0 { throw NSError(domain: "SDKInteropCheck", code: Int(process.terminationStatus)) }
        if !output.isEmpty { print(output) }
    }
}
