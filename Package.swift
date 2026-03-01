// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "radio-scrobbler",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "radio-scrobbler",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
            ]
        )
    ]
)
