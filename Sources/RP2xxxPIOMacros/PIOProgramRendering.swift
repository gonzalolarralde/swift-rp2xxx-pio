import RP2xxxPIOCore
import SwiftSyntax
import SwiftSyntaxBuilder

enum PIOProgramRendering {
    static func render(_ program: PIOProgramData) -> String {
        let words = program.instructions.map { String($0) }.joined(separator: ", ")
        let symbols = program.symbols.map {
            "RP2xxxPIOCore.PIOSymbol(name: \(StringLiteralExprSyntax(content: $0.name).trimmedDescription), value: \($0.value), isLabel: \($0.isLabel))"
        }.joined(separator: ", ")
        let side = program.sideSet.map { "RP2xxxPIOCore.PIOSideSet(bits: \($0.bits), optional: \($0.optional))" } ?? "nil"
        return """
        RP2xxxPIOCore.PIOProgramData(instructions: [\(words)], version: .\(program.version == .rp2040 ? "rp2040" : "rp2350"),
            sideSet: \(side), wrapTarget: \(program.wrapTarget), wrap: \(program.wrap),
            usedGPIORanges: \(program.usedGPIORanges), symbols: [\(symbols)],
            fifoRequirements: RP2xxxPIOCore.PIOFIFORequirements(rawValue: \(program.fifoRequirements.rawValue)))
        """
    }
}
