// HE REST Server
// ===============
// This server uses plain NIO HTTP (not gRPC) to demonstrate that
// the slowdown is specific to gRPC 2.x, not NIO itself.

import ApplicationProtobuf
import ArgumentParser
import CoreFoundation
import Dispatch
import Foundation
import HomomorphicEncryption
import HomomorphicEncryptionProtobuf
import NIOCore
import NIOHTTP1
import NIOPosix
import PrivateNearestNeighborSearch

// Type alias to avoid conflict with any Server type
typealias PNNSServer = PrivateNearestNeighborSearch.Server

@main
struct RESTServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "RESTServer",
        abstract: "HE REST Server (plain NIO HTTP, no gRPC)",
        discussion: """
            This server uses plain NIO HTTP to demonstrate that the slowdown
            is specific to gRPC 2.x, not NIO itself.

            Expected: HE computations run at native speed.
            """)

    @Argument(help: "Path to processed database file (.binpb)")
    var databasePath: String

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 8080

    @Option(name: .long, help: "Host to bind to")
    var host: String = "127.0.0.1"

    func run() async throws {
        print("HE REST Server (plain NIO HTTP)")
        print("================================")
        print("Database: \(databasePath)")
        print("Listening on: http://\(host):\(port)")
        print()

        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw ServerError.databaseNotFound(databasePath)
        }

        try await runServer(Bfv<UInt64>.self)
    }

    func runServer<Scheme: HeScheme>(_: Scheme.Type) async throws {
        // Load database
        print("Loading database...")
        let loadStart = CFAbsoluteTimeGetCurrent()
        let protoDatabase = try Apple_SwiftHomomorphicEncryption_Pnns_V1_SerializedProcessedDatabase(
            from: databasePath)
        let serialized: SerializedProcessedDatabase<Scheme> = try protoDatabase.native()
        let database = try ProcessedDatabase(from: serialized)
        let pnnsServer = try PNNSServer<Scheme>(database: database)
        let loadTime = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000

        print("Database loaded in \(String(format: "%.0f", loadTime))ms")
        print("  Contexts: \(pnnsServer.contexts.count)")
        print("  Vector dimension: \(pnnsServer.config.vectorDimension)")
        print()

        // Create event loop group
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)

        // Create server bootstrap
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HEHTTPHandler(pnnsServer: pnnsServer))
                }
            }
            .childChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.maxMessagesPerRead, value: 1)

        let channel = try await bootstrap.bind(host: host, port: port).get()

        print("REST server started on http://\(host):\(channel.localAddress?.port ?? port)/compute")
        print("Press Ctrl+C to stop")
        print()

        try await channel.closeFuture.get()
        try await group.shutdownGracefully()
    }
}

// MARK: - HTTP Handler

final class HEHTTPHandler<Scheme: HeScheme>: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let pnnsServer: PNNSServer<Scheme>
    var requestBody = Data()
    var requestHead: HTTPRequestHead?

    init(pnnsServer: PNNSServer<Scheme>) {
        self.pnnsServer = pnnsServer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)

        switch reqPart {
        case let .head(head):
            requestHead = head
            requestBody = Data()

        case var .body(buffer):
            if let bytes = buffer.readBytes(length: buffer.readableBytes) {
                requestBody.append(contentsOf: bytes)
            }

        case .end:
            guard let head = requestHead else { return }

            if head.method == .POST, head.uri == "/compute" {
                handleCompute(context: context, body: requestBody)
            } else {
                sendResponse(context: context, status: .notFound, body: "Not Found")
            }
        }
    }

    private func handleCompute(context: ChannelHandlerContext, body: Data) {
        let pnnsServer = pnnsServer
        let channel = context.channel

        // Process in a detached task to avoid NIO executor inheritance
        let promise = context.eventLoop.makePromise(of: Data.self)

        // Use DispatchQueue to run computation completely outside NIO context
        DispatchQueue.global(qos: .userInitiated).async {
            // Create a new task on a fresh executor
            let semaphore = DispatchSemaphore(value: 0)
            var result: Result<Data, Error>?

            Task.detached {
                do {
                    let response = try await Self.processRequest(body: body, pnnsServer: pnnsServer)
                    result = .success(response)
                } catch {
                    result = .failure(error)
                }
                semaphore.signal()
            }

            semaphore.wait()

            // Return result to NIO event loop
            channel.eventLoop.execute {
                guard let result else {
                    promise.fail(ServerError.computeFailed)
                    return
                }
                switch result {
                case let .success(response):
                    promise.succeed(response)
                case let .failure(error):
                    promise.fail(error)
                }
            }
        }

        promise.futureResult.whenComplete { result in
            channel.eventLoop.execute {
                switch result {
                case let .success(response):
                    self.sendResponseOnChannel(channel: channel, status: .ok, body: response)
                case let .failure(error):
                    self.sendResponseOnChannel(
                        channel: channel,
                        status: .internalServerError,
                        body: Data("Error: \(error)".utf8))
                }
            }
        }
    }

    private static func processRequest(body: Data, pnnsServer: PNNSServer<Scheme>) async throws -> Data {
        let contexts = pnnsServer.contexts

        // Parse request: first 4 bytes = query count, then [4-byte length + query data]..., then eval key
        var offset = 0

        // Read query count
        let queryCount = Int(body[offset..<offset + 4].withUnsafeBytes { $0.load(as: UInt32.self) })
        offset += 4

        // Read queries
        var queryMatrices: [Apple_SwiftHomomorphicEncryption_Pnns_V1_SerializedCiphertextMatrix] = []
        for _ in 0..<queryCount {
            let length = Int(body[offset..<offset + 4].withUnsafeBytes { $0.load(as: UInt32.self) })
            offset += 4
            let queryData = body[offset..<offset + length]
            offset += length
            let matrix = try Apple_SwiftHomomorphicEncryption_Pnns_V1_SerializedCiphertextMatrix(
                serializedBytes: queryData)
            queryMatrices.append(matrix)
        }

        // Read eval key (rest of the data)
        let evalKeyData = body[offset...]
        let protoEvalKey = try Apple_SwiftHomomorphicEncryption_V1_SerializedEvaluationKey(
            serializedBytes: evalKeyData)

        // Deserialize
        let ciphertextMatrices: [CiphertextMatrix<Scheme, Coeff>] = try zip(queryMatrices, contexts)
            .map { matrix, ctx in
                let native: SerializedCiphertextMatrix<Scheme.Scalar> = try matrix.native()
                return try CiphertextMatrix(deserialize: native, context: ctx)
            }
        let query = Query(ciphertextMatrices: ciphertextMatrices)
        let evalKey: EvaluationKey<Scheme> = try protoEvalKey.native(context: contexts[0])

        // *** THE CRITICAL COMPUTATION ***
        // In plain NIO HTTP, this runs WITHOUT the gRPC 2.x overhead
        let computeStart = CFAbsoluteTimeGetCurrent()
        let pnnsResponse = try await pnnsServer.computeResponse(to: query, using: evalKey)
        let computeTimeMs = (CFAbsoluteTimeGetCurrent() - computeStart) * 1000

        // Serialize response
        let protoResponse = try pnnsResponse.proto()
        let responseData = try protoResponse.serializedData()

        // Build response: 8-byte compute time + response data
        var result = Data()
        var timeMs = computeTimeMs
        result.append(Data(bytes: &timeMs, count: 8))
        result.append(responseData)

        return result
    }

    private func sendResponse(context: ChannelHandlerContext, status: HTTPResponseStatus, body: String) {
        let bodyData = Data(body.utf8)
        sendResponse(context: context, status: status, body: bodyData, contentType: "text/plain")
    }

    private func sendResponse(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        body: Data,
        contentType: String = "application/octet-stream")
    {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(body.count)")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)

        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }

    private func sendResponseOnChannel(
        channel: Channel,
        status: HTTPResponseStatus,
        body: Data,
        contentType: String = "application/octet-stream")
    {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(body.count)")

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)

        var buffer = channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)

        channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
    }
}

enum ServerError: Error, CustomStringConvertible {
    case computeFailed
    case databaseNotFound(String)

    var description: String {
        switch self {
        case .computeFailed:
            "HE computation failed"
        case let .databaseNotFound(path):
            "Database file not found: \(path)"
        }
    }
}
