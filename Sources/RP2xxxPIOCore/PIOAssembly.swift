struct PIOAssembly {
    var version: PIOVersion = .rp2040
    var sideSet: PIOSideSet?
    var wrapTarget: Int?
    var wrap: Int?
    var symbols: [PIOSymbol] = []
    var publicSymbols: [PIOSymbol] = []
    var labels: [PIOLabelHandle: Int] = [:]
    var instructions: [PIOStatement] = []
    var configured: [String] = []

    init(options: PIOOptions) {
        version = options.version; sideSet = options.sideSet
    }

    mutating func assemble(_ source: PIOProgramSource) throws(PIOAssemblyError) -> PIOProgramData {
        for statement in source.statements {
            switch statement {
            case .instruction, .word:
                guard instructions.count < 32 else { throw .invalidStructure("a program may contain at most 32 instructions") }
                instructions.append(statement)
            case .label(let label):
                guard labels.updateValue(instructions.count, forKey: label) == nil else {
                    throw .duplicateSymbol(label.diagnosticName)
                }
            case .symbol(let name, let value, let isPublic):
                try addSymbol(name: name, value: value, isLabel: false, isPublic: isPublic)
            case .directive(let directive): try configure(directive)
            }
        }
        try validateConfiguration()
        var encoder = PIOEncoder(version: version, sideSet: sideSet, labels: labels, count: instructions.count)
        var words: [UInt16] = []
        for statement in instructions {
            switch statement {
            case .instruction(let instruction): words.append(try encoder.encode(instruction))
            case .word(let value):
                if let sideSet, !sideSet.optional {
                    throw .invalidConfiguration("raw words cannot supply mandatory side-set bits")
                }
                words.append(UInt16(try checked(value, 0, 65535, "word")))
            default: break
            }
        }
        if encoder.fifoRequirements.contains(.push), !encoder.fifoRequirements.intersection([.indexedRead, .indexedWrite]).isEmpty {
            throw .invalidConfiguration("Push and indexed RX FIFO moves require incompatible FIFO modes")
        }
        return PIOProgramData(
            instructions: words, version: version, sideSet: sideSet,
            wrapTarget: wrapTarget ?? 0, wrap: wrap ?? max(0, words.count - 1),
            usedGPIORanges: encoder.usedGPIORanges, symbols: publicSymbols, labels: labels,
            fifoRequirements: encoder.fifoRequirements
        )
    }

    private mutating func addSymbol(name: String, value: Int, isLabel: Bool, isPublic: Bool) throws(PIOAssemblyError) {
        guard !name.isEmpty else { throw .invalidStructure("symbol names must not be empty") }
        guard !symbols.contains(where: { $0.name == name }) else { throw .duplicateSymbol(name) }
        let symbol = PIOSymbol(name: name, value: value, isLabel: isLabel)
        symbols.append(symbol)
        if isPublic { publicSymbols.append(symbol) }
    }

    private mutating func reserve(_ name: String) throws(PIOAssemblyError) {
        guard !configured.contains(name) else { throw .invalidConfiguration("duplicate " + name + " directive") }
        configured.append(name)
    }

    private mutating func configure(_ directive: PIODirective) throws(PIOAssemblyError) {
        switch directive {
        case .wrapTarget: try reserve("wrapTarget"); wrapTarget = instructions.count
        case .wrap:
            try reserve("wrap")
            guard !instructions.isEmpty else { throw .invalidStructure("wrap must follow an instruction") }
            wrap = instructions.count - 1
        }
    }

    private func validateConfiguration() throws(PIOAssemblyError) {
        if let wrapTarget {
            guard wrapTarget < instructions.count else { throw .invalidStructure("wrapTarget must precede an instruction") }
        }
        if let sideSet { _ = try checked(sideSet.bits, 0, sideSet.optional ? 4 : 5, "side-set bit count") }
    }
}
