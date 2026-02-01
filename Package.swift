// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HESlowdownReproducer",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "HESlowdownReproducer", targets: ["HESlowdownReproducer"]),
        .executable(name: "HEServer", targets: ["HEServer"]),
        .executable(name: "HEClient", targets: ["HEClient"]),
        .executable(name: "HEServerV1", targets: ["HEServerV1"]),
        .executable(name: "HEClientV1", targets: ["HEClientV1"]),
        .executable(name: "RESTServer", targets: ["RESTServer"]),
        .executable(name: "RESTClient", targets: ["RESTClient"]),
        .executable(name: "NativeRESTServer", targets: ["NativeRESTServer"]),
        .executable(name: "NativeRESTClient", targets: ["NativeRESTClient"]),
        .executable(name: "HEWorker", targets: ["HEWorker"]),
        .executable(name: "HEServerIsolated", targets: ["HEServerIsolated"]),
        .executable(name: "NativeBenchmark", targets: ["NativeBenchmark"]),
    ],
    dependencies: [
        .package(path: "./swift-homomorphic-encryption"),
        // gRPC-swift 2.x with NIO transport (HAS THE SLOWDOWN)
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        // gRPC-swift 1.x (NO SLOWDOWN - for comparison)
        .package(url: "https://github.com/grpc/grpc-swift.git", from: "1.23.0"),
        // SwiftNIO (for REST server)
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.31.1"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    ],
    targets: [
        // Shared library for gRPC service definitions (generated from .proto)
        .target(
            name: "Shared",
            dependencies: [
                .product(name: "HomomorphicEncryption", package: "swift-homomorphic-encryption"),
                .product(name: "HomomorphicEncryptionProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "PrivateNearestNeighborSearch", package: "swift-homomorphic-encryption"),
                .product(name: "ApplicationProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            exclude: ["Protos"],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        // All-in-one benchmark (direct vs gRPC comparison)
        .executableTarget(
            name: "HESlowdownReproducer",
            dependencies: [
                .product(name: "HomomorphicEncryption", package: "swift-homomorphic-encryption"),
                .product(name: "HomomorphicEncryptionProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "PrivateNearestNeighborSearch", package: "swift-homomorphic-encryption"),
                .product(name: "ApplicationProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        // Standalone gRPC server (demonstrates slowdown in real deployment)
        .executableTarget(
            name: "HEServer",
            dependencies: [
                "Shared",
                .product(name: "HomomorphicEncryption", package: "swift-homomorphic-encryption"),
                .product(name: "HomomorphicEncryptionProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "PrivateNearestNeighborSearch", package: "swift-homomorphic-encryption"),
                .product(name: "ApplicationProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        // Standalone gRPC client
        .executableTarget(
            name: "HEClient",
            dependencies: [
                "Shared",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        // Native benchmark (no gRPC, baseline comparison)
        .executableTarget(
            name: "NativeBenchmark",
            dependencies: [
                .product(name: "HomomorphicEncryption", package: "swift-homomorphic-encryption"),
                .product(name: "HomomorphicEncryptionProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "PrivateNearestNeighborSearch", package: "swift-homomorphic-encryption"),
                .product(name: "ApplicationProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        // ============================================================
        // Process-isolated gRPC server (HE runs in separate process)
        // ============================================================
        .executableTarget(
            name: "HEWorker",
            dependencies: [
                .product(name: "HomomorphicEncryption", package: "swift-homomorphic-encryption"),
                .product(name: "HomomorphicEncryptionProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "PrivateNearestNeighborSearch", package: "swift-homomorphic-encryption"),
                .product(name: "ApplicationProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        .executableTarget(
            name: "HEServerIsolated",
            dependencies: [
                "Shared",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        // ============================================================
        // Native REST server/client (Network.framework - NO NIO)
        // ============================================================
        .executableTarget(
            name: "NativeRESTServer",
            dependencies: [
                .product(name: "HomomorphicEncryption", package: "swift-homomorphic-encryption"),
                .product(name: "HomomorphicEncryptionProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "PrivateNearestNeighborSearch", package: "swift-homomorphic-encryption"),
                .product(name: "ApplicationProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        .executableTarget(
            name: "NativeRESTClient",
            dependencies: [
                .product(name: "HomomorphicEncryption", package: "swift-homomorphic-encryption"),
                .product(name: "HomomorphicEncryptionProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "PrivateNearestNeighborSearch", package: "swift-homomorphic-encryption"),
                .product(name: "ApplicationProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        // ============================================================
        // NIO REST server/client (SwiftNIO HTTP - shows slowdown)
        // ============================================================
        .executableTarget(
            name: "RESTServer",
            dependencies: [
                .product(name: "HomomorphicEncryption", package: "swift-homomorphic-encryption"),
                .product(name: "HomomorphicEncryptionProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "PrivateNearestNeighborSearch", package: "swift-homomorphic-encryption"),
                .product(name: "ApplicationProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        .executableTarget(
            name: "RESTClient",
            dependencies: [
                .product(name: "HomomorphicEncryption", package: "swift-homomorphic-encryption"),
                .product(name: "HomomorphicEncryptionProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "PrivateNearestNeighborSearch", package: "swift-homomorphic-encryption"),
                .product(name: "ApplicationProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        // ============================================================
        // gRPC-swift 1.x targets (NO SLOWDOWN - for comparison)
        // ============================================================
        // Shared library for gRPC 1.x service definitions
        .target(
            name: "SharedV1",
            dependencies: [
                .product(name: "HomomorphicEncryption", package: "swift-homomorphic-encryption"),
                .product(name: "HomomorphicEncryptionProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "PrivateNearestNeighborSearch", package: "swift-homomorphic-encryption"),
                .product(name: "ApplicationProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        // gRPC 1.x server (NO SLOWDOWN)
        .executableTarget(
            name: "HEServerV1",
            dependencies: [
                "SharedV1",
                .product(name: "HomomorphicEncryption", package: "swift-homomorphic-encryption"),
                .product(name: "HomomorphicEncryptionProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "PrivateNearestNeighborSearch", package: "swift-homomorphic-encryption"),
                .product(name: "ApplicationProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
        // gRPC 1.x client
        .executableTarget(
            name: "HEClientV1",
            dependencies: [
                "SharedV1",
                .product(name: "HomomorphicEncryption", package: "swift-homomorphic-encryption"),
                .product(name: "HomomorphicEncryptionProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "PrivateNearestNeighborSearch", package: "swift-homomorphic-encryption"),
                .product(name: "ApplicationProtobuf", package: "swift-homomorphic-encryption"),
                .product(name: "GRPC", package: "grpc-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [
                .unsafeFlags(["-cross-module-optimization"], .when(configuration: .release)),
            ]),
    ])
