// HE Worker Process
// ==================
// Standalone process that performs HE computations WITHOUT SwiftNIO.
// Communicates via Unix socket with the gRPC server.
// This proves the slowdown is caused by NIO executor context.

import ApplicationProtobuf
import ArgumentParser
import CoreFoundation
import Foundation
import HomomorphicEncryption
import HomomorphicEncryptionProtobuf
import Network
import PrivateNearestNeighborSearch

@main
struct HEWorkerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "HEWorker",
        abstract: "HE computation worker process (NO SwiftNIO)",
        discussion: """
            This worker process performs HE computations outside of any NIO context.
            It communicates with the gRPC server via Unix socket.

            Expected: HE computations run at native speed (~6ms).
            """)

    @Argument(help: "Path to processed database file (.binpb)")
    var databasePath: String

    @Option(name: .long, help: "Unix socket path")
    var socketPath: String = "/tmp/he-worker.sock"

    func run() async throws {
        print("HE Worker Process (NO SwiftNIO)")
        print("================================")
        print("Database: \(databasePath)")
        print("Socket: \(socketPath)")
        print()

        guard FileManager.default.fileExists(atPath: databasePath) else {
            throw WorkerError.databaseNotFound(databasePath)
        }

        try await runWorker(Bfv<UInt64>.self)
    }

    func runWorker<Scheme: HeScheme>(_: Scheme.Type) async throws {
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
        print()

        // Remove existing socket
        try? FileManager.default.removeItem(atPath: socketPath)

        // Create Unix socket listener using Network.framework
        let worker = HEWorkerServer(pnnsServer: pnnsServer, socketPath: socketPath)
        try await worker.start()

        print("Worker listening on \(socketPath)")
        print("Press Ctrl+C to stop")
        print()

        // Keep running
        try await Task.sleep(for: .seconds(86400 * 365))
    }
}

// MARK: - Worker Server

final class HEWorkerServer<Scheme: HeScheme>: @unchecked Sendable {
    let pnnsServer: Server<Scheme>
    let socketPath: String
    var listener: NWListener?

    init(pnnsServer: Server<Scheme>, socketPath: String) {
        self.pnnsServer = pnnsServer
        self.socketPath = socketPath
    }

    func start() async throws {
        // Create Unix socket parameters
        let parameters = NWParameters()
        parameters.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        parameters.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        listener = try NWListener(using: parameters)

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Worker ready")
            case let .failed(error):
                print("Worker failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: .global(qos: .userInitiated))

        // Wait for listener to be ready
        try await Task.sleep(for: .milliseconds(100))
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                self.receiveRequest(connection)
            case let .failed(error):
                print("Connection failed: \(error)")
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .userInitiated))
    }

    private func receiveRequest(_ connection: NWConnection) {
        // First receive 4-byte length prefix
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, _, _, error in
            guard let self else { return }

            if let error {
                print("Receive error: \(error)")
                connection.cancel()
                return
            }

            guard let lengthData = content, lengthData.count == 4 else {
                connection.cancel()
                return
            }

            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self) }

            // Now receive the full message
            receiveFullMessage(connection, length: Int(length))
        }
    }

    private func receiveFullMessage(_ connection: NWConnection, length: Int) {
        var receivedData = Data()

        func receiveMore() {
            let remaining = length - receivedData.count
            connection
                .receive(minimumIncompleteLength: 1, maximumLength: remaining) { [weak self] content, _, _, error in
                    guard let self else { return }

                    if let error {
                        print("Receive error: \(error)")
                        connection.cancel()
                        return
                    }

                    if let data = content {
                        receivedData.append(data)
                    }

                    if receivedData.count >= length {
                        // Full message received, process it
                        processRequest(data: receivedData, connection: connection)
                    } else {
                        receiveMore()
                    }
                }
        }

        receiveMore()
    }

    private func processRequest(data: Data, connection: NWConnection) {
        Task {
            do {
                let response = try await self.computeHE(requestData: data)
                self.sendResponse(connection: connection, data: response)
            } catch {
                print("Compute error: \(error)")
                connection.cancel()
            }
        }
    }

    private func computeHE(requestData: Data) async throws -> Data {
        let contexts = pnnsServer.contexts

        // Parse request (same format as REST)
        var offset = 0

        // Read query count
        let queryCount = Int(requestData[offset..<offset + 4].withUnsafeBytes { $0.load(as: UInt32.self) })
        offset += 4

        // Read queries
        var queryMatrices: [Apple_SwiftHomomorphicEncryption_Pnns_V1_SerializedCiphertextMatrix] = []
        for _ in 0..<queryCount {
            let length = Int(requestData[offset..<offset + 4].withUnsafeBytes { $0.load(as: UInt32.self) })
            offset += 4
            let queryData = requestData[offset..<offset + length]
            offset += length
            let matrix = try Apple_SwiftHomomorphicEncryption_Pnns_V1_SerializedCiphertextMatrix(
                serializedBytes: queryData)
            queryMatrices.append(matrix)
        }

        // Read eval key
        let evalKeyData = requestData[offset...]
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
        // Running in worker process WITHOUT NIO - should be fast!
        let computeStart = CFAbsoluteTimeGetCurrent()
        let pnnsResponse = try await pnnsServer.computeResponse(to: query, using: evalKey)
        let computeTimeMs = (CFAbsoluteTimeGetCurrent() - computeStart) * 1000

        print("  HE compute: \(String(format: "%.2f", computeTimeMs))ms")

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

    private func sendResponse(connection: NWConnection, data: Data) {
        // Send length prefix + data
        var length = UInt32(data.count)
        var message = Data(bytes: &length, count: 4)
        message.append(data)

        connection.send(content: message, completion: .contentProcessed { error in
            if let error {
                print("Send error: \(error)")
            }
            // Ready for next request
            self.receiveRequest(connection)
        })
    }
}

enum WorkerError: Error, CustomStringConvertible {
    case databaseNotFound(String)

    var description: String {
        switch self {
        case let .databaseNotFound(path):
            "Database file not found: \(path)"
        }
    }
}
