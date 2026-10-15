// swift-tools-version:5.9
import PackageDescription
let package = Package(name: "storyprobe", platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../FocusCore")],
    targets: [.executableTarget(name: "storyprobe", dependencies: [.product(name: "FocusCore", package: "FocusCore")])])
