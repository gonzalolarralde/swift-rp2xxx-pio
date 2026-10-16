// swift-tools-version: 6.3

import PackageDescription

let package = Package(
    name: "PicoAudio",
    products: [
        .library(name: "PicoAudio", type: .static, targets: ["PicoAudio"]),
    ],
    dependencies: [
        .package(path: "../..", traits: ["SDKInterop"]),
        .package(
            url: "https://github.com/gonzalolarralde/CPicoSDK.git",
            branch: "main",
            traits: [
                "BootStage2_W25Q080",
                "StdIO_Automatic",
                "Platform_RP2350",
                "Variant_RP2350A",
                "Radio_None",
            ]
        ),
    ],
    targets: [
        .target(
            name: "PicoAudio",
            dependencies: [
                .product(name: "CPicoSDK", package: "CPicoSDK"),
                .product(name: "RP2xxxPIO", package: "swift-rp2xxx-pio"),
            ]
        ),
    ]
)
