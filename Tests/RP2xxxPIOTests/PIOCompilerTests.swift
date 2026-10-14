import Foundation
import XCTest

final class PIOCompilerTests: XCTestCase {
    func testStrictAndOrdinaryFailuresAreActualCompilerErrors() throws {
        for (source, message) in [
            ("let value = #constPIO { Set(.x, 32) }", "SET value must be between 0 and 31; got 32"),
            ("let value = try #pio { Set(.x, 32) }", "SET value must be between 0 and 31; got 32"),
            ("func f(_ input: Int) { _ = #constPIO { Set(.x, input) } }", "could not produce a compile-time constant"),
            ("func f(_ encoding: PIOSideSet) { _ = #constPIO(sideSet: encoding) { Nop() } }", "program options"),
            ("let value = #constPIO(clockDivider: 2) { Nop() }", "extra trailing closure"),
            ("func f() { @PIOLabel var entry; let alias = entry; _ = #constPIO { Label(entry); Jmp(to: alias) } }", "matching Label declaration"),
            ("func f() { _ = #constPIO { @PIOLabel var loop; Jmp(to: loop) } }", "undefined label"),
        ] {
            let result = try typecheck("import RP2xxxPIO\n" + source)
            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains(message), result.output)
            XCTAssertFalse(result.output.contains("cannot convert value of type 'Never'"), result.output)
            XCTAssertFalse(result.output.contains("no calls to throwing functions"), result.output)
        }
    }

    func testTypedThrowingContractAndRenderedIRCompile() throws {
        let result = try typecheck("""
        import RP2xxxPIO
        func dynamic(_ input: Int) throws(PIOAssemblyError) -> PIOProgram {
            try #pio(version: .rp2350) {
                Mov(to: .rxFIFO(.index(3)), from: .isr)
                Set(.x, input)
                Mov(to: .osr, from: .rxFIFO(.y))
                Wait(true, .irq(2, mode: .next))
            }
        }
        let folded = try #pio { Nop() }
        let strict = #constPIO { Nop() }
        func configure(_ clock: Double) throws(PIOConfigurationError) -> PIOConfiguration {
            try PIOConfiguration(program: #constPIO { Nop() }, clockDivider: clock)
        }
        func captured() throws(PIOAssemblyError) -> PIOProgram {
            @PIOLabel var entry
            let program = #constPIO(sideSet: .init(bits: 1, optional: true)) {
                @PIOLabel var loop
                let alias = loop
                Label(entry); Label(alias); Nop(); Jmp(to: loop)
            }
            precondition(program.labels[entry] == 0)
            return try #pio(sideSet: program.sideSet) { Nop() }
        }
        """)
        XCTAssertEqual(result.status, 0, result.output)
    }

    private func typecheck(_ source: String) throws -> (status: Int32, output: String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        // Discover the current test executable's build directory, including
        // non-default --scratch-path builds, rather than picking stale objects.
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var build = executable.deletingLastPathComponent()
        while build.path != "/", !FileManager.default.fileExists(atPath: build.appendingPathComponent("Modules").path) {
            build.deleteLastPathComponent()
        }
        if build.path == "/" { build = root.appendingPathComponent(".build/debug").resolvingSymlinksInPath() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pio-compile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("main.swift")
        try source.write(to: input, atomically: true, encoding: .utf8)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "swiftc", "-typecheck", "-swift-version", "6", "-warnings-as-errors",
            "-I", build.appendingPathComponent("Modules").path,
            "-load-plugin-executable", "\(build.appendingPathComponent("RP2xxxPIOMacros-tool").path)#RP2xxxPIOMacros",
            input.path,
        ]
        process.standardOutput = output; process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, text)
    }
}
