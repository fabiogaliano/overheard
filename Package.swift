// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "overheard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "overheard",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
