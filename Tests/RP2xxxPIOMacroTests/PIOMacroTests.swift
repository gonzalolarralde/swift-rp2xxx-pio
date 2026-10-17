import RP2xxxPIOMacros
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@Test func strictRejectsUnknownInput() throws {
    let file = Parser.parse(source: "#constPIO { Set(.x, runtimeValue) }")
    let node = try #require(file.statements.first?.item.as(MacroExpansionExprSyntax.self))
    let context = BasicMacroExpansionContext()
    _ = try ConstPIOMacro.expansion(of: node, in: context)
    #expect(context.diagnostics.count == 1)
}

@Test func numericLabelsPreserveSourceNamesInDiagnostics() throws {
    let missing = try expanded("@PIOLabel var missing; Jmp(to: missing)", strict: true)
    #expect(missing.messages.first?.contains("undefined label 'missing'") == true)
    let duplicate = try expanded("@PIOLabel var repeated; Label(repeated); Label(repeated); Nop()", strict: true)
    #expect(duplicate.messages.first?.contains("duplicate symbol 'repeated'") == true)
    #expect(!missing.messages.joined().contains("$pio-label:"))
    let namedSymbol = try expanded("@PIOLabel var loop; Label(loop); Define(\"$pio-label:0\", 1); Define(\"$pio-label:0\", 2); Nop()", strict: true)
    #expect(namedSymbol.messages.first?.contains("duplicate symbol '$pio-label:0'") == true)
}

@Test func constantExpansionContainsOnlyProgramData() throws {
    for strict in [false, true] {
        let result = try expanded("Set(.x, 3); Jmp(to: 0)", strict: strict)
        #expect(result.messages.isEmpty)
        #expect(result.source.contains("RP2xxxPIOCore.PIOProgramData(instructions: [57379, 0]"))
        #expect(!result.source.contains(".assemble("))
        #expect(!result.source.contains("buildExpression"))
        #expect(!result.source.contains("Set("))
        #expect(!result.source.contains("PIOConfiguration"))
        #expect(result.source.contains("._validated(") == !strict)
    }
}

@Test func bothMacrosDiagnoseInvalidKnownPrograms() throws {
    for strict in [false, true] {
        for (body, options, message) in [
            ("Set(.x, 32)", "", "SET value must be between 0 and 31; got 32"),
            ("@PIOLabel var missing; Jmp(to: missing)", "", "undefined label"),
            ("Nop()", "sideSet: .init(bits: 1)", "every instruction requires a side-set value"),
            ("Wait(true, .jmpPin())", "", "requires RP2350"),
            ("@PIOLabel var a; Label(a); Label(a); Nop()", "", "duplicate symbol"),
        ] {
            let result = try expanded(body, strict: strict, options: options)
            #expect(result.messages.count == 1)
            #expect(result.messages.first?.contains(message) == true)
        }
    }
}

@Test func partialExpansionPreencodesConstantInstructions() throws {
    let result = try expanded("Set(.x, 3); Set(.y, runtimeValue); Nop()", strict: false)
    #expect(result.messages.isEmpty)
    #expect(result.source.contains("Swift.UInt16(57379)"))
    #expect(result.source.contains("Swift.UInt16(41026)"))
    #expect(result.source.contains("runtimeValue"))
    #expect(!result.source.contains("Set(.x, 3)"))
    #expect(result.source.contains("PIOAssembler.assemble"))
    let strict = try expanded("Set(.x, 3); Set(.y, runtimeValue); Nop()", strict: true)
    #expect(strict.messages.count == 1)
}

@Test func unknownBranchKeepsLazyClosureButPreencodesItsConstantInstructions() throws {
    let result = try expanded("if enabled { Set(.x, read()) } else { Nop() }", strict: false)
    #expect(result.messages.isEmpty)
    #expect(result.source.contains("PIOAssembler.source {"))
    #expect(result.source.contains("if enabled { Set(.x, read()) } else { Swift.UInt16(41026) }"))
}

@Test func partialExpansionKeepsLabelsBranchesAndDynamicOperands() throws {
    let result = try expanded("""
    @PIOLabel var start
    Label(start)
    Out(.pins, 1).sideSet(value: 2)
    Out(.pins, count).sideSet(value: 0)
    if extra { Set(.x, 14).sideSet(value: 1) }
    Nop().sideSet(value: side)
    Jmp(.xDecrement, to: start).sideSet(value: 3)
    Label(entry)
    Set(.x, 14).sideSet(value: 3)
    """, strict: false, options: "sideSet: .init(bits: 2)")
    #expect(result.messages.isEmpty)
    #expect(result.source.contains("@PIOLabel var start"))
    #expect(result.source.contains("Label(start)"))
    #expect(result.source.contains("Label(entry)"))
    #expect(result.source.contains("if extra { Swift.UInt16(59438) }"))
    #expect(result.source.contains("Swift.UInt16(28673)"))
    #expect(result.source.contains("Swift.UInt16(63534)"))
    #expect(result.source.contains("Out(.pins, count).sideSet(value: 0)"))
    #expect(result.source.contains("Nop().sideSet(value: side)"))
    #expect(result.source.contains("Jmp(.xDecrement, to: start).sideSet(value: 3)"))
    #expect(!result.source.contains("_symbol"))
}

@Test func partialExpansionPreservesMetadataInItsSelectedBranch() throws {
    let result = try expanded("""
    if upper { Wait(true, .gpio(47)) } else { Wait(true, .gpio(0)) }
    if indexed { Mov(to: .rxFIFO(.y), from: .isr) } else { Push() }
    Mov(to: .osr, from: .rxFIFO(.index(index)))
    """, strict: false, options: "version: .rp2350")
    #expect(result.messages.isEmpty)
    for metadata in ["gpioRanges: 4, fifo: 0", "gpioRanges: 1, fifo: 0", "gpioRanges: 0, fifo: 4", "gpioRanges: 0, fifo: 1"] {
        #expect(result.source.contains(metadata))
    }
    #expect(result.source.contains("if upper"))
    #expect(result.source.contains("if indexed"))
    #expect(result.source.contains(".index(index)"))
    #expect(!result.source.contains("Wait("))
    #expect(!result.source.contains("Push()"))
}

@Test func partialExpansionFoldsSwitchCasesAndLexicalConstants() throws {
    let result = try expanded("""
    let count = 3
    Out(.pins, count)
    switch mode {
    case 0:
        let count = 7
        Out(.pins, count)
    default:
        Nop()
    }
    Set(.x, value)
    """, strict: false)
    #expect(result.messages.isEmpty)
    #expect(result.source.contains("switch mode"))
    #expect(result.source.contains("Swift.UInt16(24579)"))
    #expect(result.source.contains("Swift.UInt16(24583)"))
    #expect(result.source.contains("Swift.UInt16(41026)"))
    #expect(result.source.contains("Set(.x, value)"))
    #expect(!result.source.contains("Out("))
}

@Test func partialExpansionDoesNotGuessDynamicEncodingOptionsOrJumpBounds() throws {
    let options = try expanded("Out(.pins, 1); Set(.x, value)", strict: false, options: "sideSet: encoding")
    #expect(options.messages.isEmpty)
    #expect(!options.source.contains("Swift.UInt16("))
    let jump = try expanded("Jmp(to: 2); if extra { Nop() }; Nop()", strict: false)
    #expect(jump.messages.isEmpty)
    #expect(jump.source.contains("Jmp(to: 2)"))
    #expect(jump.source.components(separatedBy: "Swift.UInt16(41026)").count == 3)
}

@Test func partialExpansionLeavesInvalidUncertainInstructionsForRuntimeValidation() throws {
    let result = try expanded("if enabled { Set(.x, 99) }; Nop()", strict: false)
    #expect(result.messages.isEmpty)
    #expect(result.source.contains("Set(.x, 99)"))
    #expect(result.source.contains("Swift.UInt16(41026)"))
}

@Test func partialExpansionRespectsBindingShadowsAndOptionalPatterns() throws {
    let result = try expanded("""
    let count = 3
    if let count = input { Out(.pins, count) } else { Out(.pins, count) }
    let Nop = replacement
    Nop()
    Set(.x, value)
    """, strict: false)
    #expect(result.messages.isEmpty)
    #expect(result.source.contains("if let count = input { Out(.pins, count) } else { Swift.UInt16(24579) }"))
    #expect(result.source.contains("Nop()"))
}

@Test func localLabelsAreErasedAndExternalLabelsOnlyBindOffsets() throws {
    for strict in [false, true] {
        let result = try expanded("@PIOLabel var loop; Label(loop); Jmp(to: loop); Label(entry); Nop()", strict: strict)
        #expect(result.messages.isEmpty)
        #expect(result.source.contains("(entry, 1)"))
        #expect(!result.source.contains("loop"))
        #expect(!result.source.contains("_symbol"))
        #expect(!result.source.contains(".assemble("))
        #expect(result.source.components(separatedBy: "entry").count == 2)
    }
}

@Test func strictRejectsDynamicOptionsAndIdentityDependentControlFlow() throws {
    let options = try expanded("Nop()", strict: true, options: "sideSet: encoding")
    #expect(options.messages.count == 1)
    #expect(options.messages.first?.contains("program options") == true)
    let identity = try expanded("@PIOLabel var loop; if loop == entry { Nop() }; Label(loop); Nop()", strict: true)
    #expect(identity.messages.count == 1)
    let alias = try expanded("Label(entry); Jmp(to: alias)", strict: true)
    #expect(alias.messages.count == 1)
    #expect(alias.messages.first?.contains("matching Label declaration") == true)
}

private func expanded(_ body: String, strict: Bool, options: String = "") throws -> (source: String, messages: [String]) {
    let name = strict ? "constPIO" : "pio"
    let file = Parser.parse(source: "#\(name)(\(options)) { \(body) }")
    let node = try #require(file.statements.first?.item.as(MacroExpansionExprSyntax.self))
    let context = BasicMacroExpansionContext()
    let expression = try strict
        ? ConstPIOMacro.expansion(of: node, in: context)
        : PIOMacro.expansion(of: node, in: context)
    return (expression.trimmedDescription, context.diagnostics.map(\.message))
}
