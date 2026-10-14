// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "I2SExample",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "I2SExample", targets: ["I2SExample"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "I2SExample",
            dependencies: [
                .product(name: "RP2xxxPIO", package: "swift-rp2xxx-pio"),
            ]
        ),
    ]
)
