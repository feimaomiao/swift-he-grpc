// Native HE Benchmark
// ====================
// Runs HE computations directly without gRPC to establish baseline performance.
// Compare with HEServer/HEClient to measure the gRPC 2.x slowdown.

import ApplicationProtobuf
import ArgumentParser
import CoreFoundation
import Foundation
import HomomorphicEncryption
import HomomorphicEncryptionProtobuf
import PrivateNearestNeighborSearch

@main
struct NativeBenchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "NativeBenchmark",
        abstract: "Native HE benchmark (no gRPC, baseline performance)",
        discussion: """
            This benchmark runs HE computations directly without gRPC overhead.
            Use this to establish baseline performance and compare with HEServer/HEClient.

            Expected: This should be 40-90x faster than gRPC 2.x results.
            """)

    @Argument(help: "Path to processed database file (.binpb)")
    var databasePath: String

    @Option(name: .shortAndLong, help: "Number of iterations")
    var iterations: Int = 10

    @Flag(name: .long, help: "Use BFV with UInt32 instead of UInt64")
    var bfv32: Bool = false

    @Flag(name: .shortAndLong, help: "Show detailed output")
    var verbose: Bool = false

    func run() async throws {
        print("Native HE Benchmark")
        print("===================")
        print("Database: \(databasePath)")
        print("Iterations: \(iterations)")
        print("Scheme: \(bfv32 ? "Bfv<UInt32>" : "Bfv<UInt64>")")
        print()

        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw BenchmarkError.databaseNotFound(databasePath)
        }

        if bfv32 {
            try await runBenchmark(Bfv<UInt32>.self)
        } else {
            try await runBenchmark(Bfv<UInt64>.self)
        }
    }

    func runBenchmark<Scheme: HeScheme>(_: Scheme.Type) async throws {
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

        // Generate test data
        print("Generating test query and evaluation key...")
        let client = try Client<Scheme>(config: pnnsServer.clientConfig, contexts: pnnsServer.contexts)
        let secretKey = try client.generateSecretKey()
        let evalKey = try client.generateEvaluationKey(using: secretKey)

        let vectorDim = pnnsServer.config.vectorDimension
        let queryVector = (0..<vectorDim).map { Float($0) / Float(vectorDim) }
        let queryVectors = Array2d(data: [queryVector])
        let query = try client.generateQuery(for: queryVectors, using: secretKey)
        print("Test data ready")
        print()

        // Warm-up
        print("Warm-up run...")
        _ = try await pnnsServer.computeResponse(to: query, using: evalKey)
        print()

        // Benchmark
        print("Running \(iterations) iterations...")
        var times: [Double] = []

        for i in 1...iterations {
            let start = CFAbsoluteTimeGetCurrent()
            let response = try await pnnsServer.computeResponse(to: query, using: evalKey)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            // Decrypt to prevent optimization
            _ = try client.decrypt(response: response, using: secretKey)

            times.append(elapsed)

            if verbose {
                print("  Iteration \(i): \(String(format: "%.2f", elapsed))ms")
            }
        }

        // Statistics
        let avg = times.reduce(0, +) / Double(times.count)
        let minTime = times.min() ?? 0
        let maxTime = times.max() ?? 0
        let variance = times.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(times.count)
        let stdDev = sqrt(variance)

        print()
        print("=== Results (Native Baseline) ===")
        print("Average: \(String(format: "%.2f", avg))ms")
        print("Min/Max: \(String(format: "%.2f", minTime))ms / \(String(format: "%.2f", maxTime))ms")
        print("Std Dev: \(String(format: "%.2f", stdDev))ms")
        print()
        print("This is the BASELINE performance without gRPC overhead.")
        print("gRPC 2.x server results should be ~40-90x slower than this.")
    }
}

enum BenchmarkError: Error, CustomStringConvertible {
    case databaseNotFound(String)

    var description: String {
        switch self {
        case let .databaseNotFound(path):
            "Database file not found: \(path)"
        }
    }
}
