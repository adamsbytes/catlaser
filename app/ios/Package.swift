// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CatLaser",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CatLaserProto",
            targets: ["CatLaserProto"],
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.30.0",
        ),
    ],
    targets: [
        .target(
            name: "CatLaserProto",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/CatLaserProto",
        ),
        .testTarget(
            name: "CatLaserProtoTests",
            dependencies: ["CatLaserProto"],
            path: "Tests/CatLaserProtoTests",
        ),
    ],
    swiftLanguageModes: [.v6],
)
