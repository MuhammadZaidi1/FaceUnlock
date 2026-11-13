// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FaceUnlock",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FaceUnlock", targets: ["FaceUnlock"])],
    targets: [.executableTarget(name: "FaceUnlock")]
)
