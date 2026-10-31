import Crypto
import Foundation
import SwiftASN1
import TenderCore
import X509

public enum PKIError: Error, Equatable, CustomStringConvertible {
    case invalidCSR(String)
    case nodeMismatch(expected: String, found: String)
    case invalidNodeID(String)
    case invalidAuthority(String)

    public var description: String {
        switch self {
        case .invalidCSR(let detail): "Invalid certificate request: \(detail)"
        case .nodeMismatch(let expected, let found): "Certificate request is for '\(found)', not '\(expected)'."
        case .invalidNodeID(let id): "'\(id)' isn't a valid node ID."
        case .invalidAuthority(let detail): "Invalid CA: \(detail)"
        }
    }
}

/// The cluster's internal certificate authority. Holds the only copy of its key
/// (plus any offline backup), so it issues certificates without seeing node keys.
public struct CertificateAuthority: Sendable {
    public let certificatePEM: String
    public let privateKeyPEM: String
    private let certificate: Certificate
    private let key: Certificate.PrivateKey

    public static let certificateValidity: TimeInterval = 2 * 365 * 86400
    public static let authorityValidity: TimeInterval = 20 * 365 * 86400

    public init(certificatePEM: String, privateKeyPEM: String) throws {
        self.certificatePEM = certificatePEM
        self.privateKeyPEM = privateKeyPEM
        certificate = try Certificate(pemEncoded: certificatePEM)
        key = Certificate.PrivateKey(try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM))
        guard certificate.publicKey == key.publicKey else {
            throw PKIError.invalidAuthority("the private key doesn't match the certificate")
        }
        guard case .isCertificateAuthority = try certificate.extensions.basicConstraints else {
            throw PKIError.invalidAuthority("the certificate isn't a CA certificate")
        }
    }

    /// Reads `tender ca export` output. Older exports have no newline between the two
    /// PEM blocks, so this looks for the markers instead of parsing line by line.
    public init(backupPEM: String) throws {
        guard let certificate = Self.pemBlock("CERTIFICATE", in: backupPEM) else {
            throw PKIError.invalidAuthority("the backup has no certificate")
        }
        guard let key = Self.pemBlock("PRIVATE KEY", in: backupPEM) ?? Self.pemBlock("EC PRIVATE KEY", in: backupPEM) else {
            throw PKIError.invalidAuthority("the backup has no private key")
        }
        try self.init(certificatePEM: certificate, privateKeyPEM: key)
    }

    private static func pemBlock(_ label: String, in text: String) -> String? {
        guard let start = text.range(of: "-----BEGIN \(label)-----"),
              let end = text.range(of: "-----END \(label)-----", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.lowerBound..<end.upperBound])
    }

    public static func create(name: String = "Tender Internal CA", now: Date = Date()) throws -> CertificateAuthority {
        let signing = P256.Signing.PrivateKey()
        let key = Certificate.PrivateKey(signing)
        let subject = try DistinguishedName { CommonName(name) }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-300),
            notValidAfter: now.addingTimeInterval(authorityValidity),
            issuer: subject,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: key
        )
        return try CertificateAuthority(
            certificatePEM: try certificate.serializeAsPEM().pemString,
            privateKeyPEM: signing.pemRepresentation
        )
    }

    /// SHA-256 of the DER certificate, hex. Join tokens carry it so that a joining
    /// node can tell it reached the right head before trusting anything it says.
    public var fingerprint: String { Self.fingerprint(ofPEM: certificatePEM) ?? "" }

    public static func fingerprint(ofPEM pem: String) -> String? {
        guard let document = try? PEMDocument(pemString: pem) else { return nil }
        return SHA256.hash(data: Data(document.derBytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// Signs a node's CSR. The node's name comes from the caller, never from the
    /// CSR alone, and the CSR's own signature proves possession of the key.
    public func sign(csrPEM: String, nodeID: NodeID, dnsNames: [String] = [], ipAddresses: [String] = [],
                     now: Date = Date()) throws -> String {
        guard Self.isValidNodeID(nodeID.rawValue) else { throw PKIError.invalidNodeID(nodeID.rawValue) }
        let csr: CertificateSigningRequest
        do {
            csr = try CertificateSigningRequest(pemEncoded: csrPEM)
        } catch {
            throw PKIError.invalidCSR("\(error)")
        }
        guard csr.publicKey.isValidSignature(csr.signature, for: csr) else {
            throw PKIError.invalidCSR("signature doesn't match its public key")
        }
        let found = csr.subject.first { $0.first?.type == .RDNAttributeType.commonName }?.first
            .map { String(describing: $0.value) }
        if let found, found != nodeID.rawValue { throw PKIError.nodeMismatch(expected: nodeID.rawValue, found: found) }

        var names: [GeneralName] = [.dnsName(nodeID.rawValue)]
        names += dnsNames.filter { $0 != nodeID.rawValue }.map { .dnsName($0) }
        for address in ipAddresses {
            if let bytes = Self.ipBytes(address) { names.append(.ipAddress(ASN1OctetString(contentBytes: bytes[...]))) }
        }
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: csr.publicKey,
            notValidBefore: now.addingTimeInterval(-300),
            notValidAfter: now.addingTimeInterval(Self.certificateValidity),
            issuer: self.certificate.subject,
            subject: try DistinguishedName { CommonName(nodeID.rawValue) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true))
                try ExtendedKeyUsage([.serverAuth, .clientAuth])
                SubjectAlternativeNames(names)
            },
            issuerPrivateKey: key
        )
        return try certificate.serializeAsPEM().pemString
    }

    public static func isValidNodeID(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 63, id.first != "-" else { return false }
        return id.unicodeScalars.allSatisfy {
            switch $0 {
            case "a"..."z", "A"..."Z", "0"..."9", "-", "_", ".": true
            default: false
            }
        }
    }

    static func ipBytes(_ address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            return withUnsafeBytes(of: &v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { Array($0) }
        }
        return nil
    }
}

/// A node's key. It is generated where it's used and never leaves the node.
public struct NodeKey: Sendable {
    public let privateKeyPEM: String

    public init(privateKeyPEM: String) { self.privateKeyPEM = privateKeyPEM }

    public static func generate() -> NodeKey {
        NodeKey(privateKeyPEM: P256.Signing.PrivateKey().pemRepresentation)
    }

    public func makeCSR(nodeID: NodeID) throws -> String {
        let signing = try P256.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        let csr = try CertificateSigningRequest(
            version: .v1,
            subject: try DistinguishedName { CommonName(nodeID.rawValue) },
            privateKey: Certificate.PrivateKey(signing),
            attributes: CertificateSigningRequest.Attributes(),
            signatureAlgorithm: .ecdsaWithSHA256
        )
        return try csr.serializeAsPEM().pemString
    }
}

/// `<secret>.<CA fingerprint>`. The secret proves the worker may join, and the
/// fingerprint lets the worker verify the head, so neither side trusts the network.
public struct JoinToken: Sendable, Equatable {
    public var secret: String
    public var caFingerprint: String

    public init(secret: String, caFingerprint: String) {
        self.secret = secret
        self.caFingerprint = caFingerprint
    }

    public init?(parsing text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].count == 64 else { return nil }
        self.init(secret: String(parts[0]), caFingerprint: String(parts[1]))
    }

    public var text: String { "\(secret).\(caFingerprint)" }

    public static func randomSecret(bytes: Int = 32) -> String {
        Data((0..<bytes).map { _ in UInt8.random(in: .min ... .max) })
            .map { String(format: "%02x", $0) }.joined()
    }

    public static func hash(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: Tailscale

/// Runs the Tailscale CLI. A protocol so that tests can script its answers.
public protocol TailscaleRunning: Sendable {
    func whois(ip: String) async throws -> Data
}

public struct WhoisResult: Sendable, Equatable {
    public var machineName: String
    public var tags: [String]

    public init(machineName: String, tags: [String]) {
        self.machineName = machineName
        self.tags = tags
    }

    /// Parses `tailscale whois --json`. Reads only the fields needed, as the rest isn't stable.
    public init?(json: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let node = root["Node"] as? [String: Any]
        else { return nil }
        var name = node["ComputedName"] as? String
        if name == nil || name?.isEmpty == true, let full = node["Name"] as? String {
            name = full.split(separator: ".").first.map(String.init)
        }
        guard let name, !name.isEmpty else { return nil }
        self.init(machineName: name, tags: node["Tags"] as? [String] ?? [])
    }
}

public enum IdentityMode: String, Codable, Sendable {
    /// Reject a peer whose Tailscale identity doesn't match its certificate.
    case enforce
    /// Log a mismatch and let the peer through. For development.
    case warn
    /// Skip the check. For nodes not on a tailnet, such as loopback tests.
    case off
}

public enum IdentityCheckError: Error, Equatable, CustomStringConvertible {
    case mismatch(certificate: String, tailscale: String)
    case missingTag(node: String, required: [String])
    case lookupFailed(ip: String, detail: String)

    public var description: String {
        switch self {
        case .mismatch(let certificate, let tailscale):
            "Certificate is for '\(certificate)' but Tailscale says this peer is '\(tailscale)'."
        case .missingTag(let node, let required):
            "Tailscale node '\(node)' has none of the tags \(required.joined(separator: ", "))."
        case .lookupFailed(let ip, let detail):
            "Couldn't identify \(ip) with Tailscale: \(detail)"
        }
    }
}

/// Requires a peer's certificate name to match what Tailscale says about its IP.
public struct TailscaleIdentityCheck: Sendable {
    public let mode: IdentityMode
    public let requiredTags: [String]
    private let runner: any TailscaleRunning
    private let warn: @Sendable (String) -> Void

    public init(mode: IdentityMode, requiredTags: [String] = [], runner: any TailscaleRunning = TailscaleCLI(),
                warn: @escaping @Sendable (String) -> Void = { _ in }) {
        self.mode = mode
        self.requiredTags = requiredTags
        self.runner = runner
        self.warn = warn
    }

    public func verify(certificateNode: NodeID, remoteIP: String) async throws {
        guard mode != .off else { return }
        do {
            let data: Data
            do {
                data = try await runner.whois(ip: remoteIP)
            } catch {
                throw IdentityCheckError.lookupFailed(ip: remoteIP, detail: "\(error)")
            }
            guard let identity = WhoisResult(json: data) else {
                throw IdentityCheckError.lookupFailed(ip: remoteIP, detail: "unrecognized whois output")
            }
            guard identity.machineName.lowercased() == certificateNode.rawValue.lowercased() else {
                throw IdentityCheckError.mismatch(certificate: certificateNode.rawValue, tailscale: identity.machineName)
            }
            if !requiredTags.isEmpty, Set(requiredTags).isDisjoint(with: identity.tags) {
                throw IdentityCheckError.missingTag(node: identity.machineName, required: requiredTags)
            }
        } catch let error as IdentityCheckError {
            guard mode == .enforce else {
                warn("identity check: \(error)")
                return
            }
            throw error
        }
    }
}

/// The macOS app and the open-source `tailscaled` install different binaries, and
/// the app's LocalAPI socket isn't at a fixed path, so this goes through the CLI.
public struct TailscaleCLI: TailscaleRunning {
    public static let candidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    public init() {}

    public enum CLIError: Error, CustomStringConvertible {
        case notInstalled
        case failed(String)

        public var description: String {
            switch self {
            case .notInstalled: "The Tailscale CLI isn't installed."
            case .failed(let message): message
            }
        }
    }

    public static func executable() -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func whois(ip: String) async throws -> Data {
        guard let executable = Self.executable() else { throw CLIError.notInstalled }
        return try await Self.run(executable: executable, arguments: ["whois", "--json", ip])
    }

    /// This node's tailnet IPv4 address, if Tailscale is up.
    public static func localIPv4() async -> String? {
        guard let executable = executable(),
              let data = try? await run(executable: executable, arguments: ["ip", "-4"]) else { return nil }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private static func run(executable: String, arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = errors
            process.terminationHandler = { finished in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    continuation.resume(throwing: CLIError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
