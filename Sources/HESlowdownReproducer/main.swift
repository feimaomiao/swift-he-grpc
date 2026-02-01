// HE Slowdown Reproducer
// ======================
// Standalone binary to reproduce the 44x gRPC-NIO executor slowdown
// Does NOT depend on WallyBackendLib - directly uses HE and gRPC libraries
//
// This demonstrates that HE computations running inside gRPC handlers
// experience significant performance degradation due to NIO executor interference.
//
// Expected results:
//   - Direct execution: ~55ms
//   - gRPC handler execution: ~2300ms (44x slower)

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
import SwiftProtobuf

// MARK: - Main Entry Point

@main
struct HESlowdownReproducer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "HESlowdownReproducer",
        abstract: "Reproduces the 44x gRPC-NIO executor slowdown for HE computations",
        discussion: """
            This tool demonstrates that Homomorphic Encryption computations
            experience a ~44x performance degradation when executed within
            gRPC-Swift 2.x handler contexts due to NIO executor interference.

            The benchmark:
            1. Loads a PNNS cluster database (.binpb file)
            2. Generates test encrypted queries and evaluation keys
            3. Times HE computation directly (baseline)
            4. Times the same computation inside a gRPC handler
            5. Reports the slowdown factor
            """)

    @Argument(help: "Path to a cluster .binpb file")
    var databasePath: String

    @Option(name: .shortAndLong, help: "Number of benchmark iterations")
    var iterations: Int = 5

    @Option(name: .shortAndLong, help: "gRPC server port")
    var port: Int = 50099

    @Flag(name: .long, help: "Use BFV with UInt32 instead of UInt64")
    var bfv32: Bool = false

    func run() async throws {
        print("HE Slowdown Reproducer")
        print("======================")
        print("Database: \(databasePath)")
        print("Iterations: \(iterations)")
        print("Scheme: \(bfv32 ? "Bfv<UInt32>" : "Bfv<UInt64>")")
        print()

        // Verify database exists
        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw ReproducerError.databaseNotFound(databasePath)
        }

        if bfv32 {
            try await runBenchmark(Bfv<UInt32>.self)
        } else {
            try await runBenchmark(Bfv<UInt64>.self)
        }
    }

    func runBenchmark<Scheme: HeScheme>(_: Scheme.Type) async throws {
        // Load database
        print("Loading HE server from database...")
        let protoDatabase = try Apple_SwiftHomomorphicEncryption_Pnns_V1_SerializedProcessedDatabase(
            from: databasePath)
        let serialized: SerializedProcessedDatabase<Scheme> = try protoDatabase.native()
        let database = try ProcessedDatabase(from: serialized)
        let pnnsServer = try Server<Scheme>(database: database)

        print("✓ Server loaded")
        print("  Contexts: \(pnnsServer.contexts.count)")
        print("  Vector dimension: \(pnnsServer.config.vectorDimension)")
        print()

        // Generate test data using the server's configuration
        print("Generating test query and evaluation key...")
        let testData = try generateTestData(server: pnnsServer)
        print("✓ Test data generated")
        print("  Query matrices: \(testData.query.ciphertextMatrices.count)")
        print("  Serialized query size: \(testData.serializedQuery.reduce(0) { $0 + $1.count }) bytes")
        print("  Serialized eval key size: \(testData.serializedEvalKey.count) bytes")
        print()

        // Warm-up run
        print("Warm-up run...")
        _ = try await pnnsServer.computeResponse(to: testData.query, using: testData.evalKey)
        print("✓ Warm-up complete")
        print()

        // BENCHMARK 1: Direct execution (baseline)
        print("=== BENCHMARK 1: Direct Execution (Baseline) ===")
        var directTimes: [Double] = []

        for i in 1...iterations {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await pnnsServer.computeResponse(to: testData.query, using: testData.evalKey)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            directTimes.append(elapsed)
            print("  Iteration \(i): \(String(format: "%.2f", elapsed))ms")
        }

        let directStats = Statistics(times: directTimes)
        print("  Average: \(String(format: "%.2f", directStats.average))ms")
        print("  Min/Max: \(String(format: "%.2f", directStats.min))ms / \(String(format: "%.2f", directStats.max))ms")
        print("  Std Dev: \(String(format: "%.2f", directStats.stdDev))ms")
        print()

        // BENCHMARK 2: gRPC handler execution
        print("=== BENCHMARK 2: gRPC Handler Context ===")
        let grpcTimes = try await benchmarkViaGRPC(
            pnnsServer: pnnsServer,
            testData: testData)

        let grpcStats = Statistics(times: grpcTimes)
        print("  Average: \(String(format: "%.2f", grpcStats.average))ms")
        print("  Min/Max: \(String(format: "%.2f", grpcStats.min))ms / \(String(format: "%.2f", grpcStats.max))ms")
        print("  Std Dev: \(String(format: "%.2f", grpcStats.stdDev))ms")
        print()

        // Report results
        let slowdown = grpcStats.average / directStats.average
        print("=== RESULTS ===")
        print("Direct execution average:  \(String(format: "%.2f", directStats.average))ms")
        print("gRPC handler average:      \(String(format: "%.2f", grpcStats.average))ms")
        print("Slowdown factor:           \(String(format: "%.1f", slowdown))x")
        print()

        if slowdown > 10 {
            print("⚠️  SLOWDOWN REPRODUCED!")
            print("    gRPC-NIO executor causes \(String(format: "%.0f", slowdown))x performance degradation")
            print("    for CPU-bound HE computations.")
        } else if slowdown > 2 {
            print("⚠️  Moderate slowdown detected (\(String(format: "%.1f", slowdown))x)")
        } else {
            print("✓ No significant slowdown detected")
            print("  (This may indicate the issue has been fixed or the test environment differs)")
        }
    }

    func generateTestData<Scheme: HeScheme>(
        server: Server<Scheme>) throws -> TestData<Scheme>
    {
        // Create client using the server's config and contexts
        let client = try Client<Scheme>(config: server.clientConfig, contexts: server.contexts)

        // Generate secret key from client
        let secretKey = try client.generateSecretKey()

        // Generate evaluation key
        let evalKey = try client.generateEvaluationKey(using: secretKey)

        // Create a test query vector
        let vectorDim = server.config.vectorDimension
        let queryVector = (0..<vectorDim).map { Float($0) / Float(vectorDim) }
        let queryVectors = Array2d(data: [queryVector])

        // Generate encrypted query
        let query = try client.generateQuery(for: queryVectors, using: secretKey)

        // Serialize for gRPC transport
        let serializedQuery = try query.ciphertextMatrices.map { matrix in
            let proto = try matrix.serialize().proto()
            return try proto.serializedData()
        }

        let evalKeyProto = try evalKey.serialize().proto()
        let serializedEvalKey = try evalKeyProto.serializedData()

        return TestData(
            query: query,
            evalKey: evalKey,
            serializedQuery: serializedQuery,
            serializedEvalKey: serializedEvalKey)
    }

    func benchmarkViaGRPC<Scheme: HeScheme>(
        pnnsServer: Server<Scheme>,
        testData: TestData<Scheme>) async throws -> [Double]
    {
        print("Starting gRPC server on port \(port)...")

        // Configure transport with larger payload size for HE ciphertexts
        let serverConfig = HTTP2ServerTransport.Posix.Config.defaults { config in
            config.http2.maxFrameSize = 16 * 1024 * 1024 // 16MB max frame size
            config.rpc.maxRequestPayloadSize = .max
        }

        // Create gRPC transport
        let transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: "127.0.0.1", port: port),
            transportSecurity: .plaintext,
            config: serverConfig)

        // Create service handler - captures the PNNS server
        let serviceHandler = HEBenchmarkServiceHandler(pnnsServer: pnnsServer)

        let grpcServer = GRPCServer(
            transport: transport,
            services: [serviceHandler])

        // Start server
        let serverTask = Task {
            try await grpcServer.serve()
        }

        // Wait for server to be ready
        try await Task.sleep(for: .milliseconds(200))
        print("✓ gRPC server started")

        // Configure client transport with larger payload size
        let clientConfig = HTTP2ClientTransport.Posix.Config.defaults { config in
            config.http2.maxFrameSize = 16 * 1024 * 1024 // 16MB max frame size
        }

        // Configure service config with unlimited message size
        var serviceConfig = ServiceConfig()
        serviceConfig.methodConfig = [
            .init(
                names: [.init(service: "benchmark.HEBenchmark")],
                maxRequestMessageBytes: .max,
                maxResponseMessageBytes: .max),
        ]

        // Create client
        let clientTransport = try HTTP2ClientTransport.Posix(
            target: .ipv4(address: "127.0.0.1", port: port),
            transportSecurity: .plaintext,
            config: clientConfig,
            serviceConfig: serviceConfig)

        let grpcClient = GRPCClient(transport: clientTransport)

        // Start client connections task
        async let _ = grpcClient.runConnections()

        try await Task.sleep(for: .milliseconds(100))
        print("✓ gRPC client connected")
        print()

        // Run benchmark iterations
        var times: [Double] = []

        for i in 1...iterations {
            let computeTime = try await invokeGRPC(
                client: grpcClient,
                serializedQuery: testData.serializedQuery,
                serializedEvalKey: testData.serializedEvalKey)

            times.append(computeTime)
            print("  Iteration \(i): \(String(format: "%.2f", computeTime))ms")
        }

        // Cleanup
        grpcClient.beginGracefulShutdown()
        grpcServer.beginGracefulShutdown()
        serverTask.cancel()

        // Wait for cleanup
        try await Task.sleep(for: .milliseconds(100))

        return times
    }

    func invokeGRPC(
        client: GRPCClient<HTTP2ClientTransport.Posix>,
        serializedQuery: [Data],
        serializedEvalKey: Data) async throws -> Double
    {
        var request = BenchmarkRequest()
        request.encryptedQuery = serializedQuery
        request.evaluationKey = serializedEvalKey

        let response = try await client.unary(
            request: ClientRequest(message: request),
            descriptor: MethodDescriptor(
                fullyQualifiedService: "benchmark.HEBenchmark",
                method: "Compute"),
            serializer: ProtobufSerializer<BenchmarkRequest>(),
            deserializer: ProtobufDeserializer<BenchmarkResponse>(),
            options: .defaults)
        { response in
            try response.message
        }

        return response.computeTimeMs
    }
}

// MARK: - gRPC Service Handler

/// gRPC service that performs HE computation inside the NIO executor context
final class HEBenchmarkServiceHandler<Scheme: HeScheme>: RegistrableRPCService, Sendable {
    let pnnsServer: Server<Scheme>

    init(pnnsServer: Server<Scheme>) {
        self.pnnsServer = pnnsServer
    }

    static var serviceDescriptor: ServiceDescriptor {
        ServiceDescriptor(fullyQualifiedService: "benchmark.HEBenchmark")
    }

    func registerMethods(with router: inout RPCRouter<some ServerTransport>) {
        router.registerHandler(
            forMethod: MethodDescriptor(
                fullyQualifiedService: "benchmark.HEBenchmark",
                method: "Compute"),
            deserializer: ProtobufDeserializer<BenchmarkRequest>(),
            serializer: ProtobufSerializer<BenchmarkResponse>())
        { [pnnsServer] request, _ in
            // === THIS RUNS INSIDE THE gRPC-NIO EXECUTOR CONTEXT ===
            // The HE computation here will be ~44x slower than direct execution

            // Consume the single message (unary pattern)
            var requestMessage: BenchmarkRequest?
            for try await message in request.messages {
                requestMessage = message
            }
            guard let requestMessage else {
                throw RPCError(code: .invalidArgument, message: "No request message received")
            }

            let contexts = pnnsServer.contexts

            // Deserialize query matrices
            let queryMatrices = try requestMessage.encryptedQuery.map { data in
                try Apple_SwiftHomomorphicEncryption_Pnns_V1_SerializedCiphertextMatrix(
                    serializedBytes: data)
            }

            let ciphertextMatrices: [CiphertextMatrix<Scheme, Coeff>] = try zip(queryMatrices, contexts)
                .map { matrix, ctx in
                    let native: SerializedCiphertextMatrix<Scheme.Scalar> = try matrix.native()
                    return try CiphertextMatrix(deserialize: native, context: ctx)
                }
            let query = Query(ciphertextMatrices: ciphertextMatrices)

            // Deserialize evaluation key
            let protoEvalKey = try Apple_SwiftHomomorphicEncryption_V1_SerializedEvaluationKey(
                serializedBytes: requestMessage.evaluationKey)
            let evalKey: EvaluationKey<Scheme> = try protoEvalKey.native(context: contexts[0])

            // *** THE CRITICAL COMPUTATION ***
            // This call to computeResponse is what gets slowed down by the NIO executor
            let computeStart = CFAbsoluteTimeGetCurrent()
            let pnnsResponse = try await pnnsServer.computeResponse(to: query, using: evalKey)
            let computeTimeMs = (CFAbsoluteTimeGetCurrent() - computeStart) * 1000

            // Serialize response
            let protoResponse = try pnnsResponse.proto()
            let responseData = try protoResponse.serializedData()

            var response = BenchmarkResponse()
            response.responseData = responseData
            response.computeTimeMs = computeTimeMs

            return StreamingServerResponse(single: ServerResponse(message: response, metadata: [:]))
        }
    }
}

// MARK: - Protobuf Messages

/// Request message for benchmark RPC
struct BenchmarkRequest: Message, Hashable, Sendable {
    static let protoMessageName = "BenchmarkRequest"

    var encryptedQuery: [Data] = []
    var evaluationKey: Data = .init()
    var unknownFields = UnknownStorage()

    mutating func decodeMessage(decoder: inout some Decoder) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeRepeatedBytesField(value: &encryptedQuery)
            case 2: try decoder.decodeSingularBytesField(value: &evaluationKey)
            default: break
            }
        }
    }

    func traverse(visitor: inout some Visitor) throws {
        if !encryptedQuery.isEmpty {
            try visitor.visitRepeatedBytesField(value: encryptedQuery, fieldNumber: 1)
        }
        if !evaluationKey.isEmpty {
            try visitor.visitSingularBytesField(value: evaluationKey, fieldNumber: 2)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any Message) -> Bool {
        guard let other = message as? Self else { return false }
        return encryptedQuery == other.encryptedQuery && evaluationKey == other.evaluationKey
    }
}

/// Response message for benchmark RPC
struct BenchmarkResponse: Message, Hashable, Sendable {
    static let protoMessageName = "BenchmarkResponse"

    var responseData: Data = .init()
    var computeTimeMs: Double = 0
    var unknownFields = UnknownStorage()

    mutating func decodeMessage(decoder: inout some Decoder) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularBytesField(value: &responseData)
            case 2: try decoder.decodeSingularDoubleField(value: &computeTimeMs)
            default: break
            }
        }
    }

    func traverse(visitor: inout some Visitor) throws {
        if !responseData.isEmpty {
            try visitor.visitSingularBytesField(value: responseData, fieldNumber: 1)
        }
        if computeTimeMs != 0 {
            try visitor.visitSingularDoubleField(value: computeTimeMs, fieldNumber: 2)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    func isEqualTo(message: any Message) -> Bool {
        guard let other = message as? Self else { return false }
        return responseData == other.responseData && computeTimeMs == other.computeTimeMs
    }
}

// MARK: - Supporting Types

struct TestData<Scheme: HeScheme>: Sendable {
    let query: Query<Scheme>
    let evalKey: EvaluationKey<Scheme>
    let serializedQuery: [Data]
    let serializedEvalKey: Data
}

struct Statistics {
    let times: [Double]

    var average: Double {
        times.reduce(0, +) / Double(times.count)
    }

    var min: Double {
        times.min() ?? 0
    }

    var max: Double {
        times.max() ?? 0
    }

    var stdDev: Double {
        let avg = average
        let variance = times.reduce(0) { $0 + ($1 - avg) * ($1 - avg) } / Double(times.count)
        return sqrt(variance)
    }
}

enum ReproducerError: Error, CustomStringConvertible {
    case databaseNotFound(String)
    case noContexts

    var description: String {
        switch self {
        case let .databaseNotFound(path):
            "Database file not found: \(path)"
        case .noContexts:
            "No HE contexts available in database"
        }
    }
}
