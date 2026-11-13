// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FaceUnlock",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FaceUnlock", targets: ["FaceUnlock"])],
    targets: [
        .target(name: "RecognitionCore"),
        .target(name: "FaceModel", dependencies: ["RecognitionCore"], resources: [.copy("Models")]),
        .executableTarget(name: "FaceUnlock", dependencies: ["RecognitionCore", "FaceModel"]),
        .executableTarget(name: "ModelCheck", dependencies: ["FaceModel", "RecognitionCore"], path: "Tools/ModelCheck"),
        .testTarget(name: "RecognitionCoreTests", dependencies: ["RecognitionCore", "FaceUnlock", "FaceModel"])
    ]
)
