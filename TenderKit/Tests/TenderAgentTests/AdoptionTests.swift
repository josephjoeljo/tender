import Foundation
import LaunchdKit
import Testing
import TenderCore
@testable import TenderAgent
@testable import TenderClient

@Test func adoptionRefusesBadTargets() async throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let adoption = Adoption(environment: env, store: try StateStore(environment: env), launchd: MemoryLaunchd())
    await #expect(throws: AdoptionError.jobNotFound("no.such.job")) { try await adoption.adopt(label: "no.such.job") }
    await #expect(throws: AdoptionError.ownLabel("com.olympsis.tender.agent")) {
        try await adoption.adopt(label: "com.olympsis.tender.agent")
    }
    await #expect(throws: AdoptionError.invalidLabel("a/b")) { try await adoption.adopt(label: "a/b") }
    await #expect(throws: AdoptionError.invalidLabel("")) { try await adoption.adopt(label: "") }
}

@Test func adoptedJobRecordPersists() throws {
    let env = try makeTestEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let store = try StateStore(environment: env)
    let job = AdoptedJob(label: "x.y", domain: "gui/501", plistPath: "/p.plist", stdoutPath: "/o", stderrPath: nil)
    try store.saveAdopted(job)
    try store.saveAdopted(job)
    let reopened = try StateStore(environment: env)
    #expect(try reopened.adoptedJobs() == [job])
    #expect(try reopened.adopted(label: "x.y") == job)
    try reopened.removeAdopted(label: "x.y")
    try reopened.removeAdopted(label: "x.y")
    #expect(try reopened.adoptedJobs().isEmpty)
}

/// A job created outside Tender, in real launchd, driven through the whole API.
@Test func adoptControlsARealJobWithoutTouchingItsPlist() async throws {
    let env = try makeTestEnvironment()
    let launchctl = Launchctl(domain: .currentUser)
    // Adoption refuses Tender's own prefix, so this job can't use the usual
    // com.olympsis.tender.test.* namespace. It is still ours and is cleaned up.
    let jobLabel = "com.olympsis.tender-external.test.\(UUID().uuidString.prefix(8))"
    let plist = env.root.appending(path: "\(jobLabel).plist")
    let out = env.root.appending(path: "external.log")
    try PlistRenderer().render(
        label: jobLabel,
        programArguments: ["/bin/sh", "-c", "echo external-started; exec /bin/sleep 1000"],
        stdoutPath: out.path(percentEncoded: false),
        stderrPath: out.path(percentEncoded: false),
        throttleInterval: 1
    ).write(to: plist)
    let original = try Data(contentsOf: plist)
    try await launchctl.bootstrap(plistURL: plist)
    defer {
        let cleanup = Process()
        cleanup.executableURL = URL(filePath: "/bin/launchctl")
        cleanup.arguments = ["bootout", "\(launchctl.domain.target)/\(jobLabel)"]
        cleanup.standardError = FileHandle.nullDevice
        try? cleanup.run()
        cleanup.waitUntilExit()
        try? FileManager.default.removeItem(at: env.root)
    }

    let runtime = AgentRuntime(environment: env, launchd: launchctl, shutdownSignals: [])
    let daemon = Task { try await runtime.run() }
    defer { daemon.cancel() }
    let socket = env.socketPath.path(percentEncoded: false)
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: socket) {
        try await Task.sleep(for: .milliseconds(50))
    }
    let client = TenderClient(socketPath: socket)

    func status() async throws -> InstanceStatus? {
        try await client.list().processes.first { $0.service == jobLabel }
    }

    _ = try await client.adopt(label: jobLabel)
    let adopted = try #require(try await status())
    #expect(adopted.adopted)
    #expect(adopted.pid != nil)

    // Both paths are the same file: it must not be read twice.
    var tail = try await client.logs(service: jobLabel)
    for _ in 0..<50 where tail.lines.isEmpty {
        try await Task.sleep(for: .milliseconds(100))
        tail = try await client.logs(service: jobLabel)
    }
    #expect(tail.lines.map(\.text) == ["external-started"])

    _ = try await client.restart(service: jobLabel)
    #expect(try await launchctl.print(label: jobLabel) != nil)

    _ = try await client.stop(service: jobLabel)
    _ = try await client.stop(service: jobLabel)
    #expect(try await launchctl.print(label: jobLabel) == nil)
    #expect(try await status()?.state == .stopped)

    _ = try await client.start(service: jobLabel)
    #expect(try await launchctl.print(label: jobLabel) != nil)

    do {
        _ = try await client.delete(service: jobLabel)
        Issue.record("delete must refuse an adopted job")
    } catch let error as TenderClientError {
        #expect(error.code == "adopted_job")
    }

    _ = try await client.forget(label: jobLabel)
    _ = try await client.forget(label: jobLabel)
    #expect(try await status() == nil)
    #expect(try await launchctl.print(label: jobLabel) != nil, "forget must leave the job running")
    #expect(try Data(contentsOf: plist) == original, "the plist must never be rewritten")

    daemon.cancel()
    _ = try? await daemon.value
}
