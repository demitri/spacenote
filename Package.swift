// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "spacenote",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "SpikeSpaces", path: "Sources/SpikeSpaces"),
        .executableTarget(name: "SpaceNote", path: "Sources/SpaceNote"),
        .testTarget(name: "SpaceNoteTests",
                    dependencies: ["SpaceNote"],
                    path: "Tests/SpaceNoteTests")
    ]
)
