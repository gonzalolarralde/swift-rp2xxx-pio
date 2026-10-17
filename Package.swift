// swift-tools-version: 6.3

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "RP2xxxPIO",
    platforms: [.macOS(.v11)],
    products: [
        .library(name: "RP2xxxPIO", targets: ["RP2xxxPIO"]),
    ],
    traits: [.trait(name: "SDKInterop", description: "Enable CPicoSDK program and state-machine configuration adapters")],
    dependencies: [
        .package(url: "https://github.com/gonzalolarralde/swift-constexpr.git", branch: "main"),
        .package(url: "https://github.com/gonzalolarralde/CPicoSDK.git", branch: "main"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "603.0.2"),
    ],
    targets: [
        .target(name: "RP2xxxPIO", dependencies: [
            "RP2xxxPIOCore", "RP2xxxPIOMacros",
            .target(name: "RP2xxxPIOSDK", condition: .when(traits: ["SDKInterop"])),
        ]),
        .target(name: "RP2xxxPIOCore", dependencies: [
            .product(name: "ConstExpr", package: "swift-constexpr"),
        ]),
        .target(name: "RP2xxxPIOSDK", dependencies: [
            "RP2xxxPIOCore", .product(name: "CPicoSDK", package: "CPicoSDK", condition: .when(traits: ["SDKInterop"])),
        ]),
        .macro(name: "RP2xxxPIOMacros", dependencies: [
            "RP2xxxPIOCore",
            .product(name: "ConstExprMacroSupport", package: "swift-constexpr"),
            .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            .product(name: "SwiftSyntax", package: "swift-syntax"),
            .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        ]),
        .testTarget(name: "RP2xxxPIOTests", dependencies: ["RP2xxxPIO"], resources: [.copy("Fixtures")]),
        .testTarget(name: "RP2xxxPIOMacroTests", dependencies: [
            "RP2xxxPIOMacros",
            .product(name: "SwiftParser", package: "swift-syntax"),
            .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
        ]),
    ]
)
