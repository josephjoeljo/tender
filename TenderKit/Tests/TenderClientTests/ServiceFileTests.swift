import Foundation
import Testing
import TenderCore
@testable import TenderClient

private let documented = """
    kind: Service
    name: api
    binary: api                       # release from bin/api/
    args: ["--port", 8080]
    cwd: /opt/olympsis/api
    instances: 2
    node: mac-1
    env:
      LOG_LEVEL: info
      MONGO_URL: "mongodb://app:${secret:MONGO_PASSWORD}@10.0.0.3/olympsis"
      JWT_KEY: "${secret:shared/JWT_KEY}"
    secret_files:
      /opt/olympsis/api/gcp.json: GCP_KEY
    user: _olympsis
    ---
    kind: Adopted
    label: homebrew.mxcl.mongodb-community
    node: mac-1
    log_path: /opt/homebrew/var/log/mongodb/mongo.log
    ---
    """

private func parseError(_ yaml: String, directory: URL? = nil) -> String? {
    do {
        _ = try ServiceFile.parse(yaml, directory: directory)
        return nil
    } catch {
        return (error as? ManifestError)?.message ?? "\(error)"
    }
}

private func temporaryDirectory() throws -> URL {
    let url = URL(filePath: "/tmp/tender-test-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func parsesTheDocumentedFormat() throws {
    let manifest = try ServiceFile.parse(documented)
    #expect(manifest.items.count == 2)
    guard case .service(let spec) = manifest.items[0], case .adopted(let job) = manifest.items[1] else {
        Issue.record("expected a service and an adopted job")
        return
    }
    #expect(spec.name == "api")
    #expect(spec.program == .nodeRelease)
    #expect(spec.arguments == ["--port", "8080"])
    #expect(spec.workingDirectory == "/opt/olympsis/api")
    #expect(spec.instances == 2)
    #expect(spec.node == NodeID("mac-1"))
    #expect(spec.environment["JWT_KEY"] == "${secret:shared/JWT_KEY}")
    #expect(spec.environment.count == 3)
    #expect(spec.secretFiles == ["/opt/olympsis/api/gcp.json": "GCP_KEY"])
    #expect(spec.user == "_olympsis")
    #expect(job == AdoptedItem(label: "homebrew.mxcl.mongodb-community", node: NodeID("mac-1"),
                               logPath: "/opt/homebrew/var/log/mongodb/mongo.log"))
}

@Test func defaultsApplyWhenKeysAreLeftOut() throws {
    let manifest = try ServiceFile.parse("kind: Service\nname: web\nexec: /bin/sleep\n")
    #expect(manifest.items == [.service(ServiceSpec(name: "web", program: .executable("/bin/sleep")))])
}

@Test func unknownKeysNameTheKeyAndTheDocument() {
    let message = parseError("kind: Service\nname: a\nexec: /bin/sleep\n---\nkind: Service\nname: api\nexec: /bin/sleep\nevn:\n  A: b\n")
    #expect(message?.hasPrefix("services.yaml, document 2 (api), line 8: unknown key 'evn'.") == true, "\(message ?? "")")
    #expect(message?.contains("Valid keys:") == true)
    #expect(parseError("kind: Adopted\nlabel: x\nlogpath: /x\n")?.contains("unknown key 'logpath'") == true)
    #expect(parseError("kind: Adopted\nlabel: x\nexec: /x\n")?.contains("unknown key 'exec'") == true)
}

@Test(arguments: ["health", "rollout", "replicas", "placement"])
func laterKeysAreNotSupportedYet(key: String) {
    let message = parseError("kind: Service\nname: api\nexec: /bin/sleep\n\(key): 2\n")
    #expect(message?.hasSuffix("'\(key)' is not supported yet.") == true, "\(message ?? "")")
}

@Test func badSecretReferencesAreRejected() {
    #expect(parseError("kind: Service\nname: api\nexec: /bin/sleep\nenv:\n  A: \"${secret:not-valid}\"\n")?.contains("isn't a valid secret reference") == true)
    #expect(parseError("kind: Service\nname: api\nexec: /bin/sleep\nargs: [\"${secret:X\"]\n") != nil)
    #expect(parseError("kind: Service\nname: api\nexec: /bin/sleep\nsecret_files:\n  /k.json: other/KEY\n")?.contains("isn't NAME or shared/NAME") == true)
}

@Test func malformedDocumentsSayWhatIsWrong() {
    let cases: [(String, String)] = [
        ("name: api\nexec: /bin/sleep\n", "missing 'kind'"),
        ("kind: Deployment\nname: api\n", "unknown kind 'Deployment'"),
        ("kind: Service\nname: api\n", "needs 'binary'"),
        ("kind: Service\nname: api\nbinary: api\nexec: /bin/sleep\n", "both 'binary' and 'exec'"),
        ("kind: Service\nname: worker\nbinary: api\n", "binary must be the service's own name"),
        ("kind: Service\nname: api\nexec: /bin/sleep\ninstances: two\n", "whole number"),
        ("kind: Service\nname: api\nexec: /bin/sleep\nargs: --port\n", "must be a list"),
        ("kind: Service\nname: api\nexec: /bin/sleep\nenv:\n  A:\n", "'env.A' must be a string"),
        ("kind: Service\nname: api\nexec: /bin/sleep\nname: web\n", "duplicated key"),
        ("- a\n- b\n", "expected a mapping"),
        ("kind: Service\nname: api\nexec: [unclosed\n", "services.yaml"),
        ("kind: Adopted\nnode: mac-1\n", "missing 'label'"),
    ]
    for (yaml, expected) in cases {
        let message = parseError(yaml)
        #expect(message?.contains(expected) == true, "\(yaml) → \(message ?? "no error")")
    }
}

@Test func envFileIsRelativeToTheFileAndInlineWins() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory.appending(path: "env"), withIntermediateDirectories: true)
    try "LOG_LEVEL=debug\nREGION=us-west1\n".write(to: directory.appending(path: "env/api.env"), atomically: true, encoding: .utf8)
    let yaml = "kind: Service\nname: api\nexec: /bin/sleep\nenv_file: ./env/api.env\nenv:\n  LOG_LEVEL: info\n"
    try yaml.write(to: directory.appending(path: "services.yaml"), atomically: true, encoding: .utf8)

    let loaded = try ServiceFile.load(directory.appending(path: "services.yaml"))
    guard case .service(let spec) = loaded.manifest.items.first else {
        Issue.record("expected a service")
        return
    }
    #expect(spec.environment == ["LOG_LEVEL": "info", "REGION": "us-west1"])
    #expect(loaded.sha256.count == 64)
    #expect(parseError("kind: Service\nname: api\nexec: /bin/sleep\nenv_file: missing.env\n", directory: directory)?.contains("can't read env_file 'missing.env'") == true)
}

@Test func dotEnvHandlesCommentsQuotesAndExport() throws {
    let text = """
        # a comment
        export A=1
        B = two words   # trailing comment
        C="quoted # not a comment\\nnext"
        D='single $${raw} \\n'
          E=
        F="a\\"b"
        URL=postgres://u@h:5432/db?x=1#frag

        """
    #expect(try DotEnv.parse(text) == [
        "A": "1", "B": "two words", "C": "quoted # not a comment\nnext", "D": "single $${raw} \\n",
        "E": "", "F": "a\"b", "URL": "postgres://u@h:5432/db?x=1#frag",
    ])
    for bad in ["NOEQUALS", "1A=x", "A=\"open", "A=\"x\" junk"] {
        #expect(throws: ManifestError.self, "\(bad)") { try DotEnv.parse(bad) }
    }
}

@Test func exportRoundTrips() throws {
    var spec = ServiceSpec(name: "api", program: .release(sha12: "abcdef012345"), arguments: ["--port", "8080", "true", ""],
                           environment: ["MONGO_URL": "mongodb://app:${secret:MONGO_PASSWORD}@db", "QUOTE": "a \"b\" 'c'", "N": "08"],
                           workingDirectory: "/opt/api", instances: 3, node: NodeID("mac-1"),
                           secretFiles: ["/opt/api/gcp.json": "shared/GCP_KEY"])
    spec.user = "_api"
    let web = ServiceSpec(name: "web", program: .executable("/usr/bin/env"), node: NodeID("mac-2"))
    let items: [ManifestItem] = [.service(spec), .service(web),
                                 .adopted(AdoptedItem(label: "homebrew.mxcl.postgresql@18", node: NodeID("mac-1"), logPath: "/var/log/pg.log")),
                                 .adopted(AdoptedItem(label: "homebrew.mxcl.redis", node: NodeID("mac-2")))]
    let yaml = try ServiceFile.render(items)
    #expect(yaml.hasPrefix("---\nkind: Service\nname: api\nbinary: api\n"), "\(yaml)")
    #expect(yaml.contains("${secret:MONGO_PASSWORD}"))

    let parsed = try ServiceFile.parse(yaml).items
    var expected = items
    spec.program = .nodeRelease
    expected[0] = .service(spec)
    #expect(parsed == expected)

    let current = [NodeSpecs(node: NodeID("mac-1"), services: [{ var s = spec; s.program = .release(sha12: "abcdef012345"); return s }()],
                             adopted: [AdoptedItem(label: "homebrew.mxcl.postgresql@18", logPath: "/var/log/pg.log")]),
                   NodeSpecs(node: NodeID("mac-2"), services: [web], adopted: [AdoptedItem(label: "homebrew.mxcl.redis")])]
    #expect(!ManifestDiff.compute(items: parsed, current: current, defaultNode: NodeID("mac-1"), prune: true).hasChanges)
    #expect(try ServiceFile.render([]) == "")
}

@Test func renderedDiffShowsFieldsButNoEnvironmentValues() {
    let diff = ManifestDiff(changes: [
        ManifestChange(action: .create, kind: .service, name: "web", node: NodeID("mac-1")),
        ManifestChange(action: .update, kind: .service, name: "api", node: NodeID("mac-1"), fields: [
            FieldChange(field: "instances", from: "1", to: "2"),
            FieldChange(field: "env.TOKEN", from: "changed", to: "changed"),
            FieldChange(field: "env.NEW", from: nil, to: "added"),
        ]),
        ManifestChange(action: .unchanged, kind: .adopted, name: "homebrew.mxcl.redis", node: NodeID("mac-1")),
        ManifestChange(action: .prune, kind: .service, name: "old", node: NodeID("mac-2")),
    ])
    #expect(ManifestDiffRenderer.render(diff) == """
        + create service web on mac-1
        ~ update service api on mac-1
            instances: 1 -> 2
            env.TOKEN: changed
            env.NEW: added
        - prune service old on mac-2
        1 to create, 1 to update, 1 unchanged, 1 to prune.
        """)
    #expect(ManifestDiffRenderer.render(ManifestDiff(changes: [diff.changes[2]])) == "Nothing to change (1 unchanged).")
}

@Test func theDocumentedExampleParses() throws {
    let example = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../docs/examples/services.yaml").standardizedFileURL
    let manifest = try ServiceFile.load(example).manifest
    #expect(manifest.items.map(\.name) == ["api", "worker", "homebrew.mxcl.mongodb-community", "homebrew.mxcl.postgresql@18"])
    #expect(manifest.items.map(\.kind) == [.service, .service, .adopted, .adopted])
}
