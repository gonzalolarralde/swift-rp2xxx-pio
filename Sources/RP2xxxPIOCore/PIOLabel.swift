internal import ConstExpr

/// An opaque label identity. An offset belongs to a program, never to this handle.
public struct PIOLabelHandle: Hashable, Sendable {
    private final class Identity: Sendable {}
    private let identity: Identity?
    package let symbolicName: String?

    public init() { identity = Identity(); symbolicName = nil }
    private init(symbol: String) { identity = nil; symbolicName = symbol }

    /// Compiler-generated program-local symbol; not a globally named label.
    @ConstExpr(registrationAccess: .package)
    public static func _symbol(_ name: String) -> PIOLabelHandle { Self(symbol: name) }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        if let a = lhs.identity, let b = rhs.identity { return a === b }
        return lhs.identity == nil && rhs.identity == nil && lhs.symbolicName == rhs.symbolicName
    }

    public func hash(into hasher: inout Hasher) {
        if let identity { hasher.combine(0); hasher.combine(ObjectIdentifier(identity)) }
        else { hasher.combine(1); hasher.combine(symbolicName) }
    }

    package var diagnosticName: String { symbolicName ?? "captured label" }
}

/// Declares a fresh, immutable label handle without a string name.
/// Capture it from outside a program to look up that program's entry-point offset.
@propertyWrapper
public struct PIOLabel: Sendable {
    public let wrappedValue: PIOLabelHandle
    public init() { wrappedValue = PIOLabelHandle() }
}
