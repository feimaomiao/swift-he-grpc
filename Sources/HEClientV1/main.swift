// HE gRPC 1.x Client
// ==================
// Client for HEServerV1 to demonstrate gRPC 1.x has NO slowdown.

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
struct HEClientV1Command: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "HEClientV1",
        abstract: "HE gRPC 1.x Client",
        discussion: """
            Client for testing HEServerV1 (gRPC 1.x).
            Should show normal HE compute times (~15-20ms for small databases).
            """)

    @Argument(help: "Path to processed database file (.binpb) for generating test data")
    var databasePath: String

    @Option(name: .long, help: "Server host")
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 50052

    @Option(name: .shortAndLong, help: "Number of requests to send")
    var requests: Int = 10

    @Flag(name: .long, help: "Use BFV with UInt32 instead of UInt64")
    var bfv32: Bool = false

    @Flag(name: .shortAndLong, help: "Show detailed output")
    var verbose: Bool = false

    func run() async throws {
        print("HE gRPC 1.x Client")
        print("==================")
        print("Database: \(databasePath)")
        print("Server: \(host):\(port)")
        print("Requests: \(requests)")
        print("Scheme: \(bfv32 ? "Bfv<UInt32>" : "Bfv<UInt64>")")
        print()

        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw ClientError.databaseNotFound(databasePath)
        }

        if bfv32 {
            try await runClient(Bfv<UInt32>.self)
        } else {
            try await runClient(Bfv<UInt64>.self)
        }
    }

    func runClient<Scheme: HeScheme>(_: Scheme.Type) async throws {
        // Load database for test data generation
        print("Loading database for test data generation...")
        let protoDatabase = try Apple_SwiftHomomorphicEncryption_Pnns_V1_SerializedProcessedDatabase(
            from: databasePath)
        let serialized: SerializedProcessedDatabase<Scheme> = try protoDatabase.native()
        let database = try ProcessedDatabase(from: serialized)
        let pnnsServer = try Server<Scheme>(database: database)

        // Generate test query and evaluation key
        print("Generating encrypted query and evaluation key...")
        let client = try Client<Scheme>(config: pnnsServer.clientConfig, contexts: pnnsServer.contexts)
        let secretKey = try client.generateSecretKey()
        let evalKey = try client.generateEvaluationKey(using: secretKey)

        let vectorDim = pnnsServer.config.vectorDimension
        let queryVector = (0..<vectorDim).map { Float($0) / Float(vectorDim) }
        let queryVectors = Array2d(data: [queryVector])
        let query = try client.generateQuery(for: queryVectors, using: secretKey)

        // Serialize query and eval key
        let serializedQuery: [Data] = try query.ciphertextMatrices.map { matrix in
            let proto = try matrix.serialize().proto()
            return try proto.serializedData()
        }
        let evalKeyProto = try evalKey.serialize().proto()
        let serializedEvalKey = try evalKeyProto.serializedData()

        let querySize = serializedQuery.reduce(0) { $0 + $1.count }
        print("Test data ready:")
        print("  Query size: \(querySize) bytes")
        print("  EvalKey size: \(serializedEvalKey.count) bytes")
        print()

        // Create event loop group and channel
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        print("Connecting to server...")
        let config = ClientConfigV1(host: host, port: port)
        let channel = try createClientChannelV1(config: config, group: group)

        print("Connected to \(host):\(port)")
        print()

        // Send requests
        print("Sending \(requests) requests...")
        var heTimes: [Double] = []
        var totalTimes: [Double] = []

        for i in 1...requests {
            let totalStart = CFAbsoluteTimeGetCurrent()

            let response = try await invokeComputeV1(
                channel: channel,
                encryptedQuery: serializedQuery,
                evaluationKey: serializedEvalKey)

            let totalTime = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000
            let heTime = response.computeTimeMs

            heTimes.append(heTime)
            totalTimes.append(totalTime)

            if verbose {
                print(
                    "  Request \(i): HE=\(String(format: "%.2f", heTime))ms, total=\(String(format: "%.2f", totalTime))ms")
            }
        }

        // Statistics
        let heAvg = heTimes.reduce(0, +) / Double(heTimes.count)
        let heMin = heTimes.min() ?? 0
        let heMax = heTimes.max() ?? 0
        let totalAvg = totalTimes.reduce(0, +) / Double(totalTimes.count)

        print()
        print("=== Results (gRPC 1.x - NO SLOWDOWN) ===")
        print("HE Compute Time (server-side):")
        print("  Average: \(String(format: "%.2f", heAvg))ms")
        print("  Min/Max: \(String(format: "%.2f", heMin))ms / \(String(format: "%.2f", heMax))ms")
        print()
        print("Total Round-Trip Time:")
        print("  Average: \(String(format: "%.2f", totalAvg))ms")
        print()
        print("Note: If HE compute time is ~500ms instead of ~6ms,")
        print("this confirms the NIO executor slowdown affects gRPC 1.x too.")

        // Cleanup
        try await channel.close().get()
        try await group.shutdownGracefully()
    }
}

enum ClientError: Error, CustomStringConvertible {
    case databaseNotFound(String)

    var description: String {
        switch self {
        case let .databaseNotFound(path):
            "Database file not found: \(path)"
        }
    }
}
