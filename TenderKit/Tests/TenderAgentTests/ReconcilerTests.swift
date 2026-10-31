import Foundation
import LaunchdKit
import Testing
import TenderCore
@testable import TenderAgent

private actor FakeLaunchd: LaunchdControlling {
    var loaded: Set<String> = []
    var calls: [String] = []
    var failBootout = false

    func setLoaded(_ labels: Set<String>) { loaded = labels }
    func setFailBootout(_ value: Bool) { failBootout = value }
    func resetCalls() { calls = [] }

    func bootstrap(plistURL: URL) async throws {
        let label = plistURL.deletingPathExtension().lastPathComponent
        calls.append("bootstrap \(label)")
        loaded.insert(label)
    }
    func bootout(label: String) async throws {
        calls.append("bootout \(label)")
        if failBootout { throw LaunchctlError.ioError("boom") }
        guard loaded.remove(label) != nil else { throw LaunchctlError.notFound(label) }
    }
    func kickstart(label: String, kill: Bool) async throws { calls.append("kickstart \(label)") }
    func enable(label: String) async throws {}
    func disable(label: String) async throws {}
    func print(label: String) async throws -> JobInfo? {
        loaded.contains(label) ? JobInfo(output: "x/\(label) = {\n\tstate = running\n\tpid = 42\n\truns = 3\n}\n") : nil
    }
    func listLabels(prefix: String) async throws -> [String] { loaded.filter { $0.hasPrefix(prefix) }.sorted() }
}

private struct Harness {
    let env: TenderEnvironment
    let store: StateStore
    let launchd = FakeLaunchd()
    let reconciler: Reconciler

    init() throws {
        env = try makeTestEnvironment()
        store = try StateStore(environment: env)
        reconciler = Reconciler(environment: env, store: store, launchd: launchd)
    }

    func label(_ service: String = "api", _ instance: Int = 0) -> String {
        env.serviceLabel(service: service, instance: instance)
    }
    func cleanup() { try? FileManager.default.removeItem(at: env.root) }
}

private let spec = ServiceSpec(name: "api", program: .executable("/bin/sleep"), arguments: ["1000"])

// MARK: Planning

private func record(_ desired: DesiredState) -> InstanceRecord {
    InstanceRecord(service: "api", instance: 0, label: "l", desired: desired)
}
private let plistA = Data("a".utf8)
private let plistB = Data("b".utf8)

@Test func planInstallsMissingJob() {
    let actions = Reconciler.plan(desired: [.init(record: record(.running), plist: plistA)],
                                  observed: .init(loadedLabels: [], plists: [:]))
    #expect(actions == [.install(label: "l", plist: plistA)])
}

@Test func planDoesNothingWhenInSync() {
    let actions = Reconciler.plan(desired: [.init(record: record(.running), plist: plistA)],
                                  observed: .init(loadedLabels: ["l"], plists: ["l": plistA]))
    #expect(actions.isEmpty)
}

@Test func planReplacesJobWhosePlistChanged() {
    let actions = Reconciler.plan(desired: [.init(record: record(.running), plist: plistB)],
                                  observed: .init(loadedLabels: ["l"], plists: ["l": plistA]))
    #expect(actions == [.replace(label: "l", plist: plistB)])
}

@Test func planBootsOutStoppedJob() {
    let actions = Reconciler.plan(desired: [.init(record: record(.stopped), plist: nil)],
                                  observed: .init(loadedLabels: ["l"], plists: ["l": plistA]))
    #expect(actions == [.bootout(label: "l"), .removePlist(label: "l")])
    #expect(Reconciler.plan(desired: [.init(record: record(.stopped), plist: nil)],
                            observed: .init(loadedLabels: [], plists: [:])).isEmpty)
}

@Test func planRemovesAbsentInstance() {
    let actions = Reconciler.plan(desired: [.init(record: record(.absent), plist: nil)],
                                  observed: .init(loadedLabels: ["l"], plists: [:]))
    #expect(actions == [.bootout(label: "l"), .forget(service: "api", instance: 0)])
}

// MARK: Applying

@Test func reconcileInstallsOnceThenIsIdempotent() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.store.upsert(spec)

    let first = try await h.reconciler.reconcile()
    #expect(first.applied.count == 1)
    #expect(first.failures.isEmpty)
    #expect(FileManager.default.fileExists(atPath: h.env.plistPath(label: h.label()).path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: h.env.logDirectory(service: "api").path(percentEncoded: false)))

    await h.launchd.resetCalls()
    let second = try await h.reconciler.reconcile()
    #expect(second.applied.isEmpty)
    #expect(await h.launchd.calls.isEmpty)
}

@Test func changedSpecReplacesTheJob() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.store.upsert(spec)
    try await h.reconciler.reconcile()
    await h.launchd.resetCalls()

    var changed = spec
    changed.arguments = ["2000"]
    try h.store.upsert(changed)
    try await h.reconciler.reconcile()
    #expect(await h.launchd.calls == ["bootout \(h.label())", "bootstrap \(h.label())"])
}

@Test func stopThenDeleteRemovesEverything() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.store.upsert(spec)
    try await h.reconciler.reconcile()

    try h.store.setDesired(.stopped, service: "api")
    try await h.reconciler.reconcile()
    #expect(await h.launchd.loaded.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: h.env.plistPath(label: h.label()).path(percentEncoded: false)))
    #expect(try await h.reconciler.status().processes.map(\.state) == [.stopped])

    try h.store.deleteService("api")
    try await h.reconciler.reconcile()
    #expect(try h.store.instances().isEmpty)
    #expect(try await h.reconciler.status().processes.isEmpty)
}

@Test func failedBootoutKeepsTheRowForTheNextSweep() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.store.upsert(spec)
    try await h.reconciler.reconcile()
    try h.store.deleteService("api")

    await h.launchd.setFailBootout(true)
    let failed = try await h.reconciler.reconcile()
    #expect(failed.failures.map(\.label) == [h.label()])
    #expect(try h.store.instances().count == 1)

    await h.launchd.setFailBootout(false)
    let retried = try await h.reconciler.reconcile()
    #expect(retried.failures.isEmpty)
    #expect(try h.store.instances().isEmpty)
}

@Test func orphansAreReportedButNotTouched() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let orphan = h.label("ghost")
    await h.launchd.setLoaded([orphan, "com.apple.other"])

    let report = try await h.reconciler.reconcile()
    #expect(report.orphans == [orphan])
    #expect(report.applied.isEmpty)
    #expect(await h.launchd.loaded.contains(orphan))
    #expect(try await h.reconciler.status().orphans == [orphan])
}

@Test func restartKickstartsOnlyAlreadyLoadedInstances() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.store.upsert(spec)
    try await h.reconciler.restart(service: "api")
    #expect(!(await h.launchd.calls.contains("kickstart \(h.label())")))

    try await h.reconciler.restart(service: "api")
    #expect(await h.launchd.calls.contains("kickstart \(h.label())"))
}

@Test func statusReportsLaunchdFacts() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    try h.store.upsert(ServiceSpec(name: "api", program: .release(sha12: "abc123")))
    try await h.reconciler.reconcile()
    let status = try #require(try await h.reconciler.status().processes.first)
    #expect(status.state == .running)
    #expect(status.pid == 42)
    #expect(status.restarts == 2)
    #expect(status.release == "abc123")
}

@Test func devModeOmitsUserNameAndProductionSetsIt() async throws {
    let h = try Harness()
    defer { h.cleanup() }
    let dev = try await h.reconciler.renderPlist(spec: spec, instance: 0)
    let devPlist = try #require(try PropertyListSerialization.propertyList(from: dev, format: nil) as? [String: Any])
    #expect(devPlist["UserName"] == nil)
    #expect(devPlist["ProgramArguments"] as? [String] == ["/bin/sleep", "1000"])

    let prod = Reconciler(environment: .production, store: h.store, launchd: h.launchd)
    let data = try await prod.renderPlist(spec: spec, instance: 0)
    let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    #expect(plist["UserName"] as? String == "_tender")
}

// MARK: Real launchd

@Test func reconcilesRealLaunchdJobs() async throws {
    let env = try makeTestEnvironment()
    let store = try StateStore(environment: env)
    let launchctl = Launchctl(domain: .currentUser)
    let reconciler = Reconciler(environment: env, store: store, launchd: launchctl, throttleInterval: 1)
    let label = env.serviceLabel(service: "sleeper", instance: 0)
    defer {
        let cleanup = Process()
        cleanup.executableURL = URL(filePath: "/bin/launchctl")
        cleanup.arguments = ["bootout", "\(launchctl.domain.target)/\(label)"]
        cleanup.standardError = FileHandle.nullDevice
        try? cleanup.run()
        cleanup.waitUntilExit()
        try? FileManager.default.removeItem(at: env.root)
    }

    try store.upsert(ServiceSpec(name: "sleeper", program: .executable("/bin/sleep"), arguments: ["1000"]))
    #expect(try await reconciler.reconcile().failures.isEmpty)
    #expect(try await reconciler.reconcile().applied.isEmpty)
    #expect(try await launchctl.print(label: label) != nil)

    try store.deleteService("sleeper")
    #expect(try await reconciler.reconcile().failures.isEmpty)
    #expect(try await launchctl.print(label: label) == nil)
    #expect(try store.instances().isEmpty)
}
