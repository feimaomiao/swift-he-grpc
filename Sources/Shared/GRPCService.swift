// Shared gRPC Service Definitions
// Used by HEServer and HEClient for the real-world client/server scenario

import ApplicationProtobuf
import CoreFoundation
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import HomomorphicEncryption
import HomomorphicEncryptionProtobuf
import PrivateNearestNeighborSearch
import SwiftProtobuf

// MARK: - Service Constants

public let heServiceName = "benchmark.HEBenchmark"
public let computeMethodName = "Compute"

// MARK: - Protobuf Message Type Aliases

// Using protoc-generated types from he_benchmark.proto

public typealias HEComputeRequest = Benchmark_BenchmarkRequest
public typealias HEComputeResponse = Benchmark_BenchmarkResponse

// MARK: - gRPC Service Handler

/// gRPC service that performs HE computation inside the NIO executor context
/// This demonstrates the slowdown in a real server scenario
public final class HEComputeServiceHandler<Scheme: HeScheme>: RegistrableRPCService, Sendable {
    public let pnnsServer: Server<Scheme>

    public init(pnnsServer: Server<Scheme>) {
        self.pnnsServer = pnnsServer
    }

    public static var serviceDescriptor: ServiceDescriptor {
        ServiceDescriptor(fullyQualifiedService: heServiceName)
    }

    public func registerMethods(with router: inout RPCRouter<some ServerTransport>) {
        router.registerHandler(
            forMethod: MethodDescriptor(
                fullyQualifiedService: heServiceName,
                method: computeMethodName),
            deserializer: ProtobufDeserializer<HEComputeRequest>(),
            serializer: ProtobufSerializer<HEComputeResponse>())
        { [pnnsServer] request, _ in
            // === THIS RUNS INSIDE THE gRPC-NIO EXECUTOR CONTEXT ===
            // The HE computation here will be ~40-90x slower than direct execution

            // Consume the single message (unary pattern)
            var requestMessage: HEComputeRequest?
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

            var response = HEComputeResponse()
            response.responseData = responseData
            response.computeTimeMs = computeTimeMs
            return StreamingServerResponse(single: ServerResponse(message: response, metadata: [:]))
        }
    }
}

// MARK: - Server Helper

public struct ServerConfig {
    public let host: String
    public let port: Int

    public init(host: String = "127.0.0.1", port: Int = 50051) {
        self.host = host
        self.port = port
    }
}

/// Creates a configured gRPC server
public func createServer(
    config: ServerConfig,
    serviceHandler: HEComputeServiceHandler<some HeScheme>) -> GRPCServer<HTTP2ServerTransport.Posix>
{
    let serverConfig = HTTP2ServerTransport.Posix.Config.defaults { config in
        config.http2.maxFrameSize = 16 * 1024 * 1024
        config.rpc.maxRequestPayloadSize = .max
    }

    let transport = HTTP2ServerTransport.Posix(
        address: .ipv4(host: config.host, port: config.port),
        transportSecurity: .plaintext,
        config: serverConfig)

    return GRPCServer(transport: transport, services: [serviceHandler])
}

// MARK: - Client Helper

public struct ClientConfig {
    public let host: String
    public let port: Int

    public init(host: String = "127.0.0.1", port: Int = 50051) {
        self.host = host
        self.port = port
    }
}

/// Creates a configured gRPC client
public func createClient(config: ClientConfig) throws -> GRPCClient<HTTP2ClientTransport.Posix> {
    let clientConfig = HTTP2ClientTransport.Posix.Config.defaults { config in
        config.http2.maxFrameSize = 16 * 1024 * 1024
    }

    var serviceConfig = ServiceConfig()
    serviceConfig.methodConfig = [
        .init(
            names: [.init(service: heServiceName)],
            maxRequestMessageBytes: .max,
            maxResponseMessageBytes: .max),
    ]

    let clientTransport = try HTTP2ClientTransport.Posix(
        target: .ipv4(address: config.host, port: config.port),
        transportSecurity: .plaintext,
        config: clientConfig,
        serviceConfig: serviceConfig)

    return GRPCClient(transport: clientTransport)
}

/// Invokes the Compute RPC
public func invokeCompute(
    client: GRPCClient<HTTP2ClientTransport.Posix>,
    encryptedQuery: [Data],
    evaluationKey: Data) async throws -> HEComputeResponse
{
    var request = HEComputeRequest()
    request.encryptedQuery = encryptedQuery
    request.evaluationKey = evaluationKey

    return try await client.unary(
        request: ClientRequest(message: request),
        descriptor: MethodDescriptor(
            fullyQualifiedService: heServiceName,
            method: computeMethodName),
        serializer: ProtobufSerializer<HEComputeRequest>(),
        deserializer: ProtobufDeserializer<HEComputeResponse>(),
        options: .defaults)
    { response in
        try response.message
    }
}
