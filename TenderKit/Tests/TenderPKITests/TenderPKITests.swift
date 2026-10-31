import Crypto
import Foundation
import Testing
import TenderCore
import X509
@testable import TenderPKI

@Test func signsACSRWithTheNodeAsSAN() throws {
    let ca = try CertificateAuthority.create()
    let key = NodeKey.generate()
    let pem = try ca.sign(csrPEM: try key.makeCSR(nodeID: NodeID("mac-2")), nodeID: NodeID("mac-2"),
                          dnsNames: ["head.example"], ipAddresses: ["100.68.3.107", "::1"])
    let certificate = try Certificate(pemEncoded: pem)
    let names = try #require(try certificate.extensions.subjectAlternativeNames)
    #expect(names.contains(.dnsName("mac-2")))
    #expect(names.contains(.dnsName("head.example")))
    #expect(names.filter { if case .ipAddress = $0 { true } else { false } }.count == 2)
    #expect(certificate.issuer == (try Certificate(pemEncoded: ca.certificatePEM)).subject)
    let authority = try Certificate(pemEncoded: ca.certificatePEM)
    #expect(authority.publicKey.isValidSignature(certificate.signature, for: certificate))
}

@Test func caRoundTripsThroughPEM() throws {
    let ca = try CertificateAuthority.create()
    let loaded = try CertificateAuthority(certificatePEM: ca.certificatePEM, privateKeyPEM: ca.privateKeyPEM)
    #expect(loaded.fingerprint == ca.fingerprint)
    #expect(ca.fingerprint.count == 64)
    let csr = try NodeKey.generate().makeCSR(nodeID: NodeID("n"))
    _ = try loaded.sign(csrPEM: csr, nodeID: NodeID("n"))
}

@Test func refusesACSRForAnotherNode() throws {
    let ca = try CertificateAuthority.create()
    let csr = try NodeKey.generate().makeCSR(nodeID: NodeID("mac-2"))
    #expect(throws: PKIError.nodeMismatch(expected: "mac-3", found: "mac-2")) {
        try ca.sign(csrPEM: csr, nodeID: NodeID("mac-3"))
    }
}

@Test func refusesGarbageCSR() throws {
    let ca = try CertificateAuthority.create()
    #expect(throws: PKIError.self) { try ca.sign(csrPEM: "nonsense", nodeID: NodeID("n")) }
}

@Test(arguments: ["../evil", "a/b", "", "-x", "a b", String(repeating: "x", count: 64)])
func refusesUnsafeNodeIDs(id: String) throws {
    let ca = try CertificateAuthority.create()
    let csr = try NodeKey.generate().makeCSR(nodeID: NodeID("ok"))
    #expect(throws: PKIError.invalidNodeID(id)) { try ca.sign(csrPEM: csr, nodeID: NodeID(id)) }
}

@Test func joinTokenParsing() {
    let fingerprint = String(repeating: "a", count: 64)
    let token = JoinToken(secret: "s3", caFingerprint: fingerprint)
    #expect(JoinToken(parsing: token.text) == token)
    #expect(JoinToken(parsing: "no-dot") == nil)
    #expect(JoinToken(parsing: ".\(fingerprint)") == nil)
    #expect(JoinToken(parsing: "s.short") == nil)
    #expect(JoinToken.randomSecret() != JoinToken.randomSecret())
    #expect(JoinToken.hash("a") != "a")
}

// MARK: Tailscale

private struct FakeTailscale: TailscaleRunning {
    var output: Result<Data, TailscaleCLI.CLIError>
    func whois(ip: String) async throws -> Data { try output.get() }
}

private func whois(name: String, tags: [String] = []) -> Data {
    try! JSONSerialization.data(withJSONObject: ["Node": ["ComputedName": name, "Tags": tags]])
}

@Test func parsesWhois() {
    let full = #"{"Node":{"Name":"mac-2.tail1234.ts.net.","ComputedName":"mac-2","Tags":["tag:tender-worker"],"Other":1},"UserProfile":{}}"#
    #expect(WhoisResult(json: Data(full.utf8)) == WhoisResult(machineName: "mac-2", tags: ["tag:tender-worker"]))
    let nameOnly = #"{"Node":{"Name":"mac-3.tail1234.ts.net."}}"#
    #expect(WhoisResult(json: Data(nameOnly.utf8))?.machineName == "mac-3")
    #expect(WhoisResult(json: Data("{}".utf8)) == nil)
    #expect(WhoisResult(json: Data("nope".utf8)) == nil)
}

@Test func enforceRejectsMismatchedIdentity() async throws {
    let check = TailscaleIdentityCheck(mode: .enforce, runner: FakeTailscale(output: .success(whois(name: "mac-9"))))
    await #expect(throws: IdentityCheckError.mismatch(certificate: "mac-2", tailscale: "mac-9")) {
        try await check.verify(certificateNode: NodeID("mac-2"), remoteIP: "100.1.1.1")
    }
}

@Test func enforceAcceptsMatchIgnoringCase() async throws {
    let check = TailscaleIdentityCheck(mode: .enforce, runner: FakeTailscale(output: .success(whois(name: "MAC-2"))))
    try await check.verify(certificateNode: NodeID("mac-2"), remoteIP: "100.1.1.1")
}

@Test func enforceRequiresATag() async throws {
    let runner = FakeTailscale(output: .success(whois(name: "mac-2", tags: ["tag:other"])))
    let check = TailscaleIdentityCheck(mode: .enforce, requiredTags: ["tag:tender-worker"], runner: runner)
    await #expect(throws: IdentityCheckError.self) {
        try await check.verify(certificateNode: NodeID("mac-2"), remoteIP: "100.1.1.1")
    }
}

@Test func enforceFailsClosedWhenLookupFails() async throws {
    let check = TailscaleIdentityCheck(mode: .enforce, runner: FakeTailscale(output: .failure(.notInstalled)))
    await #expect(throws: IdentityCheckError.self) {
        try await check.verify(certificateNode: NodeID("mac-2"), remoteIP: "100.1.1.1")
    }
}

@Test func warnModeLetsThroughAndReports() async throws {
    let messages = Messages()
    let check = TailscaleIdentityCheck(mode: .warn, runner: FakeTailscale(output: .success(whois(name: "mac-9"))),
                                       warn: { messages.add($0) })
    try await check.verify(certificateNode: NodeID("mac-2"), remoteIP: "100.1.1.1")
    #expect(messages.all.count == 1)
}

@Test func offModeDoesNothing() async throws {
    let check = TailscaleIdentityCheck(mode: .off, runner: FakeTailscale(output: .failure(.notInstalled)))
    try await check.verify(certificateNode: NodeID("mac-2"), remoteIP: "100.1.1.1")
}

private final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ message: String) { lock.withLock { stored.append(message) } }
    var all: [String] { lock.withLock { stored } }
}

// MARK: Secret stores

@Test func fileSecretStoreIsPrivate() throws {
    let directory = URL(filePath: "/tmp/tender-test-\(UUID().uuidString.prefix(8))/secrets")
    defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
    let store = FileSecretStore(directory: directory)
    #expect(try store.read("k") == nil)
    try store.write("k", Data("v1".utf8))
    try store.write("k", Data("v2".utf8))
    #expect(try store.read("k") == Data("v2".utf8))
    let file = try FileManager.default.attributesOfItem(atPath: directory.appending(path: "k").path(percentEncoded: false))
    #expect(file[.posixPermissions] as? Int == 0o600)
    let folder = try FileManager.default.attributesOfItem(atPath: directory.path(percentEncoded: false))
    #expect(folder[.posixPermissions] as? Int == 0o700)
    try store.delete("k")
    try store.delete("k")
    #expect(try store.read("k") == nil)
}

/// The production code path, on a throwaway keychain because the System Keychain needs root.
@Test(.timeLimit(.minutes(1)))
@available(macOS, deprecated: 10.10)
func keychainSecretStoreRoundTrip() throws {
    let path = "/tmp/tender-test-\(UUID().uuidString.prefix(8)).keychain-db"
    let password = "test"
    var created: SecKeychain?
    #expect(SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &created) == errSecSuccess)
    defer {
        if let created { SecKeychainDelete(created) }
        try? FileManager.default.removeItem(atPath: path)
    }
    let store = KeychainSecretStore(keychainPath: path, service: "com.olympsis.tender.test")
    #expect(try store.read("k") == nil)
    try store.write("k", Data("v1".utf8))
    try store.write("k", Data("v2".utf8))
    #expect(try store.read("k") == Data("v2".utf8))
    try store.delete("k")
    try store.delete("k")
    #expect(try store.read("k") == nil)
}

@Test func readsABackupWithOrWithoutANewlineBetweenBlocks() throws {
    let ca = try CertificateAuthority.create()
    for separator in ["", "\n"] {
        let restored = try CertificateAuthority(backupPEM: ca.certificatePEM + separator + ca.privateKeyPEM + "\n")
        #expect(restored.fingerprint == ca.fingerprint)
        #expect(restored.privateKeyPEM == ca.privateKeyPEM)
        _ = try restored.sign(csrPEM: try NodeKey.generate().makeCSR(nodeID: NodeID("n")), nodeID: NodeID("n"))
    }
}

@Test func refusesAKeyFromAnotherCA() throws {
    let ca = try CertificateAuthority.create()
    let other = try CertificateAuthority.create()
    #expect(throws: PKIError.invalidAuthority("the private key doesn't match the certificate")) {
        try CertificateAuthority(certificatePEM: ca.certificatePEM, privateKeyPEM: other.privateKeyPEM)
    }
}

@Test func refusesANodeCertificateAsACA() throws {
    let ca = try CertificateAuthority.create()
    let key = NodeKey.generate()
    let certificate = try ca.sign(csrPEM: try key.makeCSR(nodeID: NodeID("n")), nodeID: NodeID("n"))
    #expect(throws: PKIError.invalidAuthority("the certificate isn't a CA certificate")) {
        try CertificateAuthority(certificatePEM: certificate, privateKeyPEM: key.privateKeyPEM)
    }
}

@Test func refusesABackupMissingItsKey() throws {
    let ca = try CertificateAuthority.create()
    #expect(throws: PKIError.invalidAuthority("the backup has no private key")) {
        try CertificateAuthority(backupPEM: ca.certificatePEM)
    }
}
