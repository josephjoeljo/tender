import Foundation
import Testing
import TenderAgent
import TenderCore
import TenderPKI
@testable import TenderHead

private func makeStore() -> FileSecretStore {
    FileSecretStore(directory: FileManager.default.temporaryDirectory.appending(path: "tender-ca-\(UUID().uuidString)"))
}

private func backup(of authority: CertificateAuthority) -> String {
    authority.certificatePEM + "\n" + authority.privateKeyPEM + "\n"
}

@Test func firstStartCreatesACAAndLaterStartsLoadIt() throws {
    let store = makeStore()
    let created = try HeadServices.loadOrCreateAuthority(secrets: store)
    #expect(try HeadServices.loadOrCreateAuthority(secrets: store).fingerprint == created.fingerprint)
}

@Test func aMissingKeyIsRefusedAndTheCertificateKept() throws {
    let store = makeStore()
    let created = try HeadServices.loadOrCreateAuthority(secrets: store)
    try store.delete(ClusterSecrets.caKey)
    #expect(throws: AuthorityStoreError.incomplete(missing: ClusterSecrets.caKey)) {
        try HeadServices.loadOrCreateAuthority(secrets: store)
    }
    #expect(try store.read(ClusterSecrets.caCertificate) == Data(created.certificatePEM.utf8))
    #expect(try store.read(ClusterSecrets.caKey) == nil)
}

@Test func aMissingCertificateIsRefusedAndTheKeyKept() throws {
    let store = makeStore()
    let created = try HeadServices.loadOrCreateAuthority(secrets: store)
    try store.delete(ClusterSecrets.caCertificate)
    #expect(throws: AuthorityStoreError.incomplete(missing: ClusterSecrets.caCertificate)) {
        try HeadServices.loadOrCreateAuthority(secrets: store)
    }
    #expect(try store.read(ClusterSecrets.caKey) == Data(created.privateKeyPEM.utf8))
}

@Test func aBackupRepairsHalfACA() throws {
    let store = makeStore()
    let created = try HeadServices.loadOrCreateAuthority(secrets: store)
    try store.delete(ClusterSecrets.caKey)
    try HeadServices.restoreAuthority(backupPEM: backup(of: created), secrets: store, replace: false)
    #expect(try HeadServices.loadOrCreateAuthority(secrets: store).fingerprint == created.fingerprint)
}

@Test func aDifferentCANeedsReplace() throws {
    let store = makeStore()
    let current = try HeadServices.loadOrCreateAuthority(secrets: store)
    let other = try CertificateAuthority.create()
    #expect(throws: AuthorityStoreError.differentAuthority(backup: other.fingerprint)) {
        try HeadServices.restoreAuthority(backupPEM: backup(of: other), secrets: store, replace: false)
    }
    #expect(try HeadServices.loadOrCreateAuthority(secrets: store).fingerprint == current.fingerprint)

    try HeadServices.restoreAuthority(backupPEM: backup(of: other), secrets: store, replace: true)
    #expect(try HeadServices.loadOrCreateAuthority(secrets: store).fingerprint == other.fingerprint)
}

@Test func aBadBackupChangesNothing() throws {
    let store = makeStore()
    let current = try HeadServices.loadOrCreateAuthority(secrets: store)
    #expect(throws: PKIError.self) {
        try HeadServices.restoreAuthority(backupPEM: "not a backup", secrets: store, replace: true)
    }
    #expect(try HeadServices.loadOrCreateAuthority(secrets: store).fingerprint == current.fingerprint)
}
