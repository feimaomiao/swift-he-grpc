// HE gRPC Client
// ===============
// Standalone gRPC client that sends HE computation requests.
// Used with HEServer to demonstrate the slowdown in a real scenario.

import ApplicationProtobuf
import ArgumentParser
import CoreFoundation
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import HomomorphicEncryption
import HomomorphicEncryptionProtobuf
import PrivateNearestNeighborSearch
import Shared
import SwiftProtobuf

@main
struct HEClient: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "HEClient",
        abstract: "HE computation gRPC client",
        discussion: """
            This client connects to an HEServer and sends encrypted queries.
            It generates test data locally and measures round-trip timing.

            Use with HEServer to demonstrate the gRPC 2.x slowdown.
            """)

    @Argument(help: "Path to processed database file (.binpb) - must match server's database")
    var databasePath: String

    @Option(name: .shortAndLong, help: "Server host")
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 50051

    @Option(name: .shortAndLong, help: "Number of requests to send")
    var requests: Int = 5

    @Flag(name: .long, help: "Use BFV with UInt32 instead of UInt64")
    var bfv32: Bool = false

    @Flag(name: .shortAndLong, help: "Show detailed output")
    var verbose: Bool = false

    func run() async throws {
        print("HE gRPC Client")
        print("==============")
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
        // Load database to generate matching test data
        print("Loading database for test data generation...")
        let protoDatabase = try Apple_SwiftHomomorphicEncryption_Pnns_V1_SerializedProcessedDatabase(
            from: databasePath)
        let serialized: SerializedProcessedDatabase<Scheme> = try protoDatabase.native()
        let database = try ProcessedDatabase(from: serialized)
        let pnnsServer = try Server<Scheme>(database: database)

        // Generate test data
        print("Generating encrypted query and evaluation key...")
        let client = try Client<Scheme>(config: pnnsServer.clientConfig, contexts: pnnsServer.contexts)
        let secretKey = try client.generateSecretKey()
        let evalKey = try client.generateEvaluationKey(using: secretKey)

        let vectorDim = pnnsServer.config.vectorDimension
        let queryVector = (0..<vectorDim).map { Float($0) / Float(vectorDim) }
        let queryVectors = Array2d(data: [queryVector])
        let query = try client.generateQuery(for: queryVectors, using: secretKey)

        // Serialize for transport
        let serializedQuery = try query.ciphertextMatrices.map { matrix in
            let proto = try matrix.serialize().proto()
            return try proto.serializedData()
        }
        let evalKeyProto = try evalKey.serialize().proto()
        let serializedEvalKey = try evalKeyProto.serializedData()

        print("Test data ready:")
        print("  Query size: \(serializedQuery.reduce(0) { $0 + $1.count }) bytes")
        print("  EvalKey size: \(serializedEvalKey.count) bytes")
        print()

        // Connect to server
        print("Connecting to server...")
        let grpcClient = try createClient(config: ClientConfig(host: host, port: port))

        // Start client connections
        let connectionsTask = Task {
            try await grpcClient.runConnections()
        }

        try await Task.sleep(for: .milliseconds(200))
        print("Connected to \(host):\(port)")
        print()

        // Send requests
        print("Sending \(requests) requests...")
        var times: [Double] = []
        var totalTimes: [Double] = []

        for i in 1...requests {
            let totalStart = CFAbsoluteTimeGetCurrent()
            let response = try await invokeCompute(
                client: grpcClient,
                encryptedQuery: serializedQuery,
                evaluationKey: serializedEvalKey)
            let totalTime = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000

            times.append(response.computeTimeMs)
            totalTimes.append(totalTime)

            if verbose {
                print("  Request \(i): HE=\(String(format: "%.2f", response.computeTimeMs))ms, " +
                    "total=\(String(format: "%.2f", totalTime))ms")
            }
        }

        // Statistics
        let avgHE = times.reduce(0, +) / Double(times.count)
        let minHE = times.min() ?? 0
        let maxHE = times.max() ?? 0
        let avgTotal = totalTimes.reduce(0, +) / Double(totalTimes.count)

        print()
        print("=== Results ===")
        print("HE Compute Time (server-side):")
        print("  Average: \(String(format: "%.2f", avgHE))ms")
        print("  Min/Max: \(String(format: "%.2f", minHE))ms / \(String(format: "%.2f", maxHE))ms")
        print()
        print("Total Round-Trip Time:")
        print("  Average: \(String(format: "%.2f", avgTotal))ms")
        print()

        if avgHE > 100 {
            print("WARNING: HE compute time is abnormally high!")
            print("         This is the expected gRPC 2.x NIO executor slowdown.")
            print("         Direct execution would be ~40-90x faster.")
        }

        // Cleanup
        grpcClient.beginGracefulShutdown()
        connectionsTask.cancel()
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
