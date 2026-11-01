import AsyncHTTPClient
import CryptoKit
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOSSL
import TenderCore

/// Where a remote head is. The token is in the secret store, not in this file.
public struct ClientContext: Codable, Sendable, Equatable {
    public var head: String
    public var caPEM: String

    public init(head: String, caPEM: String) {
        self.head = head
        self.caPEM = caPEM
    }
}

public struct ClientContextStore: Sendable {
    static let tokenName = "api-token"
    public let directory: URL
    public let secrets: any SecretStore

    public init(directory: URL, secrets: any SecretStore) {
        self.directory = directory
        self.secrets = secrets
    }

    /// `~/.config/tender` with the token in the login keychain. Setting
    /// `TENDER_CONFIG_DIR` keeps everything in that directory instead.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> ClientContextStore {
        if let override = environment["TENDER_CONFIG_DIR"], !override.isEmpty {
            let directory = URL(filePath: override)
            return ClientContextStore(directory: directory, secrets: FileSecretStore(directory: directory.appending(path: "secrets")))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ClientContextStore(
            directory: home.appending(path: ".config/tender"),
            secrets: KeychainSecretStore(keychainPath: home.appending(path: "Library/Keychains/login.keychain-db").path(percentEncoded: false),
                                         service: "com.olympsis.tender.cli"))
    }

    private var file: URL { directory.appending(path: "context.json") }

    public func save(_ context: ClientContext, token: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(context).write(to: file, options: .atomic)
        try secrets.write(Self.tokenName, Data(token.utf8))
    }

    public func load() throws -> (context: ClientContext, token: String)? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        let context = try JSONDecoder().decode(ClientContext.self, from: data)
        guard let token = try secrets.read(Self.tokenName) else { return nil }
        return (context, String(decoding: token, as: UTF8.self))
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: file)
        try secrets.delete(Self.tokenName)
    }
}

public enum ClientPinningError: Error, Equatable, CustomStringConvertible {
    case invalidCredential
    case fingerprintMismatch(expected: String, found: String)

    public var description: String {
        switch self {
        case .invalidCredential: "That token isn't valid. Create one with `tender api-token create` on the head."
        case .fingerprintMismatch(let expected, let found):
            "The head's CA fingerprint is \(found), but the token expects \(expected). This may not be your head."
        }
    }
}

public enum ClientPinning {
    public static func fingerprint(ofPEM pem: String) -> String? {
        let base64 = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded: base64), !der.isEmpty else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Fetches the head's CA and checks it against the fingerprint in the credential,
    /// so the app and CLI need nothing but `<secret>.<fingerprint>` to pin it.
    public static func fetchCA(head: String, credential: String, defaultPort: Int = 7071) async throws -> String {
        guard let separator = credential.lastIndex(of: ".") else { throw ClientPinningError.invalidCredential }
        let expected = String(credential[credential.index(after: separator)...])
        guard expected.count == 64 else { throw ClientPinningError.invalidCredential }

        var configuration = TLSConfiguration.makeClientConfiguration()
        // Nothing fetched here is trusted until its fingerprint has been compared.
        configuration.certificateVerification = .none
        let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: .init(tlsConfiguration: configuration))
        let base = head.contains(":") ? head : "\(head):\(defaultPort)"
        let pem: String
        do {
            let response = try await client.execute(HTTPClientRequest(url: "https://\(base)/v1/ca"), timeout: .seconds(10))
            pem = String(buffer: try await response.body.collect(upTo: 1 << 20))
            try await client.shutdown()
        } catch {
            try? await client.shutdown()
            throw error
        }
        let found = fingerprint(ofPEM: pem) ?? "unreadable"
        guard found == expected else { throw ClientPinningError.fingerprintMismatch(expected: expected, found: found) }
        return pem
    }
}

/// HTTPS clients by CA. One per CA for the life of the process: `HTTPClient` must be
/// shut down off the event loop, and the CLI and app only ever talk to one head.
enum PinnedClients {
    private static let clients = NIOLockedValueBox<[String: HTTPClient]>([:])

    static func client(caPEM: String) throws -> HTTPClient {
        try clients.withLockedValue { clients in
            if let existing = clients[caPEM] { return existing }
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(caPEM.utf8)))
            let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: .init(tlsConfiguration: configuration))
            clients[caPEM] = client
            return client
        }
    }
}
