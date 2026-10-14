// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Focus",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "FocusCore"),
    ],
    targets: [
        .target(
            name: "VirtualDisplay",
            path: "VirtualDisplay",
            linkerSettings: [.linkedFramework("CoreGraphics")]
        ),
        .executableTarget(
            name: "Focus",
            dependencies: [
                .product(name: "FocusCore", package: "FocusCore"),
                "VirtualDisplay",
            ],
            path: "Sources",
            resources: [
                // KaTeX bundle for math rendering in Practice Mode.
                // Loaded by MathView via WKWebView from the app bundle.
                .copy("Resources/katex"),
                .copy("Resources/leetcode.json"),
            ]
        )
    ]
)
