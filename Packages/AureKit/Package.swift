// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AureKit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Aure", targets: ["AureApp"]),
        .executable(name: "aure-eval", targets: ["AureEval"]),
        .library(name: "AureKit", targets: ["AureCore", "AureInference", "AureModels", "AureProfile",
                                           "AureAccessibility", "AureBridge", "AureUI"]),
    ],
    targets: [
        .target(name: "AureCore"),
        .target(name: "AureInference", dependencies: ["AureCore"]),
        .target(name: "AureModels", dependencies: ["AureCore"], resources: [.copy("Resources")]),
        .target(name: "AureProfile", dependencies: ["AureCore"]),
        .target(name: "AureAccessibility", dependencies: ["AureCore"]),
        .target(name: "AureBridge", dependencies: ["AureCore"]),
        .target(name: "AureUI", dependencies: ["AureCore", "AureInference", "AureModels", "AureProfile", "AureAccessibility"]),
        .executableTarget(name: "AureApp", dependencies: ["AureUI"]),
        .executableTarget(name: "AureEval", dependencies: ["AureCore", "AureInference", "AureModels"]),
        .testTarget(name: "AureCoreTests", dependencies: ["AureCore"]),
        .testTarget(name: "AureInferenceTests", dependencies: ["AureInference", "AureCore"]),
        .testTarget(name: "AureModelsTests", dependencies: ["AureModels"]),
        .testTarget(name: "AureUITests", dependencies: ["AureUI"]),
        .testTarget(name: "AureAccessibilityTests", dependencies: ["AureAccessibility"]),
    ]
)
