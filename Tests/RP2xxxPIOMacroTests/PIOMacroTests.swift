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

@Test func constantExpansionContainsOnlyProgramData() throws {
    for strict in [false, true] {
        let result = try expanded("Set(.x, 3); Jmp(to: 0)", strict: strict)
        #expect(result.messages.isEmpty)
        #expect(result.source.contains("RP2xxxPIOCore.PIOProgram(instructions: [57379, 0]"))
        #expect(!result.source.contains(".assemble("))
        #expect(!result.source.contains("buildExpression"))
        #expect(!result.source.contains("Set("))
        #expect(!result.source.contains("PIOConfiguration"))
        #expect(result.source.contains("._validated(") == !strict)
    }
}

@Test func configurationMacroEmitsOnlySelectedSDKCalls() throws {
    let defaults = try expandedConfiguration("program: code, offset: offset")
    #expect(defaults.contains("pio_get_default_sm_config"))
    #expect(defaults.contains("sm_config_set_wrap"))
    #expect(defaults.contains("sm_config_set_sideset"))
    for omitted in ["in_shift", "out_shift", "set_pin_count", "fifo_join", "mov_status", "clkdiv", "jmp_pin"] {
        #expect(!defaults.contains("sm_config_set_" + omitted))
    }
    #expect(!defaults.contains(".defaultConfig("))
    #expect(!defaults.contains(".assemble("))
    let configured = try expandedConfiguration("program: code, offset: offset, output: .init(pinCount: 6), fifo: .tx, clockDivider: rate")
    for included in ["out_shift", "out_pin_count", "fifo_join", "clkdiv_int_frac"] {
        #expect(configured.contains("sm_config_set_" + included))
    }
    #expect(!configured.contains("sm_config_set_in_shift"))
    #expect(!configured.contains("sm_config_set_mov_status"))
    #expect(configured.contains("@inline(__always)"))
}

@Test func configurationMacroBindsArgumentsOnceAndUsesHygienicNames() throws {
    let source = try expandedConfiguration("program: readProgram(), offset: readOffset(), input: readInput(), clockDivider: readClock(), pins: readPins()")
    let calls = ["readProgram()", "readOffset()", "readInput()", "readClock()", "readPins()"]
    for call in calls { #expect(source.components(separatedBy: call).count == 2) }
    #expect(source.contains(calls.joined(separator: ", ")))
    #expect(source.contains("RP2xxxPIOCore.PIOShiftConfiguration?"))
    #expect(source.contains("if let"))
    #expect(!source.contains("let result ="))
    #expect(!source.contains("let setup ="))
}

private func expandedConfiguration(_ arguments: String) throws -> String {
    let file = Parser.parse(source: "#pioConfig(\(arguments))")
    let node = try #require(file.statements.first?.item.as(MacroExpansionExprSyntax.self))
    let context = BasicMacroExpansionContext()
    let expression = try PIOConfigMacro.expansion(of: node, in: context)
    #expect(context.diagnostics.isEmpty)
    return expression.trimmedDescription
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

@Test func partialExpansionRendersComponentsWithoutReenteringBuilder() throws {
    let result = try expanded("Set(.x, 3); Set(.y, runtimeValue); Nop()", strict: false)
    #expect(result.messages.isEmpty)
    #expect(result.source.contains("PIOStatement.instruction"))
    #expect(result.source.contains("runtimeValue"))
    #expect(!result.source.contains("Set(.x, 3)"))
    #expect(result.source.contains("PIOAssembler.assemble"))
    let strict = try expanded("Set(.x, 3); Set(.y, runtimeValue); Nop()", strict: true)
    #expect(strict.messages.count == 1)
}

@Test func unknownBranchKeepsOriginalLazyClosure() throws {
    let result = try expanded("if enabled { Set(.x, read()) } else { Nop() }", strict: false)
    #expect(result.messages.isEmpty)
    #expect(result.source.contains("PIOAssembler.source {"))
    #expect(result.source.contains("if enabled { Set(.x, read()) } else { Nop() }"))
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
