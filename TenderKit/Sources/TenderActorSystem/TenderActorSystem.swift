import Distributed
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import NIOTLS
import TenderCore
import X509

/// A distributed actor's address. Always includes the node, so any node can address any actor.
public struct ActorIdentity: Hashable, Codable, Sendable, CustomStringConvertible {
    public var node: NodeID
    public var name: String

    public init(node: NodeID, name: String) {
        self.node = node
        self.name = name
    }

    public var description: String { "\(node)/\(name)" }
}

public enum TransportError: Error, Equatable, CustomStringConvertible {
    /// Safe to try again: the connection dropped or couldn't be made.
    case unreachable(NodeID, String)
    case disconnected(NodeID)
    case timedOut(NodeID)
    case noSuchActor(ActorIdentity)
    case handshakeRejected(String)
    case invalidEnvelope(String)

    public var isRetryable: Bool {
        switch self {
        case .unreachable, .disconnected, .timedOut: true
        case .noSuchActor, .handshakeRejected, .invalidEnvelope: false
        }
    }

    public var description: String {
        switch self {
        case .unreachable(let node, let detail): "Can't reach node '\(node)': \(detail)"
        case .disconnected(let node): "Connection to node '\(node)' was lost."
        case .timedOut(let node): "Node '\(node)' didn't answer in time."
        case .noSuchActor(let id): "No actor \(id)."
        case .handshakeRejected(let reason): "Handshake rejected: \(reason)"
        case .invalidEnvelope(let detail): "Invalid message: \(detail)"
        }
    }
}

/// PEM material for mutual TLS. There is deliberately no plaintext mode.
public struct TransportTLS: Sendable {
    public var certificatePEM: String
    public var privateKeyPEM: String
    public var trustRootPEM: String

    public init(certificatePEM: String, privateKeyPEM: String, trustRootPEM: String) {
        self.certificatePEM = certificatePEM
        self.privateKeyPEM = privateKeyPEM
        self.trustRootPEM = trustRootPEM
    }
}

public struct NodeAddress: Sendable, Equatable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// Finds a node's address. Pluggable so that membership can later come from gossip.
public protocol NodeResolver: Sendable {
    func address(of node: NodeID) async throws -> NodeAddress?
}

public struct StaticNodeResolver: NodeResolver {
    public var addresses: [NodeID: NodeAddress]
    public init(_ addresses: [NodeID: NodeAddress] = [:]) { self.addresses = addresses }
    public func address(of node: NodeID) async throws -> NodeAddress? { addresses[node] }
}

/// Decides whether to accept a peer that already passed mTLS.
public protocol PeerVerifier: Sendable {
    /// `certificateNode` comes from the peer's validated certificate. Throw to reject.
    func verify(certificateNode: NodeID, remoteIP: String?) async throws
}

public struct AcceptAllPeers: PeerVerifier {
    public init() {}
    public func verify(certificateNode: NodeID, remoteIP: String?) async throws {}
}

// MARK: Wire format

enum Frame: Codable, Sendable {
    case hello(protocolVersion: Int, node: NodeID)
    case helloAck(node: NodeID)
    case reject(reason: String)
    case call(CallEnvelope)
    case reply(ReplyEnvelope)
}

struct CallEnvelope: Codable, Sendable {
    var callID: UInt64
    var recipient: ActorIdentity
    var target: String
    var genericSubstitutions: [String]
    var arguments: [Data]
}

struct ReplyEnvelope: Codable, Sendable {
    var callID: UInt64
    var result: Data?
    var error: NodeCallError?
}

// MARK: Actor system

public final class TenderActorSystem: DistributedActorSystem, @unchecked Sendable {
    public typealias ActorID = ActorIdentity
    public typealias InvocationEncoder = EnvelopeEncoder
    public typealias InvocationDecoder = EnvelopeDecoder
    public typealias ResultHandler = EnvelopeResultHandler
    public typealias SerializationRequirement = any Codable

    /// Gives the next actor initialized in this task a well-known name, such as `agent`.
    @TaskLocal public static var wellKnownName: String?

    /// The authenticated node making the current inbound call.
    @TaskLocal public static var currentCaller: NodeID?

    public let localNode: NodeID
    public let protocolVersion: Int
    public let callTimeout: Duration
    let verifier: any PeerVerifier
    let resolver: any NodeResolver
    private let tls: TransportTLS
    private let group: any EventLoopGroup
    private let state = NIOLockedValueBox(State())

    private struct State {
        var actors: [ActorIdentity: any DistributedActor] = [:]
        var connections: [NodeID: Connection] = [:]
        var dials: [NodeID: Task<Connection, Error>] = [:]
        var server: (any Channel)?
        var nextCallID: UInt64 = 1
        var stopped = false
    }

    public init(
        localNode: NodeID,
        tls: TransportTLS,
        resolver: any NodeResolver = StaticNodeResolver(),
        verifier: any PeerVerifier = AcceptAllPeers(),
        protocolVersion: Int = TenderVersion.protocolVersion,
        callTimeout: Duration = .seconds(30),
        group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton
    ) {
        self.localNode = localNode
        self.tls = tls
        self.resolver = resolver
        self.verifier = verifier
        self.protocolVersion = protocolVersion
        self.callTimeout = callTimeout
        self.group = group
    }

    // MARK: Listening and dialing

    private func serverContext() throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: try NIOSSLCertificate.fromPEMBytes(Array(tls.certificatePEM.utf8)).map { .certificate($0) },
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(tls.privateKeyPEM.utf8), format: .pem))
        )
        configuration.certificateVerification = .noHostnameVerification
        configuration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(tls.trustRootPEM.utf8)))
        configuration.minimumTLSVersion = .tlsv13
        return try NIOSSLContext(configuration: configuration)
    }

    private func clientContext() throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateChain = try NIOSSLCertificate.fromPEMBytes(Array(tls.certificatePEM.utf8)).map { .certificate($0) }
        configuration.privateKey = .privateKey(try NIOSSLPrivateKey(bytes: Array(tls.privateKeyPEM.utf8), format: .pem))
        // Names are checked at the handshake against the node ID, not against a hostname.
        configuration.certificateVerification = .noHostnameVerification
        configuration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(tls.trustRootPEM.utf8)))
        configuration.minimumTLSVersion = .tlsv13
        return try NIOSSLContext(configuration: configuration)
    }

    /// Starts accepting connections and returns the bound port (for port 0).
    @discardableResult
    public func listen(host: String, port: Int) async throws -> Int {
        let context = try serverContext()
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let connection = Connection(channel: channel, system: self, role: .listener, expectedPeer: nil)
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(FrameDecoder()))
                    try channel.pipeline.syncOperations.addHandler(FrameHandler(connection: connection))
                }
            }
            .bind(host: host, port: port)
            .get()
        state.withLockedValue { $0.server = channel }
        return channel.localAddress?.port ?? port
    }

    /// The connection to `node`, dialing it if needed. Concurrent callers share one dial.
    func connection(to node: NodeID) async throws -> Connection {
        enum Next {
            case existing(Connection)
            case dial(Task<Connection, Error>)
        }
        let next: Next = state.withLockedValue { state in
            if let existing = state.connections[node], existing.isActive { return .existing(existing) }
            if let dial = state.dials[node] { return .dial(dial) }
            let task = Task { try await self.dial(node) }
            state.dials[node] = task
            return .dial(task)
        }
        switch next {
        case .existing(let connection):
            return connection
        case .dial(let task):
            defer { state.withLockedValue { $0.dials[node] = nil } }
            return try await task.value
        }
    }

    private func dial(_ node: NodeID) async throws -> Connection {
        guard let address = try await resolver.address(of: node) else {
            throw TransportError.unreachable(node, "address unknown")
        }
        return try await dial(node, at: address)
    }

    /// Connects to a known address, for a worker's first contact with its head.
    @discardableResult
    public func connect(to node: NodeID, at address: NodeAddress) async throws -> Bool {
        _ = try await dial(node, at: address)
        return true
    }

    private func dial(_ node: NodeID, at address: NodeAddress) async throws -> Connection {
        let context = try clientContext()
        let box = NIOLockedValueBox<Connection?>(nil)
        let channel: any Channel
        do {
            channel = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(5))
                .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let connection = Connection(channel: channel, system: self, role: .dialer, expectedPeer: node)
                        box.withLockedValue { $0 = connection }
                        try channel.pipeline.syncOperations.addHandler(try NIOSSLClientHandler(context: context, serverHostname: nil))
                        try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(FrameDecoder()))
                        try channel.pipeline.syncOperations.addHandler(FrameHandler(connection: connection))
                    }
                }
                .connect(host: address.host, port: address.port)
                .get()
        } catch {
            throw TransportError.unreachable(node, "\(error)")
        }
        guard let connection = box.withLockedValue({ $0 }) else {
            throw TransportError.unreachable(node, "no connection")
        }
        do {
            try await connection.waitForHandshake(timeout: .seconds(10))
        } catch {
            channel.close(mode: .all, promise: nil)
            throw error
        }
        return connection
    }

    /// The newest connection to a peer wins: an old one may belong to a process or
    /// machine that died without closing it.
    func register(_ connection: Connection, peer: NodeID) {
        let replaced: Connection? = state.withLockedValue { state in
            let previous = state.connections[peer]
            state.connections[peer] = connection
            return previous === connection ? nil : previous
        }
        replaced?.close()
    }

    func unregister(_ connection: Connection, peer: NodeID) {
        state.withLockedValue { state in
            if state.connections[peer] === connection { state.connections[peer] = nil }
        }
    }

    /// Whether a live connection to `node` exists.
    public func isConnected(to node: NodeID) -> Bool {
        state.withLockedValue { $0.connections[node]?.isActive ?? false }
    }

    /// Drops a peer's connection, for example when its certificate is revoked.
    public func disconnect(_ node: NodeID) {
        let connection = state.withLockedValue { $0.connections[node] }
        connection?.close()
    }

    public func shutdown() async {
        let (server, connections): ((any Channel)?, [Connection]) = state.withLockedValue { state in
            state.stopped = true
            defer {
                state.server = nil
                state.connections = [:]
            }
            return (state.server, Array(state.connections.values))
        }
        try? await server?.close()
        connections.forEach { $0.close() }
    }

    // MARK: DistributedActorSystem

    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
    where Act: DistributedActor, Act.ID == ActorID {
        // A @Resolvable stub isn't the concrete actor's type, so a local actor can come
        // back as nil here. remoteCall then dispatches in-process: one code path.
        state.withLockedValue { $0.actors[id] as? Act }
    }

    public func assignID<Act>(_ actorType: Act.Type) -> ActorID where Act: DistributedActor, Act.ID == ActorID {
        ActorIdentity(node: localNode, name: Self.wellKnownName ?? UUID().uuidString)
    }

    public func actorReady<Act>(_ actor: Act) where Act: DistributedActor, Act.ID == ActorID {
        state.withLockedValue { $0.actors[actor.id] = actor }
    }

    public func resignID(_ id: ActorID) {
        state.withLockedValue { $0.actors[id] = nil }
    }

    public func makeInvocationEncoder() -> InvocationEncoder { EnvelopeEncoder() }

    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res where Act: DistributedActor, Act.ID == ActorID, Err: Error, Res: Codable {
        let data = try await send(recipient: actor.id, target: target, invocation: invocation)
        guard let data else { throw TransportError.invalidEnvelope("reply has no result") }
        do {
            return try JSONDecoder().decode(Res.self, from: data)
        } catch {
            throw TransportError.invalidEnvelope("\(error)")
        }
    }

    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws where Act: DistributedActor, Act.ID == ActorID, Err: Error {
        _ = try await send(recipient: actor.id, target: target, invocation: invocation)
    }

    private func send(recipient: ActorIdentity, target: RemoteCallTarget, invocation: InvocationEncoder) async throws -> Data? {
        let callID = state.withLockedValue { state -> UInt64 in
            defer { state.nextCallID += 1 }
            return state.nextCallID
        }
        let call = CallEnvelope(callID: callID, recipient: recipient, target: target.identifier,
                                genericSubstitutions: invocation.genericSubstitutions,
                                arguments: invocation.arguments)
        let reply: ReplyEnvelope
        if recipient.node == localNode {
            reply = await Self.$currentCaller.withValue(localNode) { await handle(call) }
        } else {
            let connection = try await connection(to: recipient.node)
            reply = try await connection.call(call, timeout: callTimeout)
        }
        if let error = reply.error { throw error }
        return reply.result
    }

    /// Runs an inbound call. Errors travel as `NodeCallError`, the only type both sides share.
    func handle(_ call: CallEnvelope) async -> ReplyEnvelope {
        guard let actor = state.withLockedValue({ $0.actors[call.recipient] }) else {
            return ReplyEnvelope(callID: call.callID, result: nil, error: NodeCallError(
                code: "no_such_actor", message: TransportError.noSuchActor(call.recipient).description, httpStatus: 502))
        }
        var decoder = EnvelopeDecoder(call: call)
        let handler = EnvelopeResultHandler()
        do {
            try await executeDistributedTarget(
                on: actor,
                target: RemoteCallTarget(call.target),
                invocationDecoder: &decoder,
                handler: handler
            )
        } catch {
            handler.record(error: error)
        }
        let (result, failure) = handler.outcome
        return ReplyEnvelope(callID: call.callID, result: result, error: failure)
    }
}

// MARK: Invocation

public struct EnvelopeEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = any Codable
    var genericSubstitutions: [String] = []
    var arguments: [Data] = []

    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {
        genericSubstitutions.append(_mangledTypeName(T.self) ?? "")
    }

    public mutating func recordArgument<Value: Codable>(_ argument: RemoteCallArgument<Value>) throws {
        arguments.append(try JSONEncoder().encode(argument.value))
    }

    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {}
    public mutating func recordReturnType<R: Codable>(_ type: R.Type) throws {}
    public mutating func doneRecording() throws {}
}

public struct EnvelopeDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = any Codable
    private let call: CallEnvelope
    private var nextArgument = 0

    init(call: CallEnvelope) { self.call = call }

    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        try call.genericSubstitutions.map { name in
            guard let type = _typeByName(name) else { throw TransportError.invalidEnvelope("unknown type \(name)") }
            return type
        }
    }

    public mutating func decodeNextArgument<Argument: Codable>() throws -> Argument {
        guard nextArgument < call.arguments.count else { throw TransportError.invalidEnvelope("missing argument") }
        defer { nextArgument += 1 }
        return try JSONDecoder().decode(Argument.self, from: call.arguments[nextArgument])
    }

    public mutating func decodeErrorType() throws -> Any.Type? { nil }
    public mutating func decodeReturnType() throws -> Any.Type? { nil }
}

public final class EnvelopeResultHandler: DistributedTargetInvocationResultHandler, @unchecked Sendable {
    public typealias SerializationRequirement = any Codable
    private let box = NIOLockedValueBox<(Data?, NodeCallError?)>((nil, nil))

    var outcome: (Data?, NodeCallError?) { box.withLockedValue { $0 } }

    public func onReturn<Success: Codable>(value: Success) async throws {
        let data = try JSONEncoder().encode(value)
        box.withLockedValue { $0 = (data, nil) }
    }

    public func onReturnVoid() async throws {}

    public func onThrow<Err: Error>(error: Err) async throws {
        record(error: error)
    }

    func record(error: any Error) {
        let failure = (error as? NodeCallError) ?? NodeCallError(code: "internal", message: "\(error)")
        box.withLockedValue { $0 = (nil, failure) }
    }
}

// MARK: Connection

final class Connection: @unchecked Sendable {
    enum Role { case dialer, listener }

    private let channel: any Channel
    private let system: TenderActorSystem
    let role: Role
    private let expectedPeer: NodeID?
    private let state = NIOLockedValueBox(ConnectionState())

    private struct ConnectionState {
        var peer: NodeID?
        var pending: [UInt64: CheckedContinuation<ReplyEnvelope, Error>] = [:]
        var handshake: HandshakeState = .waiting([])
        var closed = false
    }

    private enum HandshakeState {
        case waiting([CheckedContinuation<Void, Error>])
        case done
        case failed(Error)
    }

    init(channel: any Channel, system: TenderActorSystem, role: Role, expectedPeer: NodeID?) {
        self.channel = channel
        self.system = system
        self.role = role
        self.expectedPeer = expectedPeer
    }

    var isActive: Bool {
        channel.isActive && state.withLockedValue { state in
            if case .done = state.handshake, !state.closed { return true }
            return false
        }
    }

    func close() { channel.close(mode: .all, promise: nil) }

    func waitForHandshake(timeout: Duration) async throws {
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            self?.failHandshake(TransportError.unreachable(self?.expectedPeer ?? NodeID("?"), "handshake timed out"))
            self?.close()
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            state.withLockedValue { state in
                switch state.handshake {
                case .waiting(var waiters):
                    waiters.append(continuation)
                    state.handshake = .waiting(waiters)
                case .done:
                    continuation.resume()
                case .failed(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func completeHandshake(peer: NodeID) {
        let waiters = state.withLockedValue { state -> [CheckedContinuation<Void, Error>] in
            state.peer = peer
            guard case .waiting(let waiters) = state.handshake else { return [] }
            state.handshake = .done
            return waiters
        }
        system.register(self, peer: peer)
        waiters.forEach { $0.resume() }
    }

    private func failHandshake(_ error: Error) {
        let waiters = state.withLockedValue { state -> [CheckedContinuation<Void, Error>] in
            guard case .waiting(let waiters) = state.handshake else { return [] }
            state.handshake = .failed(error)
            return waiters
        }
        waiters.forEach { $0.resume(throwing: error) }
    }

    private func write(_ frame: Frame) {
        guard let data = try? JSONEncoder().encode(frame) else { return }
        var buffer = channel.allocator.buffer(capacity: data.count + 4)
        buffer.writeInteger(UInt32(data.count))
        buffer.writeBytes(data)
        channel.writeAndFlush(buffer, promise: nil)
    }

    func call(_ call: CallEnvelope, timeout: Duration) async throws -> ReplyEnvelope {
        let peer = state.withLockedValue { $0.peer } ?? NodeID("?")
        let callID = call.callID
        let timer = Task { [weak self] in
            try await Task.sleep(for: timeout)
            let continuation = self?.state.withLockedValue { $0.pending.removeValue(forKey: callID) }
            continuation?.resume(throwing: TransportError.timedOut(peer))
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            let accepted = state.withLockedValue { state -> Bool in
                guard !state.closed else { return false }
                state.pending[callID] = continuation
                return true
            }
            if accepted {
                write(.call(call))
            } else {
                continuation.resume(throwing: TransportError.disconnected(peer))
            }
        }
    }

    // MARK: Events from the pipeline

    /// TLS is up, so the dialer speaks first.
    func tlsEstablished() {
        if role == .dialer { write(.hello(protocolVersion: system.protocolVersion, node: system.localNode)) }
    }

    func closed() {
        let (peer, pending) = state.withLockedValue { state -> (NodeID?, [CheckedContinuation<ReplyEnvelope, Error>]) in
            state.closed = true
            defer { state.pending = [:] }
            return (state.peer, Array(state.pending.values))
        }
        let name = peer ?? expectedPeer ?? NodeID("?")
        failHandshake(TransportError.unreachable(name, "connection closed during handshake"))
        pending.forEach { $0.resume(throwing: TransportError.disconnected(name)) }
        if let peer { system.unregister(self, peer: peer) }
    }

    func received(_ frame: Frame) {
        switch frame {
        case .hello(let version, let node):
            guard role == .listener else { return protocolViolation() }
            Task { await self.acceptHello(version: version, node: node) }
        case .helloAck(let node):
            guard role == .dialer else { return protocolViolation() }
            verifyAck(node: node)
        case .reject(let reason):
            failHandshake(TransportError.handshakeRejected(reason))
            close()
        case .call(let call):
            // Nothing runs before the peer has been authenticated.
            guard isActive else { return protocolViolation() }
            Task {
                let caller = state.withLockedValue { $0.peer }
                let reply = await TenderActorSystem.$currentCaller.withValue(caller) { await system.handle(call) }
                write(.reply(reply))
            }
        case .reply(let reply):
            guard isActive else { return protocolViolation() }
            let continuation = state.withLockedValue { $0.pending.removeValue(forKey: reply.callID) }
            continuation?.resume(returning: reply)
        }
    }

    private func protocolViolation() {
        failHandshake(TransportError.handshakeRejected("unexpected message"))
        close()
    }

    private func acceptHello(version: Int, node: NodeID) async {
        guard version == system.protocolVersion else {
            return reject("protocol version mismatch: this node speaks \(system.protocolVersion), the peer speaks \(version). Upgrade so that both match.")
        }
        do {
            let certificateNode = try await peerCertificateNode()
            guard certificateNode == node else {
                return reject("certificate is for '\(certificateNode)', but the peer says it is '\(node)'.")
            }
            try await system.verifier.verify(certificateNode: certificateNode, remoteIP: channel.remoteAddress?.ipAddress)
        } catch {
            return reject("\(error)")
        }
        write(.helloAck(node: system.localNode))
        completeHandshake(peer: node)
    }

    private func verifyAck(node: NodeID) {
        Task {
            do {
                let certificateNode = try await peerCertificateNode()
                guard certificateNode == node, expectedPeer == nil || expectedPeer == node else {
                    throw TransportError.handshakeRejected(
                        "expected node '\(expectedPeer?.rawValue ?? "?")', but its certificate is for '\(certificateNode)'.")
                }
                try await system.verifier.verify(certificateNode: certificateNode, remoteIP: channel.remoteAddress?.ipAddress)
                completeHandshake(peer: node)
            } catch {
                failHandshake(error as? TransportError ?? TransportError.handshakeRejected("\(error)"))
                close()
            }
        }
    }

    private func reject(_ reason: String) {
        write(.reject(reason: reason))
        failHandshake(TransportError.handshakeRejected(reason))
        // Give the rejection a chance to reach the peer before the close.
        channel.eventLoop.scheduleTask(in: .milliseconds(100)) { self.close() }
    }

    private func peerCertificateNode() async throws -> NodeID {
        let channel = self.channel
        let der: [UInt8]? = try await channel.eventLoop.submit {
            let handler = try channel.pipeline.syncOperations.handler(type: NIOSSLHandler.self)
            return try handler.peerCertificate?.toDERBytes()
        }.get()
        guard let der else { throw TransportError.handshakeRejected("peer sent no certificate") }
        let certificate = try Certificate(derEncoded: der)
        guard let names = try certificate.extensions.subjectAlternativeNames else {
            throw TransportError.handshakeRejected("peer certificate has no subject alternative name")
        }
        for name in names {
            if case .dnsName(let value) = name { return NodeID(value) }
        }
        throw TransportError.handshakeRejected("peer certificate names no node")
    }
}

// MARK: Pipeline

struct FrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    static let maxFrameSize = 32 << 20

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else { return .needMoreData }
        guard length <= Self.maxFrameSize else {
            throw TransportError.invalidEnvelope("frame of \(length) bytes is too large")
        }
        guard buffer.readableBytes >= 4 + Int(length) else { return .needMoreData }
        buffer.moveReaderIndex(forwardBy: 4)
        context.fireChannelRead(wrapInboundOut(buffer.readSlice(length: Int(length))!))
        return .continue
    }
}

final class FrameHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let connection: Connection

    init(connection: Connection) { self.connection = connection }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event as? TLSUserEvent ?? .shutdownCompleted {
            connection.tlsEstablished()
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard let frame = try? JSONDecoder().decode(Frame.self, from: Data(buffer.readableBytesView)) else {
            context.close(promise: nil)
            return
        }
        connection.received(frame)
    }

    func channelInactive(context: ChannelHandlerContext) {
        connection.closed()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
