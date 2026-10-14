import Foundation
import RP2xxxPIO
import XCTest

final class PIOGoldenTests: XCTestCase {
    @PIOLabel private var basicLoop
    @PIOLabel private var metadataLoop

    func testCheckedInUpstreamWordsAndMetadata() throws {
        let resource = try XCTUnwrap(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "Fixtures"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: resource)) as? [String: Any])
        let programs = try XCTUnwrap(root["programs"] as? [[String: Any]])
        let actual = try configurationsByName()
        for expected in programs {
            let name = try XCTUnwrap(expected["name"] as? String)
            let config = try XCTUnwrap(actual[name])
            let program = config.program
            let words = try XCTUnwrap(expected["instructions"] as? [[String: String]]).map {
                UInt16(truncatingIfNeeded: try XCTUnwrap(UInt32(try XCTUnwrap($0["hex"]), radix: 16)))
            }
            XCTAssertEqual(program.instructions, words, name)
            XCTAssertEqual(program.version.rawValue, expected["pioVersion"] as? Int, name)
            XCTAssertEqual(config.origin ?? -1, expected["origin"] as? Int, name)
            XCTAssertEqual(program.wrap, expected["wrap"] as? Int, name)
            XCTAssertEqual(program.wrapTarget, expected["wrapTarget"] as? Int, name)
            XCTAssertEqual(Int(program.usedGPIORanges), expected["usedGPIORanges"] as? Int, name)
            let handle = name == "basic" ? basicLoop : metadataLoop
            let labels: [String: Int] = program.labels[handle].map { ["loop": $0] } ?? [:]
            XCTAssertEqual(labels, expected["publicLabels"] as? [String: Int])
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: program.symbols.filter { !$0.isLabel }.map { ($0.name, $0.value) }), expected["publicSymbols"] as? [String: Int])
            try compare(config, with: expected)
        }
    }

    private func compare(_ config: PIOConfiguration, with expected: [String: Any]) throws {
        if let side = expected["sideset"] as? [String: Any] {
            XCTAssertEqual(config.program.sideSet?.totalBits, side["size"] as? Int)
            XCTAssertEqual(config.program.sideSet?.optional, side["optional"] as? Bool)
            XCTAssertEqual(config.sideSetPinDirections, side["pindirs"] as? Bool)
        } else { XCTAssertNil(config.program.sideSet) }
        for (key, actual, automatic) in [("in", config.input, "autopush"), ("out", config.output, "autopull")] {
            if let shift = expected[key] as? [String: Any] {
                XCTAssertEqual(actual?.pinCount, shift["pinCount"] as? Int)
                XCTAssertEqual(actual?.threshold, shift["threshold"] as? Int)
                XCTAssertEqual(actual?.right, shift["right"] as? Bool)
                XCTAssertEqual(actual?.automatic, shift[automatic] as? Bool)
            } else { XCTAssertNil(actual) }
        }
        XCTAssertEqual(config.setCount, expected["setCount"] as? Int)
        let fifoNames: [PIOFIFOJoin: String] = [.tx: "PIO_FIFO_JOIN_TX", .rx: "PIO_FIFO_JOIN_RX", .txPut: "PIO_FIFO_JOIN_TXPUT", .txGet: "PIO_FIFO_JOIN_TXGET", .putGet: "PIO_FIFO_JOIN_PUTGET"]
        XCTAssertEqual(fifoNames[config.fifo], expected["fifoConfig"] as? String)
        if let status = expected["movStatus"] as? [String: Any] {
            switch try XCTUnwrap(config.movStatus) {
            case .txLessThan(let n): XCTAssertEqual(status["type"] as? String, "STATUS_TX_LESSTHAN"); XCTAssertEqual(status["n"] as? Int, n)
            case .rxLessThan(let n): XCTAssertEqual(status["type"] as? String, "STATUS_RX_LESSTHAN"); XCTAssertEqual(status["n"] as? Int, n)
            case .irqSet(let n, let bank): XCTAssertEqual(status["type"] as? String, "STATUS_IRQ_SET"); XCTAssertEqual(status["n"] as? Int, n + bank.rawValue * 8)
            }
        } else { XCTAssertNil(config.movStatus) }
        let clock = expected["clockDiv"] as? [String: Int]
        XCTAssertEqual(Int(config.clockDividerInteger), clock?["int"] ?? 1)
        XCTAssertEqual(config.clockDividerFraction, UInt8(truncatingIfNeeded: clock?["frac"] ?? 0))
    }

    private func configurationsByName() throws -> [String: PIOConfiguration] {
        [
            "basic": try PIOConfiguration(program: #constPIO {
                Label(basicLoop)
                Set(.x, 31); Wait(true, .pin(2)); In(.pins, 32); Out(.x, 8)
                Push(); Pull(); Mov(to: .y, from: .x, operation: .invert)
                Irq(.wait, 3, mode: .relative); Nop(); Jmp(.xDecrement, to: basicLoop)
            }),
            "metadata": try PIOConfiguration(program: #constPIO(
                version: .rp2350, sideSet: .init(bits: 2, optional: true)
            ) {
                Define("limit", 123, isPublic: true)
                Nop(); WrapTarget()
                Label(metadataLoop)
                Wait(true, .gpio(47)).sideSet(value: 3).delay(2)
                Push(); Wrap(); Jmp(to: metadataLoop)
            }, origin: 4,
                input: .init(pinCount: 16, right: false, automatic: true, threshold: 12),
                output: .init(pinCount: 20, right: false, automatic: true, threshold: 24),
                setCount: 3, fifo: .rx, movStatus: .irqSet(6, bank: .next), clockDivider: 12.5,
                sideSetPinDirections: true),
            "indexed": try PIOConfiguration(program: #constPIO(version: .rp2350) {
                Mov(to: .rxFIFO(.y), from: .isr); Mov(to: .rxFIFO(.index(7)), from: .isr)
                Mov(to: .osr, from: .rxFIFO(.y)); Mov(to: .osr, from: .rxFIFO(.index(7)))
                Mov(to: .pinDirs, from: .x, operation: .bitReverse)
                Wait(false, .jmpPin(offset: 3)); Irq(.clear, 7, mode: .next)
            }, fifo: .putGet),
            "raw": try PIOConfiguration(program: #constPIO(sideSet: .init(bits: 0, optional: true)) {
                Word(65535); Nop().sideSet(value: 0).delay(15)
            }),
        ]
    }
}
