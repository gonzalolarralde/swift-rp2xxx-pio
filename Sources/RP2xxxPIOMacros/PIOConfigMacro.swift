import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// Specializes the *call list* by argument presence, without interpreting runtime
/// expressions or assembling instructions. Inlinable validation is shared with
/// PIOConfiguration; Swift can fold constant values through the generated calls.
public struct PIOConfigMacro: ExpressionMacro {
    public static func expansion(of node: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext) throws -> ExprSyntax {
        let types = ["program": "PIOProgram", "offset": "UInt32", "input": "PIOShiftConfiguration?",
            "output": "PIOShiftConfiguration?", "setCount": "Int?", "fifo": "PIOFIFOJoin",
            "movStatus": "PIOMovStatus?", "clockDivider": "Double", "sideSetPinDirections": "Bool", "pins": "PIOPinMapping"]
        var names: [String: String] = [:]
        var statements: [String] = []
        var parameters: [String] = []
        var parameterTypes: [String] = []
        var values: [String] = []
        // Bind in call-site order, once, with contextual types for .init and enum cases.
        for argument in node.arguments {
            guard let label = argument.label?.text, let type = types[label] else { continue }
            let name = context.makeUniqueName(label).text
            names[label] = name
            let qualified = ["UInt32", "Int?", "Double", "Bool"].contains(type) ? "Swift.\(type)" : "RP2xxxPIOCore.\(type)"
            parameters.append("_ \(name): \(qualified)")
            parameterTypes.append(qualified)
            values.append(argument.expression.trimmedDescription)
        }
        guard let program = names["program"], let offset = names["offset"] else {
            return "Swift.fatalError(\"pioConfig requires program and offset\")"
        }
        let setup = context.makeUniqueName("setup").text
        let result = context.makeUniqueName("result").text
        let value = context.makeUniqueName("value").text
        let arguments = ["input", "output", "setCount", "fifo", "movStatus", "clockDivider", "sideSetPinDirections", "pins"]
            .compactMap { label in names[label].map { "\(label): \($0)" } }.joined(separator: ", ")
        statements.append("let \(setup) = try RP2xxxPIOCore.PIOConfiguration(program: \(program)\(arguments.isEmpty ? "" : ", " + arguments))")
        statements.append("try \(setup)._validateOffset(\(offset))")
        statements.append("var \(result) = CPicoSDK.pio_get_default_sm_config()")
        statements.append("CPicoSDK.sm_config_set_wrap(&\(result), \(offset) + Swift.UInt32(\(program).wrapTarget), \(offset) + Swift.UInt32(\(program).wrap))")
        statements.append("if let \(value) = \(program).sideSet { CPicoSDK.sm_config_set_sideset(&\(result), Swift.UInt32(\(value).totalBits), \(value).optional, \(setup).sideSetPinDirections) }")
        for (label, sdk) in [("input", "in"), ("output", "out")] where names[label] != nil {
            statements.append("""
            if let \(value) = \(setup).\(label) {
                CPicoSDK.sm_config_set_\(sdk)_pin_count(&\(result), Swift.UInt32(\(value).pinCount))
                CPicoSDK.sm_config_set_\(sdk)_shift(&\(result), \(value).right, \(value).automatic, Swift.UInt32(\(value).threshold))
            }
            """)
        }
        if names["setCount"] != nil {
            statements.append("if let \(value) = \(setup).setCount { CPicoSDK.sm_config_set_set_pin_count(&\(result), Swift.UInt32(\(value))) }")
        }
        if names["fifo"] != nil {
            statements.append("CPicoSDK.sm_config_set_fifo_join(&\(result), CPicoSDK.pio_fifo_join(rawValue: \(setup)._sdkFIFO))")
        }
        if names["movStatus"] != nil {
            let status = context.makeUniqueName("status").text
            statements.append("""
            if let \(value) = \(setup).movStatus {
                let \(status) = RP2xxxPIOCore.PIOConfiguration._sdkStatus(\(value))
                CPicoSDK.sm_config_set_mov_status(&\(result), CPicoSDK.pio_mov_status_type(rawValue: \(status).0), \(status).1)
            }
            """)
        }
        if names["clockDivider"] != nil {
            statements.append("CPicoSDK.sm_config_set_clkdiv_int_frac(&\(result), \(setup).clockDividerInteger, \(setup).clockDividerFraction)")
        }
        if names["pins"] != nil {
            for (field, sdk) in [("input", "in_pin_base"), ("output", "out_pin_base"), ("set", "set_pin_base"), ("sideSet", "sideset_pin_base"), ("jump", "jmp_pin")] {
                statements.append("if let \(value) = \(setup).pins.\(field) { CPicoSDK.sm_config_set_\(sdk)(&\(result), Swift.UInt32(\(value))) }")
            }
        }
        statements.append("return \(result)")
        let make = context.makeUniqueName("makeConfig").text
        // Swift cannot attach @inline to a closure. A trivial factory exposes
        // an always-inline local function without capturing client expressions.
        // Its explicit function type preserves contextual typing of literals
        // and .init arguments, and keeps argument evaluation outside validation.
        return ExprSyntax(stringLiteral: """
        { () -> (\(parameterTypes.joined(separator: ", "))) throws(RP2xxxPIOCore.PIOConfigurationError) -> CPicoSDK.pio_sm_config in
            @inline(__always) func \(make)(\(parameters.joined(separator: ", "))) throws(RP2xxxPIOCore.PIOConfigurationError) -> CPicoSDK.pio_sm_config {
                \(statements.joined(separator: "\n"))
            }
            return \(make)
        }()(\(values.joined(separator: ", ")))
        """)
    }
}
