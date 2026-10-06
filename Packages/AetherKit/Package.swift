// swift-tools-version: 6.2
import PackageDescription
import Foundation

let rustLibraryPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../.build/rust/lib").standardized.path
let package = Package(
    name: "AetherKit",
    platforms: [.macOS("14.6")],
    products: ["SharedSupport", "TimerFeature", "ClipboardFeature", "ShortcutsFeature", "PromptFeature", "MemoFeature", "PortsFeature"].map { .library(name: $0, targets: [$0]) },
    dependencies: [
        .package(url: "https://github.com/sindresorhus/Defaults", exact: "9.0.3"),
        .package(url: "https://github.com/TheBoredTeam/MacroVisionKit", exact: "0.1.0"),
        .package(url: "https://github.com/Lakr233/SkyLightWindow", revision: "4a7e8628c85e6b2ec429b57657a556a2171a4864")
    ],
    targets: [
        .target(name: "CAetherCore", linkerSettings: [.unsafeFlags(["-L" + rustLibraryPath])]),
        .target(name: "RustCore", dependencies: ["CAetherCore"]),
        .target(name: "SharedSupport"),
        .target(name: "WhatPortCore", dependencies: ["CAetherCore"]),
        .target(name: "WhatPortIOKit", dependencies: ["WhatPortCore"], linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "PortsFeature", dependencies: ["SharedSupport", "WhatPortCore", "WhatPortIOKit", "CAetherCore"]),
        .testTarget(name: "WhatPortCoreTests", dependencies: ["WhatPortCore", "WhatPortIOKit"]),
        .testTarget(name: "PortsFeatureTests", dependencies: ["PortsFeature"]),
        .target(name: "ShortcutCore", dependencies: ["RustCore", "CAetherCore"]),
        .target(name: "ShortcutsFeature", dependencies: ["ShortcutCore", "SharedSupport", "CAetherCore"]),
        .target(name: "ClipboardFeature", dependencies: ["SharedSupport", "RustCore", "CAetherCore"]),
        .target(name: "PromptFeature", dependencies: ["SharedSupport", "RustCore", "CAetherCore"]),
        .target(name: "MemoFeature", dependencies: ["SharedSupport", "RustCore", "CAetherCore"]),
        .target(name: "TimerFeature", dependencies: ["SharedSupport", "RustCore", "CAetherCore", .product(name: "Defaults", package: "Defaults"), .product(name: "MacroVisionKit", package: "MacroVisionKit"), .product(name: "SkyLightWindow", package: "SkyLightWindow")]),
        .testTarget(name: "ShortcutCoreTests", dependencies: ["ShortcutCore"]),
        .testTarget(name: "ShortcutsFeatureTests", dependencies: ["ShortcutsFeature"]),
        .testTarget(name: "TimerFeatureTests", dependencies: ["TimerFeature"]),
        .testTarget(name: "ClipboardFeatureTests", dependencies: ["ClipboardFeature"]),
        .testTarget(name: "PromptFeatureTests", dependencies: ["PromptFeature"]),
        .testTarget(name: "MemoFeatureTests", dependencies: ["MemoFeature"]),
        .testTarget(name: "SharedSupportTests", dependencies: ["SharedSupport"]),
        .testTarget(name: "RustCoreTests", dependencies: ["RustCore"])
    ],
    swiftLanguageModes: [.v5]
)
