import Foundation
import Network
import Security

/// Loopback-only pages for real WebKit tests. Held responses stay unfinished
/// until explicitly released; stop cancels all connections, including stalls.
final class ComposeFixtureServer: @unchecked Sendable {
    private let listener: NWListener
    struct Response: Sendable {
        let body: String
        var status = "200 OK"
        var headers = ["Content-Type": "text/html; charset=utf-8"]
    }

    private let responses: [String: Response]
    private let scheme: String
    private let lock = NSLock()
    private var heldPaths: Set<String>
    private var heldResponses: [(NWConnection, Data)] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var targets: [String] = []
    private var stopped = false
    private(set) var port: UInt16 = 0

    var requestedTargets: [String] { lock.withLock { targets } }

    convenience init(pages: [String: String], holdPaths: Set<String> = []) async throws {
        try await self.init(responses: pages.mapValues { Response(body: $0) }, holdPaths: holdPaths)
    }

    @MainActor
    init(responses: [String: Response], holdPaths: Set<String> = [], tlsIdentity: SecIdentity? = nil) async throws {
        self.responses = responses
        self.heldPaths = holdPaths
        scheme = tlsIdentity == nil ? "http" : "https"
        let parameters: NWParameters
        if let tlsIdentity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(tlsIdentity)!)
            parameters = NWParameters(tls: tls)
        } else {
            parameters = .tcp
        }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let accepted = self.lock.withLock {
                guard !self.stopped else { return false }
                self.connections[ObjectIdentifier(connection)] = connection
                return true
            }
            guard accepted else { connection.cancel(); return }
            connection.start(queue: .global())
            self.receiveRequest(connection, accumulated: Data())
        }
        port = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "ChorusComposeFixtures"))
        }
    }

    func url(_ path: String = "/") -> URL {
        URL(string: "\(scheme)://127.0.0.1:\(port)\(path)")!
    }

    func releaseHeldResponses() {
        let responses = lock.withLock {
            heldPaths.removeAll()
            let responses = heldResponses
            heldResponses.removeAll()
            return responses
        }
        responses.forEach { send($0.1, on: $0.0) }
    }

    func stop() {
        let active = lock.withLock {
            stopped = true
            heldResponses.removeAll()
            let active = Array(connections.values)
            connections.removeAll()
            return active
        }
        listener.cancel()
        active.forEach { $0.cancel() }
    }

    deinit { stop() }

    private func finish(_ connection: NWConnection) {
        _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
        connection.cancel()
    }

    private func send(_ response: Data, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finish(connection)
            connection.cancel()
        })
    }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let data { request.append(data) }
            guard error == nil, request.count < 65536 else { self.finish(connection); return }
            guard let text = String(data: request, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete { self.finish(connection) }
                else { self.receiveRequest(connection, accumulated: request) }
                return
            }
            let target = text.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let path = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
            let fixture = self.responses[path] ?? Response(body: "<!doctype html><p>Missing fixture</p>", status: "404 Not Found")
            let body = Data(fixture.body.utf8)
            let headers = fixture.headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
            var response = Data("HTTP/1.1 \(fixture.status)\r\n\(headers)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            response.append(body)
            let held = self.lock.withLock {
                self.targets.append(target)
                if self.heldPaths.contains(path) && !self.stopped {
                    self.heldResponses.append((connection, response))
                    return true
                }
                return false
            }
            if !held { self.send(response, on: connection) }
        }
    }
}
