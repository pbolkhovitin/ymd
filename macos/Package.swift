// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ymd-menubar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "ymd-menubar",
            path: "Sources/ymd-menubar"
        ),
        .testTarget(name: "YmdMenuBarTests", dependencies: ["ymd-menubar"], path: "Tests/YmdMenuBarTests")
    ]
)
