import Foundation
import RP2xxxPIO
import XCTest

/// Differential oracle: independently assembled pioasm programs, not a second
/// Swift implementation of the encoding formulas. Run Scripts/prepare-pioasm.sh
/// once, or provide PIOASM to select a compatible reference executable.
final class PIOOracleTests: XCTestCase {
    func testEveryInstructionOperandAndModifierAgainstPioasm() throws {
        let fixtures = instructionFixtures()
        let source = fixtures.enumerated().map { index, fixture in
            ".program case_\(index)\n" + fixture.pio + "\n"
        }.joined(separator: "\n")
        let programs = try oracle(source)
        XCTAssertEqual(programs.count, fixtures.count)
        for (fixture, expected) in zip(fixtures, programs) {
            let actual = try PIOAssembler.assemble(options: fixture.options, PIOProgramSource(fixture.statements))
            _ = try PIOConfiguration(program: actual, fifo: fixture.fifo)
            let words = try XCTUnwrap(expected["instructions"] as? [[String: Any]])
                .map { try XCTUnwrap($0["hex"] as? String).flatMapHex() }
            XCTAssertEqual(actual.instructions, words, fixture.pio)
            XCTAssertEqual(Int(actual.usedGPIORanges), expected["usedGPIORanges"] as? Int, fixture.pio)
        }
        XCTAssertGreaterThan(fixtures.count, 300)
    }

    func testConfigurationAndSymbolsAgainstPioasm() throws {
        let expected = try XCTUnwrap(oracle("""
        .program metadata
        .pio_version 1
        .origin 4
        .side_set 2 opt pindirs
        .in 16 left auto 12
        .out 20 left auto 24
        .set 3
        .fifo rx
        .mov_status irq next set 6
        .clock_div 12.5
        .define public limit 123
        nop
        .wrap_target
        public loop:
        wait 1 gpio 47 side 3 [2]
        push
        .wrap
        jmp loop
        """).first)
        XCTAssertEqual(expected["pioVersion"] as? Int, 1)
        XCTAssertEqual(expected["origin"] as? Int, 4)
        XCTAssertEqual(expected["wrapTarget"] as? Int, 1)
        XCTAssertEqual(expected["wrap"] as? Int, 2)
        XCTAssertEqual(expected["usedGPIORanges"] as? Int, 4)
        XCTAssertEqual(expected["publicSymbols"] as? [String: Int], ["limit": 123])
        XCTAssertEqual(expected["publicLabels"] as? [String: Int], ["loop": 1])
        let clock = try XCTUnwrap(expected["clockDiv"] as? [String: Int])
        XCTAssertEqual(clock["int"], 12)
        // The pinned pioasm computes an out-of-range float-to-uint8 cast, and
        // optimized builds can expose 3200 in JSON. The SDK parameter is UInt8.
        XCTAssertEqual(UInt8(truncatingIfNeeded: try XCTUnwrap(clock["frac"])), 128)
        let input = try XCTUnwrap(expected["in"] as? [String: Any])
        XCTAssertEqual(input["pinCount"] as? Int, 16)
        XCTAssertEqual(input["right"] as? Bool, false)
        XCTAssertEqual(input["autopush"] as? Bool, true)
        XCTAssertEqual(input["threshold"] as? Int, 12)
        let output = try XCTUnwrap(expected["out"] as? [String: Any])
        XCTAssertEqual(output["pinCount"] as? Int, 20)
        XCTAssertEqual(output["right"] as? Bool, false)
        XCTAssertEqual(output["autopull"] as? Bool, true)
        XCTAssertEqual(output["threshold"] as? Int, 24)
    }

    private struct Fixture {
        let pio: String
        let statements: [PIOStatement]
        var options: PIOOptions = .init()
        var fifo: PIOFIFOJoin = .txrx
    }

    func testI2SLocalLoopsAndExternalEntryAgainstPioasm() throws {
        @PIOLabel var entryPoint
        let constant = #constPIO(sideSet: .init(bits: 2)) {
            @PIOLabel var bitloop0
            @PIOLabel var bitloop1
            Label(bitloop1)
            Out(.pins, 1).sideSet(value: 2)
            Jmp(.xDecrement, to: bitloop1).sideSet(value: 3)
            Out(.pins, 1).sideSet(value: 0)
            Set(.x, 14).sideSet(value: 1)
            Label(bitloop0)
            Out(.pins, 1).sideSet(value: 0)
            Jmp(.xDecrement, to: bitloop0).sideSet(value: 1)
            Out(.pins, 1).sideSet(value: 2)
            Label(entryPoint)
            Set(.x, 14).sideSet(value: 3)
        }
        func dynamic(swapped: Bool) throws(PIOAssemblyError) -> PIOProgramData {
            try #pio(sideSet: .init(bits: 2)) {
                @PIOLabel var bitloop0
                @PIOLabel var bitloop1
                Label(bitloop1)
                Out(.pins, 1).sideSet(value: swapped ? 1 : 2)
                Jmp(.xDecrement, to: bitloop1).sideSet(value: 3)
                Out(.pins, 1).sideSet(value: 0)
                Set(.x, 14).sideSet(value: swapped ? 2 : 1)
                Label(bitloop0)
                Out(.pins, 1).sideSet(value: 0)
                Jmp(.xDecrement, to: bitloop0).sideSet(value: swapped ? 2 : 1)
                Out(.pins, 1).sideSet(value: swapped ? 1 : 2)
                Label(entryPoint)
                Set(.x, 14).sideSet(value: 3)
            }
        }
        for swapped in [false, true] {
            let expected = try XCTUnwrap(oracle("""
            .program i2s
            .side_set 2
            bitloop1:
            out pins, 1 side \(swapped ? 1 : 2)
            jmp x-- bitloop1 side 3
            out pins, 1 side 0
            set x, 14 side \(swapped ? 2 : 1)
            bitloop0:
            out pins, 1 side 0
            jmp x-- bitloop0 side \(swapped ? 2 : 1)
            out pins, 1 side \(swapped ? 1 : 2)
            public entryPoint:
            set x, 14 side 3
            """).first)
            let words = try XCTUnwrap(expected["instructions"] as? [[String: String]])
                .map { try XCTUnwrap($0["hex"]).flatMapHex() }
            let runtime = try dynamic(swapped: swapped)
            XCTAssertEqual(runtime.instructions, words)
            XCTAssertEqual(runtime.labels[entryPoint], 7)
            if !swapped {
                XCTAssertEqual(constant.instructions, words)
                XCTAssertEqual(constant.labels[entryPoint], 7)
                XCTAssertEqual(constant.labels.count, 1)
            }
        }
    }

    func testLEDRowForwardLabelsAgainstPioasm() throws {
        let program = #constPIO(sideSet: .init(bits: 1)) {
            let width = 64
            let loops = width / 4 - 1
            @PIOLabel var shift0
            @PIOLabel var loop0
            @PIOLabel var noOE0
            @PIOLabel var noOE1
            @PIOLabel var noOE2
            @PIOLabel var noOE3
            @PIOLabel var loop1
            @PIOLabel var loop2
            Label(shift0)
            Set(.x, loops).sideSet(value: 0)
            Irq(.wait, 0).sideSet(value: 0)
            Label(loop0)
            Pull().sideSet(value: 0)
            Out(.pins, 6).sideSet(value: 0)
            Out(.y, 2).sideSet(value: 1)
            Label(noOE0)
            Jmp(.notX, to: loop1).sideSet(value: 1)
            Out(.pins, 6).sideSet(value: 0)
            Out(.y, 2).sideSet(value: 0)
            Jmp(.notY, to: noOE1).sideSet(value: 1).delay(1)
            Set(.pins, 0).sideSet(value: 0)
            Label(noOE1)
            Out(.pins, 6).sideSet(value: 0)
            Out(.y, 2).sideSet(value: 0)
            Jmp(.notY, to: noOE2).sideSet(value: 1).delay(1)
            Set(.pins, 0).sideSet(value: 0)
            Label(noOE2)
            Out(.pins, 6).sideSet(value: 0)
            Out(.y, 2).sideSet(value: 0)
            Jmp(.notY, to: noOE3).sideSet(value: 1).delay(1)
            Set(.pins, 0).sideSet(value: 0)
            Label(noOE3)
            Jmp(.xDecrement, to: loop0).sideSet(value: 0)
            Label(loop1)
            Set(.pins, 3).sideSet(value: 0)
            Out(.pins, 6).sideSet(value: 0).delay(1)
            Out(.null, 2).sideSet(value: 1).delay(1)
            Out(.pins, 6).sideSet(value: 0).delay(1)
            Out(.null, 2).sideSet(value: 1).delay(1)
            Out(.pins, 6).sideSet(value: 0).delay(1)
            Label(loop2)
            Irq(.clear, 1).sideSet(value: 1).delay(1)
        }
        let expected = try XCTUnwrap(oracle("""
        .program led_row
        .side_set 1
        .out 6
        .set 2
        shift0:
        set x, 15 side 0
        irq wait 0 side 0
        loop0:
        pull block side 0
        out pins, 6 side 0
        out y, 2 side 1
        noOE0:
        jmp !x loop1 side 1
        out pins, 6 side 0
        out y, 2 side 0
        jmp !y noOE1 side 1 [1]
        set pins, 0 side 0
        noOE1:
        out pins, 6 side 0
        out y, 2 side 0
        jmp !y noOE2 side 1 [1]
        set pins, 0 side 0
        noOE2:
        out pins, 6 side 0
        out y, 2 side 0
        jmp !y noOE3 side 1 [1]
        set pins, 0 side 0
        noOE3:
        jmp x-- loop0 side 0
        loop1:
        set pins, 3 side 0
        out pins, 6 side 0 [1]
        out null, 2 side 1 [1]
        out pins, 6 side 0 [1]
        out null, 2 side 1 [1]
        out pins, 6 side 0 [1]
        loop2:
        irq clear 1 side 1 [1]
        """).first)
        let words = try XCTUnwrap(expected["instructions"] as? [[String: String]])
            .map { try XCTUnwrap($0["hex"]).flatMapHex() }
        XCTAssertEqual(program.instructions, words)
        XCTAssertEqual(program.instructions.count, 26)
        XCTAssertTrue(program.labels.isEmpty)
    }

    private func instructionFixtures() -> [Fixture] {
        var result: [Fixture] = []
        func add(_ text: String, _ instruction: PIOInstruction, version: PIOVersion = .rp2040,
                 prelude: String = "", sideSet: PIOSideSet? = nil, fifo: PIOFIFOJoin = .txrx) {
            let header = version == .rp2350 ? ".pio_version 1\n" : ""
            result.append(Fixture(pio: header + prelude + text,
                statements: [.instruction(instruction)], options: .init(version: version, sideSet: sideSet), fifo: fifo))
        }
        let conditions: [(String, PIOJmpCondition)] = [
            ("", .always), ("!x, ", .notX), ("x--, ", .xDecrement), ("!y, ", .notY),
            ("y--, ", .yDecrement), ("x!=y, ", .xNotEqualY), ("pin, ", .pin), ("!osre, ", .notOSREmpty),
        ]
        for (name, value) in conditions { add("jmp \(name)0", Jmp(value, to: 0)) }
        for polarity in [false, true] {
            let bit = polarity ? 1 : 0
            for pin in 0..<48 { add("wait \(bit) gpio \(pin)", Wait(polarity, .gpio(pin)), version: .rp2350) }
            for pin in [0, 15, 31] {
                add("wait \(bit) pin \(pin)", Wait(polarity, .pin(pin)))
                add("wait \(bit) gpio \(pin)", Wait(polarity, .gpio(pin)))
            }
            for offset in 0..<4 { add("wait \(bit) jmppin + \(offset)", Wait(polarity, .jmpPin(offset: offset)), version: .rp2350) }
            for (text, mode) in [("", PIOIRQIndexMode.absolute), (" rel", .relative), (" prev", .previous), (" next", .next)] {
                for index in [0, 7] {
                    let address = mode == .relative ? "\(index) rel" : "\(text) \(index)"
                    add("wait \(bit) irq \(address)", Wait(polarity, .irq(index, mode: mode)), version: .rp2350)
                }
            }
        }
        for count in [1, 16, 31, 32] {
            for (name, source) in [("pins", PIOInSource.pins), ("x", .x), ("y", .y), ("null", .null), ("status", .status), ("isr", .isr), ("osr", .osr)] {
                add("in \(name), \(count)", In(source, count))
            }
            for (name, destination) in [("pins", PIOOutDestination.pins), ("x", .x), ("y", .y), ("null", .null), ("pindirs", .pinDirs), ("pc", .pc), ("isr", .isr), ("exec", .exec)] {
                add("out \(name), \(count)", Out(destination, count))
            }
        }
        for conditional in [false, true] {
            for blocking in [false, true] {
                add("push \(conditional ? "iffull" : "") \(blocking ? "block" : "noblock")", Push(ifFull: conditional, blocking: blocking))
                add("pull \(conditional ? "ifempty" : "") \(blocking ? "block" : "noblock")", Pull(ifEmpty: conditional, blocking: blocking))
            }
        }
        let destinations: [(String, PIOMovDestination)] = [("pins", .pins), ("x", .x), ("y", .y), ("pindirs", .pinDirs), ("exec", .exec), ("pc", .pc), ("isr", .isr), ("osr", .osr)]
        let sources: [(String, PIOMovSource)] = [("pins", .pins), ("x", .x), ("y", .y), ("null", .null), ("status", .status), ("isr", .isr), ("osr", .osr)]
        for (destText, destination) in destinations {
            for (sourceText, source) in sources {
                for (opText, op) in [("", PIOMovOperation.none), ("!", .invert), ("::", .bitReverse)] {
                    add("mov \(destText), \(opText)\(sourceText)", Mov(to: destination, from: source, operation: op), version: .rp2350)
                }
            }
        }
        for (indexText, index) in [("y", PIOFIFOIndex.y)] + (0..<8).map({ (String($0), PIOFIFOIndex.index($0)) }) {
            for (modeText, mode) in [("txput", PIOFIFOJoin.txPut), ("putget", .putGet)] {
                add("mov rxfifo[\(indexText)], isr", Mov(to: .rxFIFO(index), from: .isr), version: .rp2350, prelude: ".fifo \(modeText)\n", fifo: mode)
            }
            for (modeText, mode) in [("txget", PIOFIFOJoin.txGet), ("putget", .putGet)] {
                add("mov osr, rxfifo[\(indexText)]", Mov(to: .osr, from: .rxFIFO(index)), version: .rp2350, prelude: ".fifo \(modeText)\n", fifo: mode)
            }
        }
        for (opText, op) in [("set", PIOIRQOperation.set), ("wait", .wait), ("clear", .clear)] {
            for index in [0, 7] {
                add("irq \(opText) \(index)", Irq(op, index))
                add("irq \(opText) \(index) rel", Irq(op, index, mode: .relative))
                add("irq prev \(opText) \(index)", Irq(op, index, mode: .previous), version: .rp2350)
                add("irq next \(opText) \(index)", Irq(op, index, mode: .next), version: .rp2350)
            }
        }
        for (name, dest) in [("pins", PIOSetDestination.pins), ("x", .x), ("y", .y), ("pindirs", .pinDirs)] {
            for value in [0, 1, 31] { add("set \(name), \(value)", Set(dest, value)) }
        }
        add("nop", Nop())
        for bits in 0...5 {
            for optional in [false, true] where bits + (optional ? 1 : 0) <= 5 {
                let delay = (1 << (5 - bits - (optional ? 1 : 0))) - 1
                for value in [0, (1 << bits) - 1] {
                    add("nop side \(value) [\(delay)]", Nop().sideSet(value: value).delay(delay),
                        prelude: ".side_set \(bits) \(optional ? "opt" : "")\n", sideSet: .init(bits: bits, optional: optional))
                }
                if optional { add("nop [\(delay)]", Nop().delay(delay), prelude: ".side_set \(bits) opt\n", sideSet: .init(bits: bits, optional: true)) }
            }
        }
        for delay in 0...31 { add("nop [\(delay)]", Nop().delay(delay)) }
        for word in [0, 1, 65535] { result.append(.init(pio: ".word \(word)", statements: [Word(word)])) }
        return result
    }

    private func oracle(_ source: String) throws -> [[String: Any]] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = ProcessInfo.processInfo.environment["PIOASM"] ?? root.appendingPathComponent(".build/pioasm-reference/build/pioasm").path
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw XCTSkip("Build the pinned pioasm with Scripts/prepare-pioasm.sh, or set PIOASM") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pio-oracle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("oracle.pio")
        let output = directory.appendingPathComponent("oracle.json")
        try source.write(to: input, atomically: true, encoding: .utf8)
        let process = Process()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-o", "json", input.path, output.path]
        process.standardError = errors
        try process.run()
        let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
        return try XCTUnwrap(json["programs"] as? [[String: Any]])
    }
}

private extension String {
    func flatMapHex() throws -> UInt16 {
        // pioasm carries the sixth WAIT GPIO bit above the instruction word.
        // C SDK output narrows to uint16_t and uses usedGPIORanges separately.
        UInt16(truncatingIfNeeded: try XCTUnwrap(UInt32(self, radix: 16)))
    }
}
