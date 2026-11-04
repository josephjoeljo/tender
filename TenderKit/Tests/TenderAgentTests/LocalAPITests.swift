import Foundation
import LaunchdKit
import LogTail
import Testing
import TenderCore
@testable import TenderAgent
@testable import TenderClient

/// In-memory launchd: the API tests are about HTTP, not launchctl.
actor MemoryLaunchd: LaunchdControlling {
    var loaded: Set<String> = []
    func bootstrap(plistURL: URL) async throws { loaded.insert(plistURL.deletingPathExtension().lastPathComponent) }
    func bootout(label: String) async throws {
        guard loaded.remove(label) != nil else { throw LaunchctlError.notFound(label) }
    }
    func kickstart(label: String, kill: Bool) async throws {}
    func enable(label: String) async throws {}
    func disable(label: String) async throws {}
    func print(label: String) async throws -> JobInfo? {
        loaded.contains(label) ? JobInfo(output: "x/\(label) = {\n\tstate = running\n\tpid = 42\n\truns = 1\n}\n") : nil
    }
    func listLabels(prefix: String) async throws -> [String] { loaded.filter { $0.hasPrefix(prefix) }.sorted() }
}

/// Runs a daemon on a temp socket for the duration of `body`.
private func withDaemon(launchd: MemoryLaunchd = MemoryLaunchd(),
                        _ body: (TenderClient, TenderEnvironment) async throws -> Void) async throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let runtime = AgentRuntime(environment: env, launchd: launchd, shutdownSignals: [])
    let daemon = Task { try await runtime.run() }
    defer { daemon.cancel() }

    let socket = env.socketPath.path(percentEncoded: false)
    for _ in 0..<100 {
        if let mode = try? FileManager.default.attributesOfItem(atPath: socket)[.posixPermissions] as? Int,
           mode == 0o600 { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    try await body(TenderClient(socketPath: socket), env)
    daemon.cancel()
    _ = try? await daemon.value
}

private let sleeper = ServiceSpec(name: "api", program: .executable("/bin/sleep"), arguments: ["1000"])

@Test func namesWithDashesWorkOverTheSocket() async throws {
    try await withDaemon { client, _ async throws in
        var spec = sleeper
        spec.name = "my-api_2"
        _ = try await client.start(spec)
        #expect(try await client.stop(service: "my-api_2").processes.map(\.state) == [.stopped])
        #expect(try await client.delete(service: "my-api_2").processes.isEmpty)
    }
}

@Test func socketIsPrivate() async throws {
    try await withDaemon { _, env async throws in
        let attributes = try FileManager.default.attributesOfItem(atPath: env.socketPath.path(percentEncoded: false))
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(attributes[.type] as? FileAttributeType == .typeSocket)
        let run = try FileManager.default.attributesOfItem(atPath: env.runDirectory.path(percentEncoded: false))
        #expect(run[.posixPermissions] as? Int == 0o700)
    }
}

@Test func lifecycleOverTheSocketIsIdempotent() async throws {
    try await withDaemon { client, _ async throws in
        #expect(try await client.list().processes.isEmpty)

        #expect(try await client.start(sleeper).processes.map(\.state) == [.running])
        #expect(try await client.start(sleeper).processes.count == 1)
        #expect(try await client.list().processes.first?.pid == 42)

        #expect(try await client.restart(service: "api").processes.map(\.state) == [.running])

        #expect(try await client.stop(service: "api").processes.map(\.state) == [.stopped])
        #expect(try await client.stop(service: "api").processes.map(\.state) == [.stopped])
        #expect(try await client.start(service: "api").processes.map(\.state) == [.running])

        #expect(try await client.delete(service: "api").processes.isEmpty)
        #expect(try await client.delete(service: "api").processes.isEmpty)
    }
}

private func apiErrorCode(_ call: () async throws -> ProcessList) async -> String? {
    do {
        _ = try await call()
        return nil
    } catch {
        return (error as? TenderClientError)?.code
    }
}

/// Homebrew labels contain `@`, which the client percent-encodes in the path.
@Test func adoptedLabelsWithAtSignsWorkOverTheSocket() async throws {
    let launchd = MemoryLaunchd()
    let label = "homebrew.mxcl.postgresql@18"
    try await launchd.bootstrap(plistURL: URL(filePath: "/tmp/\(label).plist"))
    try await withDaemon(launchd: launchd) { client, _ async throws in
        #expect(try await client.adopt(label: label).processes.map(\.service) == [label])
        #expect(await apiErrorCode { try await client.delete(service: label) } == "adopted_job")
        #expect(try await client.stop(service: label).processes.map(\.state) == [.stopped])
        #expect(try await client.forget(label: label).processes.isEmpty)
        #expect(await apiErrorCode { try await client.forget(label: label) } == "not_adopted")
    }
}

/// Decoding a path parameter must not smuggle in what percent-encoding hid.
@Test func decodedPathParametersRefuseSlashesAndControlCharacters() async throws {
    try await withDaemon { client, _ async throws in
        for name in ["a/b", "../x", "a\u{0}b", "a\nb", "a\u{7F}b"] {
            #expect(await apiErrorCode { try await client.stop(service: name) } == "bad_request", "\(name)")
            #expect(await apiErrorCode { try await client.forget(label: name) } == "bad_request", "\(name)")
        }
        #expect(await apiErrorCode { try await client.stop(service: "nope@1") } == "service_not_found")
    }
}

@Test func rejectsBadRequests() async throws {
    try await withDaemon { client, _ async throws in
        #expect(await apiErrorCode { try await client.stop(service: "nope") } == "service_not_found")
        #expect(await apiErrorCode { try await client.restart(service: "nope") } == "service_not_found")

        var bad = sleeper
        bad.name = "../evil"
        #expect(await apiErrorCode { try await client.start(bad) } == "invalid_name")
        bad = sleeper
        bad.program = .executable("/does/not/exist")
        #expect(await apiErrorCode { try await client.start(bad) } == "invalid_executable")
        bad.program = .executable("relative/path")
        #expect(await apiErrorCode { try await client.start(bad) } == "invalid_executable")
        bad = sleeper
        bad.user = "root"
        #expect(await apiErrorCode { try await client.start(bad) } == "invalid_user")
        bad = sleeper
        bad.instances = 0
        #expect(await apiErrorCode { try await client.start(bad) } == "invalid_instances")

        let (status, _) = try await client.perform(.POST, "/v1/processes", body: Data("nonsense".utf8))
        #expect(status == 400)
    }
}

@Test func logsOverTheSocket() async throws {
    try await withDaemon { client, env async throws in
        _ = try await client.start(sleeper)
        let directory = env.logDirectory(service: "api")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let out = env.stdoutLog(service: "api", instance: 0)
        try Data("o1\no2\no3\n".utf8).write(to: out)
        try Data("e1\n".utf8).write(to: env.stderrLog(service: "api", instance: 0))

        let tail = try await client.logs(service: "api", lines: 2)
        #expect(tail.lines.map(\.text) == ["o2", "o3", "e1"])
        #expect(tail.lines.last?.stream == .err)
        #expect(try await client.logs(service: "api", stream: .err).lines.map(\.text) == ["e1"])
        #expect(try await client.logs(service: "api", instance: 9).lines.isEmpty)

        var iterator = client.followLogs(service: "api", lines: 1, stream: .out).makeAsyncIterator()
        #expect(try await iterator.next()?.text == "o3")
        let handle = try FileHandle(forWritingTo: out)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("live\n".utf8))
        try handle.close()
        #expect(try await iterator.next()?.text == "live")
    }
}

@Test func logsForUnknownServiceFail() async throws {
    try await withDaemon { client, _ async throws in
        do {
            _ = try await client.logs(service: "nope")
            Issue.record("expected an error")
        } catch let error as TenderClientError {
            #expect(error.code == "service_not_found")
        }
    }
}

@Test func rotationServiceRotatesManagedLogs() throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let store = try StateStore(environment: env)
    try store.upsert(sleeper)
    try FileManager.default.createDirectory(at: env.logDirectory(service: "api"), withIntermediateDirectories: true)
    let out = env.stdoutLog(service: "api", instance: 0)
    try Data("0123456789".utf8).write(to: out)

    try LogRotationService(environment: env, store: store, rotator: LogRotator(maxBytes: 5, keep: 1)).rotateAll()
    #expect(try Data(contentsOf: out).isEmpty)
    #expect(FileManager.default.fileExists(atPath: out.path(percentEncoded: false) + ".1"))
}

@Test func releasesOverTheSocket() async throws {
    try await withDaemon { client, _ async throws in
        #expect(try await client.releases(service: "api").releases.isEmpty)
        _ = try await client.start(sleeper)
        #expect(await apiErrorCode { try await client.rollback(service: "api") } == "no_previous_release")
        #expect(await apiErrorCode { try await client.rollback(service: "api", to: "abc") } == "release_not_found")
        #expect(await apiErrorCode { try await client.rollback(service: "nope") } == "service_not_found")
    }
}

@Test func secondDaemonIsRefused() async throws {
    try await withDaemon { _, env async throws in
        let second = AgentRuntime(environment: env, launchd: MemoryLaunchd(), shutdownSignals: [])
        await #expect(throws: AgentRuntimeError.self) { try await second.run() }
    }
}

@Test func unreachableDaemonHasAClearError() async {
    let client = TenderClient(socketPath: "/tmp/tender-test-no-such.sock")
    #expect(await apiErrorCode { try await client.list() } == "daemon_unreachable")
}

@Test func socketPathResolution() {
    #expect(TenderClient.defaultSocketPath(environment: ["TENDER_SOCKET": "/x.sock"]) == "/x.sock")
}

@Test func tableRendersMissingValuesAndOrphans() {
    let node = NodeID("n")
    let table = ProcessTable.render(ProcessList(processes: [
        InstanceStatus(service: "api", instance: 0, node: node, state: .running, pid: 7, uptime: 3700,
                       restarts: 2, release: "abc", cpu: 1.25, rss: 5 << 20),
        InstanceStatus(service: "web", instance: 1, node: node, state: .stopped),
    ], orphans: ["com.olympsis.tender.svc.ghost.0"]))
    let lines = table.split(separator: "\n").map(String.init)
    #expect(lines[0].hasPrefix("SERVICE"))
    #expect(lines[1].split(separator: " ").map(String.init)
        == ["api", "n", "0", "running", "7", "1h1m", "1.2%", "5.0M", "2", "abc"])
    #expect(lines[2].split(separator: " ").map(String.init) == ["web", "n", "1", "stopped", "-", "-", "-", "-", "0", "-"])
    #expect(table.contains("com.olympsis.tender.svc.ghost.0"))
    #expect(ProcessTable.render(ProcessList(processes: [])) == "No processes.")
}
