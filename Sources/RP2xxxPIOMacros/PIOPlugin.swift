import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxMacros

@main
struct PIOPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [PIOMacro.self, ConstPIOMacro.self]
}

public struct PIOMacro: ExpressionMacro {
    public static func expansion(of node: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext) throws -> ExprSyntax {
        PIOExpansion.expand(node, in: context, strict: false)
    }
}

public struct ConstPIOMacro: ExpressionMacro {
    public static func expansion(of node: some FreestandingMacroExpansionSyntax, in context: some MacroExpansionContext) throws -> ExprSyntax {
        PIOExpansion.expand(node, in: context, strict: true)
    }
}
