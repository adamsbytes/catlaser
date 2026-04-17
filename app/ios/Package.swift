// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CatLaser",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CatLaserProto",
            targets: ["CatLaserProto"],
        ),
        .library(
            name: "CatLaserAuth",
            targets: ["CatLaserAuth"],
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-protobuf.git",
            from: "1.30.0",
        ),
        .package(
            url: "https://github.com/openid/AppAuth-iOS.git",
            from: "2.0.0",
        ),
        .package(
            url: "https://github.com/apple/swift-crypto.git",
            from: "3.0.0",
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
        .target(
            name: "CatLaserAuth",
            dependencies: [
                .product(
                    name: "AppAuth",
                    package: "AppAuth-iOS",
                    condition: .when(platforms: [.iOS, .macOS]),
                ),
                .product(
                    name: "Crypto",
                    package: "swift-crypto",
                    condition: .when(platforms: [.linux, .windows, .android, .wasi]),
                ),
            ],
            path: "Sources/CatLaserAuth",
        ),
        .testTarget(
            name: "CatLaserAuthTests",
            dependencies: ["CatLaserAuth"],
            path: "Tests/CatLaserAuthTests",
        ),
    ],
    swiftLanguageModes: [.v6],
)
