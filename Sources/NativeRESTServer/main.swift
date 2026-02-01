// HE Native REST Server
// ======================
// This server uses Apple's Network.framework (NO SwiftNIO) to demonstrate
// that direct execution without NIO has no slowdown.

import ApplicationProtobuf
import ArgumentParser
import CoreFoundation
import Foundation
import HomomorphicEncryption
import HomomorphicEncryptionProtobuf
import Network
import PrivateNearestNeighborSearch

@main
struct NativeRESTServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "NativeRESTServer",
        abstract: "HE REST Server using Network.framework (NO SwiftNIO)",
        discussion: """
            This server uses Apple's Network.framework instead of SwiftNIO.
            It should show NO slowdown - HE computations run at native speed.
            """)

    @Argument(help: "Path to processed database file (.binpb)")
    var databasePath: String

    @Option(name: .shortAndLong, help: "Port to listen on")
    var port: Int = 8090

    @Option(name: .long, help: "Host to bind to")
    var host: String = "127.0.0.1"

    func run() async throws {
        print("HE Native REST Server (Network.framework)")
        print("==========================================")
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
        let pnnsServer = try Server<Scheme>(database: database)
        let loadTime = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000

        print("Database loaded in \(String(format: "%.0f", loadTime))ms")
        print("  Contexts: \(pnnsServer.contexts.count)")
        print("  Vector dimension: \(pnnsServer.config.vectorDimension)")
        print()

        // Create HTTP server using Network.framework
        let server = NativeHTTPServer(pnnsServer: pnnsServer, port: UInt16(port))
        try await server.start()

        print("Native REST server started on http://\(host):\(port)/compute")
        print("Press Ctrl+C to stop")
        print()

        // Keep running
        try await Task.sleep(for: .seconds(86400 * 365))
    }
}

// MARK: - Native HTTP Server using Network.framework

final class NativeHTTPServer<Scheme: HeScheme>: @unchecked Sendable {
    let pnnsServer: Server<Scheme>
    let port: UInt16
    var listener: NWListener?

    init(pnnsServer: Server<Scheme>, port: UInt16) {
        self.pnnsServer = pnnsServer
        self.port = port
    }

    func start() async throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort(port)
        }
        listener = try NWListener(using: parameters, on: nwPort)
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Server ready on port \(self.port)")
            case let .failed(error):
                print("Server failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: .global(qos: .userInitiated))

        // Wait a bit for server to start
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
        var receivedData = Data()

        func receiveMore() {
            connection
                .receive(minimumIncompleteLength: 1,
                         maximumLength: 1024 * 1024)
                { [weak self] content, _, isComplete, error in
                    guard let self else { return }

                    if let error {
                        print("Receive error: \(error)")
                        connection.cancel()
                        return
                    }

                    if let data = content {
                        receivedData.append(data)
                    }

                    // Check if we have complete HTTP request
                    if let contentLength = extractContentLength(from: receivedData),
                       let headerEnd = findHeaderEnd(in: receivedData)
                    {
                        let expectedTotal = headerEnd + contentLength
                        if receivedData.count >= expectedTotal {
                            // Complete request received
                            processHTTPRequest(data: receivedData, connection: connection)
                            return
                        }
                    }

                    if isComplete {
                        // Connection closed, process what we have
                        processHTTPRequest(data: receivedData, connection: connection)
                    } else {
                        // Need more data
                        receiveMore()
                    }
                }
        }

        receiveMore()
    }

    private func extractContentLength(from data: Data) -> Int? {
        guard let headerEnd = findHeaderEnd(in: data) else { return nil }
        let headerData = data.prefix(headerEnd)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        for line in headerString.split(separator: "\r\n") {
            let lowercased = line.lowercased()
            if lowercased.hasPrefix("content-length:") {
                let value = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                return Int(value)
            }
        }
        return nil
    }

    private func processHTTPRequest(data: Data, connection: NWConnection) {
        // Find body after headers (double CRLF)
        guard let headerEnd = findHeaderEnd(in: data) else {
            sendErrorResponse(connection: connection, message: "Invalid HTTP request")
            return
        }

        let body = data.suffix(from: headerEnd)

        // Process the HE computation
        Task {
            do {
                let response = try await self.processCompute(body: Data(body))
                self.sendSuccessResponse(connection: connection, body: response)
            } catch {
                self.sendErrorResponse(connection: connection, message: "Error: \(error)")
            }
        }
    }

    private func findHeaderEnd(in data: Data) -> Data.Index? {
        let crlf = Data([0x0D, 0x0A, 0x0D, 0x0A])
        for i in data.indices where data.indices.contains(i + 3) {
            if data[i] == crlf[0], data[i + 1] == crlf[1],
               data[i + 2] == crlf[2], data[i + 3] == crlf[3]
            {
                return i + 4
            }
        }
        return nil
    }

    private func processCompute(body: Data) async throws -> Data {
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
        // Running on Network.framework queue, NOT NIO event loop
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

    private func sendSuccessResponse(connection: NWConnection, body: Data) {
        let headers = """
            HTTP/1.1 200 OK\r
            Content-Type: application/octet-stream\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
        var response = Data(headers.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendErrorResponse(connection: NWConnection, message: String) {
        let body = Data(message.utf8)
        let headers = """
            HTTP/1.1 500 Internal Server Error\r
            Content-Type: text/plain\r
            Content-Length: \(body.count)\r
            Connection: close\r
            \r

            """
        var response = Data(headers.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum ServerError: Error, CustomStringConvertible {
    case databaseNotFound(String)
    case invalidPort(Int)

    var description: String {
        switch self {
        case let .databaseNotFound(path):
            "Database file not found: \(path)"
        case let .invalidPort(port):
            "Invalid port number: \(port)"
        }
    }
}
