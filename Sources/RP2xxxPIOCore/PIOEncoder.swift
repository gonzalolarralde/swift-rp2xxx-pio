/// Encoding layout and range rules track pico-sdk/tools/pioasm at
/// 079c6f39023649b154152db30f1d781e884879bc. No hardware APIs are called here.
struct PIOEncoder {
    let version: PIOVersion
    let sideSet: PIOSideSet?
    let labels: [PIOLabelHandle: Int]
    let count: Int
    var usedGPIORanges: UInt8 = 0
    var fifoRequirements: PIOFIFORequirements = []

    mutating func mergeMetadata(gpioRanges: UInt8, fifo: UInt8) throws(PIOAssemblyError) {
        usedGPIORanges |= gpioRanges
        guard usedGPIORanges & 5 != 5 else {
            throw .invalidConfiguration("WAIT GPIO cannot mix GPIO 0...15 with GPIO 32...47")
        }
        fifoRequirements.formUnion(.init(rawValue: fifo))
    }

    mutating func encode(_ instruction: PIOInstruction) throws(PIOAssemblyError) -> UInt16 {
        let word = try operation(instruction.operation)
        let totalSideBits = sideSet?.totalBits ?? 0
        var modifiers = try checked(instruction.delayCycles, 0, (1 << (5 - totalSideBits)) - 1, "delay")
        if let value = instruction.sideSetValue {
            guard let sideSet else { throw .invalidConfiguration("sideSet(value:) requires the sideSet program option") }
            let side = try checked(value, 0, (1 << sideSet.bits) - 1, "side-set value")
            modifiers |= side << (5 - totalSideBits)
            if sideSet.optional { modifiers |= 16 }
        } else if let sideSet, !sideSet.optional {
            throw .invalidConfiguration("every instruction requires a side-set value when sideSet is not optional")
        }
        return UInt16(word | modifiers << 8)
    }

    private mutating func operation(_ operation: PIOOperation) throws(PIOAssemblyError) -> Int {
        switch operation {
        case .jmp(let condition, let target):
            let address: Int
            switch target {
            case .address(let value): address = value
            case .label(let label):
                guard let offset = labels[label] else { throw .undefinedLabel(label.diagnosticName) }
                address = offset
            }
            return condition.rawValue << 5 | (try checked(address, 0, count - 1, "jump target"))
        case .wait(let polarity, let source): return try wait(polarity, source)
        case .input(let source, let amount): return 0x4000 | source.rawValue << 5 | ((try checked(amount, 1, 32, "input bit count")) & 31)
        case .output(let destination, let amount): return 0x6000 | destination.rawValue << 5 | ((try checked(amount, 1, 32, "output bit count")) & 31)
        case .push(let ifFull, let blocking):
            fifoRequirements.insert(.push)
            return 0x8000 | (ifFull ? 0x40 : 0) | (blocking ? 0x20 : 0)
        case .pull(let ifEmpty, let blocking): return 0x8080 | (ifEmpty ? 0x40 : 0) | (blocking ? 0x20 : 0)
        case .mov(let destination, let source, let operation): return try mov(destination, source, operation)
        case .irq(let operation, let index, let mode):
            try checkIRQMode(mode)
            return 0xc000 | operation.rawValue << 5 | mode.rawValue << 3 | (try checked(index, 0, 7, "IRQ index"))
        case .set(let destination, let value): return 0xe000 | destination.rawValue << 5 | (try checked(value, 0, 31, "SET value"))
        case .nop: return 0xa042
        }
    }

    private mutating func wait(_ polarity: Bool, _ source: PIOWaitSource) throws(PIOAssemblyError) -> Int {
        let sourceBits: Int
        let index: Int
        switch source {
        case .gpio(let value):
            sourceBits = 0
            index = try checked(value, 0, version == .rp2040 ? 31 : 47, "WAIT GPIO")
            try mergeMetadata(gpioRanges: 1 << (index / 16), fifo: 0)
        case .pin(let value): sourceBits = 1; index = try checked(value, 0, 31, "WAIT pin")
        case .irq(let value, let mode):
            try checkIRQMode(mode)
            sourceBits = 2; index = (try checked(value, 0, 7, "WAIT IRQ")) | mode.rawValue << 3
        case .jmpPin(let offset):
            try requireRP2350("WAIT jmpPin")
            sourceBits = 3; index = try checked(offset, 0, 3, "WAIT jmpPin offset")
        }
        return 0x2000 | (polarity ? 0x80 : 0) | sourceBits << 5 | (index & 31)
    }

    private func checkIRQMode(_ mode: PIOIRQIndexMode) throws(PIOAssemblyError) {
        if mode == .previous || mode == .next { try requireRP2350("previous/next IRQ addressing") }
    }

    private func requireRP2350(_ feature: String) throws(PIOAssemblyError) {
        guard version == .rp2350 else { throw .unsupportedFeature(feature + " requires RP2350") }
    }

    private func fifoIndex(_ index: PIOFIFOIndex) throws(PIOAssemblyError) -> Int {
        switch index {
        case .y: return 0
        case .index(let value): return (try checked(value, 0, 7, "RX FIFO index")) | 8
        }
    }

    private mutating func mov(_ destination: PIOMovDestination, _ source: PIOMovSource, _ operation: PIOMovOperation) throws(PIOAssemblyError) -> Int {
        if case .rxFIFO(let index) = destination {
            try requireRP2350("MOV RX FIFO")
            guard source == .isr else {
                throw .invalidConfiguration("MOV to RX FIFO requires ISR")
            }
            fifoRequirements.insert(.indexedWrite)
            // Like pioasm, the operation field is not encoded for indexed moves.
            return 0x8010 | (try fifoIndex(index))
        }
        if case .rxFIFO(let index) = source {
            try requireRP2350("MOV RX FIFO")
            guard destination == .osr else {
                throw .invalidConfiguration("MOV from RX FIFO requires OSR")
            }
            fifoRequirements.insert(.indexedRead)
            return 0x8090 | (try fifoIndex(index))
        }
        let dest: Int
        switch destination {
        case .pins: dest = 0
        case .x: dest = 1
        case .y: dest = 2
        case .pinDirs: try requireRP2350("MOV pinDirs"); dest = 3
        case .exec: dest = 4
        case .pc: dest = 5
        case .isr: dest = 6
        case .osr: dest = 7
        case .rxFIFO: preconditionFailure("indexed destination handled above")
        }
        let src: Int
        switch source {
        case .pins: src = 0
        case .x: src = 1
        case .y: src = 2
        case .null: src = 3
        case .status: src = 5
        case .isr: src = 6
        case .osr: src = 7
        case .rxFIFO: preconditionFailure("indexed source handled above")
        }
        return 0xa000 | dest << 5 | operation.rawValue << 3 | src
    }
}
