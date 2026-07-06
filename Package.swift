// swift-tools-version: 6.2
import PackageDescription

import Foundation
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let hasSherpaFramework = FileManager.default.fileExists(
    atPath: packageDir + "/Frameworks/sherpa-onnx.xcframework/Info.plist"
)

var targets: [Target] = [
    .executableTarget(
        name: "Muse",
        dependencies: hasSherpaFramework ? ["SherpaOnnxLib"] : [],
        path: "Muse",
        exclude: ["Resources"],
        cSettings: hasSherpaFramework ? [.headerSearchPath("Bridge")] : [],
        swiftSettings: [
            .swiftLanguageMode(.v5),
        ] + (hasSherpaFramework ? [.define("HAS_SHERPA_ONNX")] : []),
        linkerSettings: hasSherpaFramework ? [
            .linkedLibrary("c++"),
            .linkedFramework("Accelerate"),
            .linkedFramework("Foundation"),
        ] : []
    ),
    .testTarget(
        name: "MuseTests",
        dependencies: ["Muse"],
        path: "MuseTests"
    ),
]

if hasSherpaFramework {
    targets.insert(
        .binaryTarget(name: "SherpaOnnxLib", path: "Frameworks/sherpa-onnx.xcframework"),
        at: 0
    )
}

let package = Package(
    name: "Muse",
    platforms: [.macOS(.v14)],
    targets: targets
)
