import Foundation
import Testing
import TenderCore

@Test func templatesFindServiceAndSharedReferences() throws {
    let refs = try SecretTemplate.references(in: "mongodb://app:${secret:MONGO_PASSWORD}@db/${secret:shared/DB_NAME}")
    #expect(refs == [SecretRef(name: "MONGO_PASSWORD"), SecretRef(name: "DB_NAME", shared: true)])
    #expect(refs.map(\.description) == ["MONGO_PASSWORD", "shared/DB_NAME"])
}

@Test func templatesRenderEscapesAndLeaveOtherDollarsAlone() throws {
    let values = ["X": "1", "shared/Y": "2"]
    let render = { (text: String) in try SecretTemplate.render(text) { values[$0.description] } }
    #expect(try render("a${secret:X}b${secret:shared/Y}c") == "a1b2c")
    #expect(try render("$${secret:X}") == "${secret:X}")
    #expect(try render("${HOME} $PATH $") == "${HOME} $PATH $")
    #expect(try render("plain") == "plain")
}

@Test(arguments: ["${secret:}", "${secret:1ABC}", "${secret:A-B}", "${secret:A", "${secret:shared/}", "${secret:other/X}"])
func malformedReferencesAreRejected(text: String) {
    #expect(throws: SecretTemplateError.self) { try SecretTemplate.references(in: text) }
}

@Test func aMissingValueNamesTheSecret() {
    #expect(throws: SecretTemplateError.missing(SecretRef(name: "GONE"))) {
        try SecretTemplate.render("${secret:GONE}") { _ in nil }
    }
}

@Test func onlyTemplatedSpecsNeedTheWrapper() throws {
    var spec = ServiceSpec(name: "api", program: .executable("/bin/sleep"), arguments: ["1"], environment: ["A": "b"])
    #expect(!spec.usesSecretTemplates)
    spec.environment["URL"] = "x${secret:PASS}"
    spec.arguments.append("--key=${secret:shared/KEY}")
    #expect(spec.usesSecretTemplates)
    #expect(try spec.secretRefs().map(\.description) == ["PASS", "shared/KEY"])
}

@Test func secretNamesRoundTripThroughPathsAndItems() throws {
    let service = try #require(SecretName(path: "api/MONGO_PASSWORD"))
    #expect(service.itemName == "svc.api.MONGO_PASSWORD")
    #expect(SecretName(itemName: service.itemName) == service)
    let shared = try #require(SecretName(path: "shared/JWT_KEY"))
    #expect(shared.scope == .shared && shared.itemName == "shared.JWT_KEY")
    #expect(SecretName(itemName: "shared.JWT_KEY") == shared)
    #expect(shared.description == "shared/JWT_KEY")
    for bad in ["api", "api/", "/X", "api/X/Y", "../X", "api/X.Y", "ap i/X"] {
        #expect(SecretName(path: bad) == nil)
    }
    #expect(SecretName(itemName: "ca.key") == nil)
}

// MARK: GCP references

@Test func gcpReferencesParseInEveryForm() throws {
    let cases: [(String, GCPSecretRef, String)] = [
        ("gcp:DB_PASSWORD", GCPSecretRef(secret: "DB_PASSWORD"), "gcp:DB_PASSWORD"),
        ("gcp:DB_PASSWORD@4", GCPSecretRef(secret: "DB_PASSWORD", version: "4"), "gcp:DB_PASSWORD@4"),
        ("gcp:db-password@latest", GCPSecretRef(secret: "db-password"), "gcp:db-password"),
        ("gcp:projects/olympsis-prod/secrets/jwt", GCPSecretRef(project: "olympsis-prod", secret: "jwt"),
         "gcp:projects/olympsis-prod/secrets/jwt"),
        ("gcp:projects/123456789/secrets/jwt@12", GCPSecretRef(project: "123456789", secret: "jwt", version: "12"),
         "gcp:projects/123456789/secrets/jwt@12"),
    ]
    for (body, expected, description) in cases {
        let ref = try #require(SecretRef(parsing: body), "\(body)")
        #expect(ref.gcp == expected)
        #expect(ref.description == description)
        #expect(ref.secretName(service: "api") == nil)
        #expect(SecretRef(parsing: ref.description) == ref, "descriptions parse back to the same reference")
    }
    let refs = try SecretTemplate.references(in: "u=${secret:gcp:USER}&p=${secret:gcp:projects/p-1/secrets/PASS@3}&l=${secret:LOCAL}")
    #expect(refs.map(\.description) == ["gcp:USER", "gcp:projects/p-1/secrets/PASS@3", "LOCAL"])
    // `gcp` alone is an ordinary local name.
    #expect(SecretRef(parsing: "gcp") == SecretRef(name: "gcp"))
}

@Test(arguments: ["${secret:gcp:}", "${secret:gcp:a b}", "${secret:gcp:X@}", "${secret:gcp:X@0}", "${secret:gcp:X@04}",
                  "${secret:gcp:X@v1}", "${secret:gcp:X@1@2}", "${secret:gcp:projects/P/secrets/S}",
                  "${secret:gcp:projects//secrets/S}", "${secret:gcp:projects/p/secrets/}", "${secret:gcp:projects/p/S}",
                  "${secret:gcp:projects/p/secrets/S/versions/1}", "${secret:gcp:a/b}", "${secret:gcp:x.y}",
                  "${secret:gcp:projects/-p/secrets/S}"])
func malformedGCPReferencesAreRejected(text: String) {
    #expect(throws: SecretTemplateError.self) { try SecretTemplate.references(in: text) }
}

@Test func gcpReferencesResolveToCacheItems() throws {
    let unqualified = try #require(SecretRef(parsing: "gcp:JWT"))
    #expect(unqualified.itemName(service: "api", defaultProject: nil) == nil)
    #expect(unqualified.itemName(service: "api", defaultProject: "prod") == "gcp.prod.JWT.latest")
    let pinned = try #require(SecretRef(parsing: "gcp:projects/other/secrets/JWT@7"))
    #expect(pinned.itemName(service: "api", defaultProject: "prod") == "gcp.other.JWT.7")
    let version = try #require(pinned.gcp?.resolved(defaultProject: nil))
    #expect(version.description == "projects/other/secrets/JWT@7")
    #expect(!version.isLatest)
    #expect(GCPSecretVersion(itemName: version.itemName) == version)
    for item in ["gcp.a.b", "gcp.a.b.c.d", "svc.api.X", "gcp.P.b.latest", "gcp.a.b.0"] {
        #expect(GCPSecretVersion(itemName: item) == nil, "\(item)")
    }
    #expect(SecretName(itemName: version.itemName) == nil, "cache items are never taken for local secrets")
    #expect(SecretRef(name: "X").itemName(service: "api", defaultProject: "prod") == "svc.api.X")
}

// MARK: Secret files

@Test func secretFilesCountAsReferences() throws {
    var spec = ServiceSpec(name: "api", program: .executable("/bin/sleep"), arguments: ["1"])
    spec.secretFiles = ["/opt/api/gcp.json": "GCP_KEY", "/opt/api/tls.key": "gcp:projects/p/secrets/tls@2"]
    #expect(spec.usesSecretTemplates)
    #expect(try spec.secretRefs().map(\.description) == ["GCP_KEY", "gcp:projects/p/secrets/tls@2"])
    #expect(try spec.parsedSecretFiles().map(\.path) == ["/opt/api/gcp.json", "/opt/api/tls.key"])
    spec.secretFiles["/opt/api/bad"] = "${secret:X}"
    #expect(throws: SecretTemplateError.malformed("${secret:X}")) { try spec.secretRefs() }
}

@Test func secretFilePathsMustBeAbsoluteAndNormal() {
    for good in ["/opt/api/gcp.json", "/a", "/opt/api/key=with=equals", "/Users/me/Library/Application Support/x"] {
        #expect(ServiceSpec.isValidSecretFilePath(good), "\(good)")
    }
    for bad in ["", "/", "relative/key", "./key", "/opt/../etc/passwd", "/opt/./key", "/opt//key", "/opt/api/",
                "/opt/a\nb", "/opt/\u{7f}", "/" + String(repeating: "a", count: 1024)] {
        #expect(!ServiceSpec.isValidSecretFilePath(bad), "\(bad)")
    }
}

@Test func secretListsFromBeforeGCPStillDecode() throws {
    let old = Data(#"{"secrets":[],"missing":["api: X"],"unreachableNodes":[]}"#.utf8)
    let list = try JSONDecoder().decode(SecretList.self, from: old)
    #expect(list.missing == ["api: X"] && list.gcp.isEmpty)
    let info = GCPSecretInfo(name: "projects/p/secrets/s@latest", node: NodeID("n"), cached: true, fetchError: "down")
    #expect(info.stale)
    let encoded = String(decoding: try JSONEncoder().encode(info), as: UTF8.self)
    #expect(encoded.contains(#""stale":true"#))
}
