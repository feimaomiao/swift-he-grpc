// HE gRPC Server with Process Isolation
// ======================================
// gRPC server that delegates HE computation to a separate worker process.
// This proves the slowdown is caused by NIO executor context.

import ArgumentParser
import CoreFoundation
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import Network
import Shared
import SwiftProtobuf

@main
struct HEServerIsolatedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "HEServerIsolated",
        abstract: "HE gRPC Server with process isolation",
        discussion: """
            This gRPC server delegates HE computation to a separate worker process.
            The worker runs WITHOUT NIO, so HE computations are fast (~6ms).

            Run HEWorker first:
              .build/release/HEWorker <database> --socket-path /tmp/he-worker.sock

            Then run this server:
              .build/release/HEServerIsolated --port 50055 --socket-path /tmp/he-worker.sock
            """)

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 50055

    @Option(name: .long, help: "Host to bind to")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "Worker Unix socket path")
    var socketPath: String = "/tmp/he-worker.sock"

    func run() async throws {
        print("HE gRPC Server (Process Isolated)")
        print("==================================")
        print("Listening on: \(host):\(port)")
        print("Worker socket: \(socketPath)")
        print()

        // Create worker client
        let workerClient = WorkerClient(socketPath: socketPath)

        // Create gRPC service handler
        let serviceHandler = IsolatedHEServiceHandler(workerClient: workerClient)

        // Configure gRPC server
        let serverConfig = HTTP2ServerTransport.Posix.Config.defaults { config in
            config.http2.maxFrameSize = 16 * 1024 * 1024
            config.rpc.maxRequestPayloadSize = .max
        }

        let transport = HTTP2ServerTransport.Posix(
            address: .ipv4(host: host, port: port),
            transportSecurity: .plaintext,
            config: serverConfig)

        let server = GRPCServer(transport: transport, services: [serviceHandler])

        print("gRPC server starting...")

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await server.serve()
            }

            print("gRPC server started on \(host):\(port)")
            print("Press Ctrl+C to stop")
            print()

            try await group.next()
        }
    }
}

// MARK: - Isolated Service Handler

final class IsolatedHEServiceHandler: RegistrableRPCService, Sendable {
    let workerClient: WorkerClient

    init(workerClient: WorkerClient) {
        self.workerClient = workerClient
    }

    static var serviceDescriptor: ServiceDescriptor {
        ServiceDescriptor(fullyQualifiedService: heServiceName)
    }

    func registerMethods(with router: inout RPCRouter<some ServerTransport>) {
        router.registerHandler(
            forMethod: MethodDescriptor(
                fullyQualifiedService: heServiceName,
                method: computeMethodName),
            deserializer: ProtobufDeserializer<HEComputeRequest>(),
            serializer: ProtobufSerializer<HEComputeResponse>())
        { [workerClient] request, _ in
            // Consume the request message
            var requestMessage: HEComputeRequest?
            for try await message in request.messages {
                requestMessage = message
            }
            guard let requestMessage else {
                throw RPCError(code: .invalidArgument, message: "No request message received")
            }

            // Build worker request (same format as REST)
            var workerRequest = Data()

            // Query count
            var queryCount = UInt32(requestMessage.encryptedQuery.count)
            workerRequest.append(Data(bytes: &queryCount, count: 4))

            // Each query: length + data
            for query in requestMessage.encryptedQuery {
                var length = UInt32(query.count)
                workerRequest.append(Data(bytes: &length, count: 4))
                workerRequest.append(query)
            }

            // Eval key
            workerRequest.append(requestMessage.evaluationKey)

            // Forward to worker process (HE computation happens there, outside NIO)
            let forwardStart = CFAbsoluteTimeGetCurrent()
            let workerResponse = try await workerClient.sendRequest(workerRequest)
            let totalTime = (CFAbsoluteTimeGetCurrent() - forwardStart) * 1000

            // Parse worker response: 8-byte compute time + response data
            let computeTimeMs = workerResponse[0..<8].withUnsafeBytes { $0.load(as: Double.self) }
            let responseData = workerResponse[8...]

            print(
                "  Worker HE: \(String(format: "%.2f", computeTimeMs))ms, IPC total: \(String(format: "%.2f", totalTime))ms")

            var response = HEComputeResponse()
            response.responseData = Data(responseData)
            response.computeTimeMs = computeTimeMs

            return StreamingServerResponse(single: ServerResponse(message: response, metadata: [:]))
        }
    }
}

// MARK: - Worker Client (Unix Socket)

final class WorkerClient: Sendable {
    let socketPath: String

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func sendRequest(_ data: Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            // Create connection to worker
            let endpoint = NWEndpoint.unix(path: socketPath)
            let connection = NWConnection(to: endpoint, using: .tcp)

            var responseData = Data()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // Send length-prefixed request
                    var length = UInt32(data.count)
                    var message = Data(bytes: &length, count: 4)
                    message.append(data)

                    connection.send(content: message, completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                            connection.cancel()
                            return
                        }

                        // Receive response
                        self.receiveResponse(connection: connection) { result in
                            switch result {
                            case let .success(data):
                                continuation.resume(returning: data)
                            case let .failure(error):
                                continuation.resume(throwing: error)
                            }
                            connection.cancel()
                        }
                    })

                case let .failed(error):
                    continuation.resume(throwing: error)

                default:
                    break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func receiveResponse(connection: NWConnection, completion: @escaping (Result<Data, Error>) -> Void) {
        // First receive 4-byte length
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { content, _, _, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let lengthData = content, lengthData.count == 4 else {
                completion(.failure(WorkerClientError.invalidResponse))
                return
            }

            let length = Int(lengthData.withUnsafeBytes { $0.load(as: UInt32.self) })

            // Receive full response
            self.receiveFullResponse(connection: connection, length: length, completion: completion)
        }
    }

    private func receiveFullResponse(
        connection: NWConnection,
        length: Int,
        completion: @escaping (Result<Data, Error>) -> Void)
    {
        var receivedData = Data()

        func receiveMore() {
            let remaining = length - receivedData.count
            connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { content, _, _, error in
                if let error {
                    completion(.failure(error))
                    return
                }

                if let data = content {
                    receivedData.append(data)
                }

                if receivedData.count >= length {
                    completion(.success(receivedData))
                } else {
                    receiveMore()
                }
            }
        }

        receiveMore()
    }
}

enum WorkerClientError: Error {
    case connectionFailed
    case invalidResponse
}
