// swift-tools-version: 6.3
import PackageDescription

let rp2040 = Context.environment["PIO_BOARD"] == "pico"
let package = Package(
    name: "PIOFirmware",
    products: [.library(name: "PIOFirmware", type: .static, targets: ["PIOFirmware"])],
    dependencies: [
        .package(path: "../..", traits: ["SDKInterop"]),
        .package(url: "https://github.com/gonzalolarralde/CPicoSDK.git", branch: "main", traits: [
            .init(name: rp2040 ? "Platform_RP2040" : "Platform_RP2350"),
            .init(name: rp2040 ? "Variant_RP2040" : "Variant_RP2350A"),
            .init(name: "Radio_None"), .init(name: "BootStage2_W25Q080"), .init(name: "StdIO_UART"),
        ]),
    ],
    targets: [.target(name: "PIOFirmware", dependencies: [
        .product(name: "RP2xxxPIO", package: "swift-rp2xxx-pio"),
        .product(name: "CPicoSDK", package: "CPicoSDK"),
    ])]
)
