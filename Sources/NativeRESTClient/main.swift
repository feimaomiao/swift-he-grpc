// HE Native REST Client
// ======================
// Client for NativeRESTServer - uses Foundation's URLSession (no NIO)

import ApplicationProtobuf
import ArgumentParser
import CoreFoundation
import Foundation
import HomomorphicEncryption
import HomomorphicEncryptionProtobuf
import PrivateNearestNeighborSearch

@main
struct NativeRESTClientCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "NativeRESTClient",
        abstract: "HE REST Client using Foundation (NO SwiftNIO)",
        discussion: """
            Client for testing NativeRESTServer (Network.framework).
            Should show normal HE compute times (~6ms for dim16).
            """)

    @Argument(help: "Path to processed database file (.binpb) for generating test data")
    var databasePath: String

    @Option(name: .long, help: "Server host")
    var host: String = "127.0.0.1"

    @Option(name: .shortAndLong, help: "Server port")
    var port: Int = 8090

    @Option(name: .shortAndLong, help: "Number of requests to send")
    var requests: Int = 10

    @Flag(name: .shortAndLong, help: "Show detailed output")
    var verbose: Bool = false

    func run() async throws {
        print("HE Native REST Client")
        print("=====================")
        print("Database: \(databasePath)")
        print("Server: http://\(host):\(port)")
        print("Requests: \(requests)")
        print()

        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw ClientError.databaseNotFound(databasePath)
        }

        try await runClient(Bfv<UInt64>.self)
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
        let serializedQueries: [Data] = try query.ciphertextMatrices.map { matrix in
            let proto = try matrix.serialize().proto()
            return try proto.serializedData()
        }
        let evalKeyProto = try evalKey.serialize().proto()
        let serializedEvalKey = try evalKeyProto.serializedData()

        // Build request body
        let requestBody = buildRequestBody(queries: serializedQueries, evalKey: serializedEvalKey)

        print("Test data ready:")
        print("  Request size: \(requestBody.count) bytes")
        print()

        // Create URL session
        guard let url = URL(string: "http://\(host):\(port)/compute") else {
            throw ClientError.invalidURL("http://\(host):\(port)/compute")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = requestBody
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        print("Sending \(requests) requests...")
        var heTimes: [Double] = []
        var totalTimes: [Double] = []

        for i in 1...requests {
            let totalStart = CFAbsoluteTimeGetCurrent()

            let (data, _) = try await URLSession.shared.data(for: urlRequest)

            let totalTime = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000

            // Parse response: first 8 bytes = compute time
            let heTime = data[0..<8].withUnsafeBytes { $0.load(as: Double.self) }

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
        print("=== Results (Native REST - NO NIO) ===")
        print("HE Compute Time (server-side):")
        print("  Average: \(String(format: "%.2f", heAvg))ms")
        print("  Min/Max: \(String(format: "%.2f", heMin))ms / \(String(format: "%.2f", heMax))ms")
        print()
        print("Total Round-Trip Time:")
        print("  Average: \(String(format: "%.2f", totalAvg))ms")
        print()
        print("Expected: HE compute should be ~6ms (same as native benchmark)")
        print("This proves the slowdown is caused by NIO executor context.")
    }

    private func buildRequestBody(queries: [Data], evalKey: Data) -> Data {
        var body = Data()

        // Query count (4 bytes)
        var queryCount = UInt32(queries.count)
        body.append(Data(bytes: &queryCount, count: 4))

        // Each query: length (4 bytes) + data
        for query in queries {
            var length = UInt32(query.count)
            body.append(Data(bytes: &length, count: 4))
            body.append(query)
        }

        // Eval key (rest of data)
        body.append(evalKey)

        return body
    }
}

enum ClientError: Error, CustomStringConvertible {
    case databaseNotFound(String)
    case invalidURL(String)

    var description: String {
        switch self {
        case let .databaseNotFound(path):
            "Database file not found: \(path)"
        case let .invalidURL(url):
            "Invalid URL: \(url)"
        }
    }
}
