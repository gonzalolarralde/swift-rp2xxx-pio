// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "PartialPrograms",
    platforms: [.macOS(.v11)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "PartialPrograms", dependencies: [
        .product(name: "RP2xxxPIO", package: "swift-rp2xxx-pio"),
    ])]
)
