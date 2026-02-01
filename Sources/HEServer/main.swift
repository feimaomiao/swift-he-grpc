// HE gRPC Server
// ===============
// Standalone gRPC server that demonstrates the NIO executor slowdown
// in a real-world deployment scenario.

import ApplicationProtobuf
import ArgumentParser
import CoreFoundation
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import HomomorphicEncryption
import HomomorphicEncryptionProtobuf
import PrivateNearestNeighborSearch
import Shared

@main
struct HEServer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "HEServer",
        abstract: "HE computation gRPC server (demonstrates gRPC 2.x slowdown)",
        discussion: """
            This server loads a PNNS database and serves HE computation requests.
            Due to gRPC-Swift 2.x's NIO executor, computations will be 40-90x slower
            than direct execution.

            Use with HEClient to measure real-world performance impact.
            """)

    @Argument(help: "Path to processed database file (.binpb)")
    var databasePath: String

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 50051

    @Option(name: .long, help: "Host to bind to")
    var host: String = "127.0.0.1"

    @Flag(name: .long, help: "Use BFV with UInt32 instead of UInt64")
    var bfv32: Bool = false

    func run() async throws {
        print("HE gRPC Server (gRPC-Swift 2.x)")
        print("===============================")
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
        print("  Database rows: \(database.entryIds.count)")
        print()

        // Create service handler
        let serviceHandler = HEComputeServiceHandler(pnnsServer: pnnsServer)

        // Create and start server
        let server = createServer(
            config: ServerConfig(host: host, port: port),
            serviceHandler: serviceHandler)

        print("WARNING: HE computations will be 40-90x slower due to gRPC 2.x NIO executor!")
        print()
        print("Server ready on \(host):\(port)")
        print("Press Ctrl+C to stop")
        print()

        // Run server (blocks until shutdown)
        try await server.serve()
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
