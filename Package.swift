// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TelephoneBoothTranscription",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "telephone-booth-transcription", targets: ["TranscriptionApp"]),
        .library(name: "TranscriptionCore", targets: ["TranscriptionCore"]),
        .library(name: "TranscriptionShared", targets: ["TranscriptionShared"]),
        .library(name: "TranscriptionAuth", targets: ["TranscriptionAuth"]),
        .library(name: "TranscriptionReview", targets: ["TranscriptionReview"]),
        .library(name: "TranscriptionOnDevice", targets: ["TranscriptionOnDevice"]),
        .library(name: "TranscriptionPipeline", targets: ["TranscriptionPipeline"]),
        .library(name: "TranscriptionOperator", targets: ["TranscriptionOperator"])
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "TranscriptionShared",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "TranscriptionAuth",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "TranscriptionReview",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "TranscriptionOnDevice",
            dependencies: [
                "TranscriptionShared",
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "TranscriptionPipeline",
            dependencies: [
                "TranscriptionShared",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "TranscriptionOperator",
            dependencies: [
                "TranscriptionShared",
                "TranscriptionPipeline",
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "TranscriptionCore",
            dependencies: [
                "TranscriptionShared",
                "TranscriptionOnDevice",
                "TranscriptionPipeline",
                "TranscriptionOperator",
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
            dependencies: [
                "TranscriptionShared",
                "TranscriptionOnDevice",
                "TranscriptionPipeline",
                "TranscriptionAuth",
                "TranscriptionReview"
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .testTarget(
            name: "TranscriptionAuthTests",
            dependencies: ["TranscriptionAuth"]
        ),
        .testTarget(
            name: "TranscriptionReviewTests",
            dependencies: ["TranscriptionReview"]
        ),
        .testTarget(
            name: "TranscriptionCoreTests",
            dependencies: [
                "TranscriptionCore",
                "TranscriptionOnDevice",
                "TranscriptionPipeline",
                "TranscriptionOperator",
                .product(name: "HummingbirdTesting", package: "hummingbird")
            ]
        )
    ]
)
