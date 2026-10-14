internal import ConstExpr

/// Only settings that affect instruction encoding.
@ConstExpr(registrationAccess: .package)
public struct PIOOptions: Equatable, Sendable {
    public let version: PIOVersion
    public let sideSet: PIOSideSet?
    public init(version: PIOVersion = .rp2040, sideSet: PIOSideSet? = nil) {
        self.version = version; self.sideSet = sideSet
    }
}
