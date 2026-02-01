// HE gRPC 1.x Server
// ==================
// This server uses gRPC-swift 1.x which does NOT have the slowdown issue.
// Compare with HEServer (gRPC 2.x) to see the difference.

import ApplicationProtobuf
import ArgumentParser
import CoreFoundation
import Foundation
import GRPC
import HomomorphicEncryption
import HomomorphicEncryptionProtobuf
import NIOCore
import NIOPosix
import PrivateNearestNeighborSearch
import SharedV1

@main
struct HEServerV1Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "HEServerV1",
        abstract: "HE gRPC 1.x Server (NO SLOWDOWN)",
        discussion: """
            This server uses gRPC-swift 1.x which does NOT exhibit the slowdown.
            Use this to compare performance with HEServer (gRPC 2.x).

            Expected: HE computations run at native speed (~15-20ms for small databases).
            """)

    @Argument(help: "Path to processed database file (.binpb)")
    var databasePath: String

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 50052

    @Option(name: .long, help: "Host to bind to")
    var host: String = "127.0.0.1"

    @Flag(name: .long, help: "Use BFV with UInt32 instead of UInt64")
    var bfv32: Bool = false

    func run() async throws {
        print("HE gRPC 1.x Server (NO SLOWDOWN)")
        print("=================================")
        print("Database: \(databasePath)")
        print("Listening on: \(host):\(port)")
        print("Scheme: \(bfv32 ? "Bfv<UInt32>" : "Bfv<UInt64>")")
        print()

        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw ServerError.databaseNotFound(databasePath)
        }

        if bfv32 {
            try await runServer(Bfv<UInt32>.self)
        } else {
            try await runServer(Bfv<UInt64>.self)
        }
    }

    func runServer<Scheme: HeScheme>(_: Scheme.Type) async throws {
        // Load database
        print("Loading database...")
        let loadStart = CFAbsoluteTimeGetCurrent()
        let protoDatabase = try Apple_SwiftHomomorphicEncryption_Pnns_V1_SerializedProcessedDatabase(
            from: databasePath)
        let serialized: SerializedProcessedDatabase<Scheme> = try protoDatabase.native()
        let database = try ProcessedDatabase(from: serialized)
        let pnnsServer = try Server<Scheme>(database: database)
        let loadTime = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000

        print("Database loaded in \(String(format: "%.0f", loadTime))ms")
        print("  Contexts: \(pnnsServer.contexts.count)")
        print("  Vector dimension: \(pnnsServer.config.vectorDimension)")
        print()

        // Create event loop group
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        // Create service provider
        let provider = HEBenchmarkProvider(pnnsServer: pnnsServer)

        // Start server
        let config = ServerConfigV1(host: host, port: port)
        let server = try await runServerV1(config: config, provider: provider, group: group)

        print("gRPC 1.x server started on \(host):\(server.channel.localAddress?.port ?? port)")
        print("Press Ctrl+C to stop")
        print()

        // Wait for server to close
        try await server.onClose.get()

        // Shutdown group
        try await group.shutdownGracefully()
    }
}

enum ServerError: Error, CustomStringConvertible {
    case databaseNotFound(String)

    var description: String {
        switch self {
        case let .databaseNotFound(path):
            "Database file not found: \(path)"
        }
    }
}
