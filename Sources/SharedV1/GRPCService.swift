// Shared gRPC 1.x Service Definitions
// Used by HEServerV1 and HEClientV1 for comparison (NO SLOWDOWN)

import ApplicationProtobuf
import CoreFoundation
import Foundation
import GRPC
import HomomorphicEncryption
import HomomorphicEncryptionProtobuf
import NIOCore
import NIOPosix
import PrivateNearestNeighborSearch
import SwiftProtobuf

// Type alias to avoid conflict with GRPC.Server
public typealias PNNSServer = PrivateNearestNeighborSearch.Server

// MARK: - Service Constants

public let heServiceName = "benchmark.HEBenchmark"
public let computeMethodPath = "/benchmark.HEBenchmark/Compute"

// MARK: - Protobuf Messages (same wire format as v2)

public struct BenchmarkRequest: Message, Sendable {
    public static let protoMessageName = "benchmark.BenchmarkRequest"

    public var encryptedQuery: [Data] = []
    public var evaluationKey: Data = .init()
    public var unknownFields = UnknownStorage()

    public init() {}

    public mutating func decodeMessage(decoder: inout some Decoder) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeRepeatedBytesField(value: &encryptedQuery)
            case 2: try decoder.decodeSingularBytesField(value: &evaluationKey)
            default: break
            }
        }
    }

    public func traverse(visitor: inout some Visitor) throws {
        if !encryptedQuery.isEmpty {
            try visitor.visitRepeatedBytesField(value: encryptedQuery, fieldNumber: 1)
        }
        if !evaluationKey.isEmpty {
            try visitor.visitSingularBytesField(value: evaluationKey, fieldNumber: 2)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    public func isEqualTo(message: any Message) -> Bool {
        guard let other = message as? Self else { return false }
        return encryptedQuery == other.encryptedQuery && evaluationKey == other.evaluationKey
    }
}

public struct BenchmarkResponse: Message, Sendable {
    public static let protoMessageName = "benchmark.BenchmarkResponse"

    public var responseData: Data = .init()
    public var computeTimeMs: Double = 0
    public var unknownFields = UnknownStorage()

    public init() {}

    public mutating func decodeMessage(decoder: inout some Decoder) throws {
        while let fieldNumber = try decoder.nextFieldNumber() {
            switch fieldNumber {
            case 1: try decoder.decodeSingularBytesField(value: &responseData)
            case 2: try decoder.decodeSingularDoubleField(value: &computeTimeMs)
            default: break
            }
        }
    }

    public func traverse(visitor: inout some Visitor) throws {
        if !responseData.isEmpty {
            try visitor.visitSingularBytesField(value: responseData, fieldNumber: 1)
        }
        if computeTimeMs != 0 {
            try visitor.visitSingularDoubleField(value: computeTimeMs, fieldNumber: 2)
        }
        try unknownFields.traverse(visitor: &visitor)
    }

    public func isEqualTo(message: any Message) -> Bool {
        guard let other = message as? Self else { return false }
        return responseData == other.responseData && computeTimeMs == other.computeTimeMs
    }
}

// MARK: - gRPC 1.x Async Service Provider

/// gRPC 1.x async service provider - NO SLOWDOWN with this version
public final class HEBenchmarkProvider<Scheme: HeScheme>: CallHandlerProvider, Sendable {
    public let pnnsServer: PNNSServer<Scheme>

    public var serviceName: Substring { "benchmark.HEBenchmark" }

    public init(pnnsServer: PNNSServer<Scheme>) {
        self.pnnsServer = pnnsServer
    }

    public func handle(
        method name: Substring,
        context: CallHandlerContext) -> GRPCServerHandlerProtocol?
    {
        switch name {
        case "Compute":
            GRPCAsyncServerHandler(
                context: context,
                requestDeserializer: ProtobufDeserializer<BenchmarkRequest>(),
                responseSerializer: ProtobufSerializer<BenchmarkResponse>(),
                interceptors: [],
                wrapping: { [pnnsServer] request, _ in
                    try await Self.compute(request: request, pnnsServer: pnnsServer)
                })
        default:
            nil
        }
    }

    private static func compute(
        request: BenchmarkRequest,
        pnnsServer: PNNSServer<Scheme>) async throws -> BenchmarkResponse
    {
        let contexts = pnnsServer.contexts

        // Deserialize query matrices
        let queryMatrices = try request.encryptedQuery.map { data in
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
            serializedBytes: request.evaluationKey)
        let evalKey: EvaluationKey<Scheme> = try protoEvalKey.native(context: contexts[0])

        // *** THE CRITICAL COMPUTATION ***
        // In gRPC 1.x, this runs WITHOUT the problematic executor context
        let computeStart = CFAbsoluteTimeGetCurrent()
        let pnnsResponse = try await pnnsServer.computeResponse(to: query, using: evalKey)
        let computeTimeMs = (CFAbsoluteTimeGetCurrent() - computeStart) * 1000

        // Serialize response
        let protoResponse = try pnnsResponse.proto()
        let responseData = try protoResponse.serializedData()

        var response = BenchmarkResponse()
        response.responseData = responseData
        response.computeTimeMs = computeTimeMs
        return response
    }
}

// MARK: - Server Helper

public struct ServerConfigV1 {
    public let host: String
    public let port: Int

    public init(host: String = "127.0.0.1", port: Int = 50052) {
        self.host = host
        self.port = port
    }
}

/// Creates and runs a gRPC 1.x server
public func runServerV1(
    config: ServerConfigV1,
    provider: HEBenchmarkProvider<some HeScheme>,
    group: EventLoopGroup) async throws -> GRPC.Server
{
    let server = try await GRPC.Server.insecure(group: group)
        .withServiceProviders([provider])
        .withMaximumReceiveMessageLength(1024 * 1024 * 1024) // 1GB
        .bind(host: config.host, port: config.port)
        .get()

    return server
}

// MARK: - Client Helper

public struct ClientConfigV1 {
    public let host: String
    public let port: Int

    public init(host: String = "127.0.0.1", port: Int = 50052) {
        self.host = host
        self.port = port
    }
}

/// Creates a gRPC 1.x client channel
public func createClientChannelV1(
    config: ClientConfigV1,
    group: EventLoopGroup) throws -> GRPCChannel
{
    let channel = try GRPCChannelPool.with(
        target: .host(config.host, port: config.port),
        transportSecurity: .plaintext,
        eventLoopGroup: group)
    { config in
        config.maximumReceiveMessageLength = 1024 * 1024 * 1024 // 1GB
    }
    return channel
}

/// Invokes the Compute RPC via gRPC 1.x
public func invokeComputeV1(
    channel: GRPCChannel,
    encryptedQuery: [Data],
    evaluationKey: Data) async throws -> BenchmarkResponse
{
    var request = BenchmarkRequest()
    request.encryptedQuery = encryptedQuery
    request.evaluationKey = evaluationKey

    let call: UnaryCall<BenchmarkRequest, BenchmarkResponse> = channel.makeUnaryCall(
        path: computeMethodPath,
        request: request,
        callOptions: CallOptions())

    return try await call.response.get()
}
