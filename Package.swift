// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TelephoneBoothTranscription",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "telephone-booth-transcription", targets: ["TranscriptionApp"]),
        .library(name: "TranscriptionCore", targets: ["TranscriptionCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "TranscriptionCore",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "TranscriptionApp",
            dependencies: ["TranscriptionCore"],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "TranscriptionCoreTests",
            dependencies: [
                "TranscriptionCore",
                .product(name: "HummingbirdTesting", package: "hummingbird")
            ]
        )
    ]
)
