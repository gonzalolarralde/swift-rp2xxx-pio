internal import ConstExpr

/// An opaque label identity. An offset belongs to a program, never to this handle.
public struct PIOLabelHandle: Hashable, Sendable {
    private final class Identity: Sendable {}
    private let identity: Identity?
    // These IDs are allocated without reuse within one compiler assembly.
    // They are never used as the identity of a runtime declaration.
    package let symbolicID: UInt64?

    public init() { identity = Identity(); symbolicID = nil }
    private init(symbol: UInt64) { identity = nil; symbolicID = symbol }

    /// Compiler-generated program-local symbol; not a globally named label.
    @ConstExpr(registrationAccess: .package)
    public static func _symbol(_ id: UInt64) -> PIOLabelHandle { Self(symbol: id) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        if let a = lhs.identity, let b = rhs.identity { return a === b }
        return lhs.identity == nil && rhs.identity == nil && lhs.symbolicID == rhs.symbolicID
    }

    public func hash(into hasher: inout Hasher) {
        if let identity { hasher.combine(0); hasher.combine(ObjectIdentifier(identity)) }
        else { hasher.combine(1); hasher.combine(symbolicID) }
    }

    // Source names and numeric-to-text conversion belong to the compiler.
    // Runtime handles intentionally have no display-name payload.
    package var diagnosticName: String { "captured label" }
}

/// Declares a fresh, immutable label handle without a string name.
/// Capture it from outside a program to look up that program's entry-point offset.
@propertyWrapper
public struct PIOLabel: Sendable {
    public let wrappedValue: PIOLabelHandle
    public init() { wrappedValue = PIOLabelHandle() }
}
