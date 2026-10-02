// swift-tools-version: 6.2
import PackageDescription
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
        .target(name: "SharedSupport"),
        .target(name: "WhatPortCore"),
        .target(name: "WhatPortIOKit", dependencies: ["WhatPortCore"], linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "PortsFeature", dependencies: ["SharedSupport", "WhatPortCore", "WhatPortIOKit"]),
        .testTarget(name: "WhatPortCoreTests", dependencies: ["WhatPortCore", "WhatPortIOKit"]),
        .testTarget(name: "PortsFeatureTests", dependencies: ["PortsFeature"]),
        .target(name: "ShortcutCore"),
        .target(name: "ShortcutsFeature", dependencies: ["ShortcutCore", "SharedSupport"]),
        .target(name: "ClipboardFeature", dependencies: ["SharedSupport"]),
        .target(name: "PromptFeature", dependencies: ["SharedSupport"]),
        .target(name: "MemoFeature", dependencies: ["SharedSupport"]),
        .target(name: "TimerFeature", dependencies: ["SharedSupport", .product(name: "Defaults", package: "Defaults"), .product(name: "MacroVisionKit", package: "MacroVisionKit"), .product(name: "SkyLightWindow", package: "SkyLightWindow")]),
        .testTarget(name: "ShortcutCoreTests", dependencies: ["ShortcutCore"]),
        .testTarget(name: "ShortcutsFeatureTests", dependencies: ["ShortcutsFeature"]),
        .testTarget(name: "TimerFeatureTests", dependencies: ["TimerFeature"]),
        .testTarget(name: "ClipboardFeatureTests", dependencies: ["ClipboardFeature"]),
        .testTarget(name: "PromptFeatureTests", dependencies: ["PromptFeature"]),
        .testTarget(name: "MemoFeatureTests", dependencies: ["MemoFeature"]),
        .testTarget(name: "SharedSupportTests", dependencies: ["SharedSupport"])
    ],
    swiftLanguageModes: [.v5]
)
