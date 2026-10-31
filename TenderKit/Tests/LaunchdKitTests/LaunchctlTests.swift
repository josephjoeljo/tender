import Foundation
import Testing
@testable import LaunchdKit

/// Answers with scripted results and records what it was asked.
private final class ScriptedRunner: LaunchctlRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [CommandResult]
    private var recorded: [[String]] = []

    init(_ results: [CommandResult]) { self.results = results }

    var calls: [[String]] { lock.withLock { recorded } }

    func run(_ arguments: [String]) async throws -> CommandResult {
        lock.withLock {
            recorded.append(arguments)
            return results.isEmpty ? CommandResult(exitCode: 0) : results.removeFirst()
        }
    }
}

private func tool(_ results: CommandResult...) -> (Launchctl, ScriptedRunner) {
    let runner = ScriptedRunner(results)
    return (Launchctl(domain: .user(uid: 501), runner: runner), runner)
}

@Test func buildsExpectedCommands() async throws {
    let (launchctl, runner) = tool()
    try await launchctl.bootout(label: "l")
    try await launchctl.kickstart(label: "l", kill: true)
    try await launchctl.kickstart(label: "l", kill: false)
    try await launchctl.enable(label: "l")
    try await launchctl.disable(label: "l")
    try await launchctl.bootstrap(plistURL: URL(filePath: "/tmp/l.plist"))
    #expect(runner.calls == [
        ["bootout", "gui/501/l"],
        ["kickstart", "-k", "gui/501/l"],
        ["kickstart", "gui/501/l"],
        ["enable", "gui/501/l"],
        ["disable", "gui/501/l"],
        ["bootstrap", "gui/501", "/tmp/l.plist"],
    ])
    #expect(LaunchdDomain.system.target == "system")
}

@Test func mapsFailuresToTypedErrors() {
    func map(_ code: Int32, _ err: String = "") -> LaunchctlError {
        .from(CommandResult(exitCode: code, stderr: err), target: "t")
    }
    #expect(map(113) == .notFound("t"))
    #expect(map(3, "Boot-out failed: 3: No such process") == .notFound("t"))
    #expect(map(37) == .alreadyLoaded("t"))
    #expect(map(5, "Bootstrap failed: 5: Input/output error") == .ioError("Bootstrap failed: 5: Input/output error"))
    #expect(map(1) == .permissionDenied(""))
    #expect(map(9, "Operation not permitted") == .permissionDenied("Operation not permitted"))
    #expect(map(99, "odd") == .failed(exitCode: 99, message: "odd"))
}

@Test func printReturnsNilWhenJobIsMissing() async throws {
    let (launchctl, _) = tool(CommandResult(exitCode: 113, stderr: "Could not find service"))
    #expect(try await launchctl.print(label: "l") == nil)
}

@Test func printPropagatesOtherFailures() async throws {
    let (launchctl, _) = tool(CommandResult(exitCode: 1, stderr: "nope"))
    await #expect(throws: LaunchctlError.permissionDenied("nope")) {
        try await launchctl.print(label: "l")
    }
}

@Test func bootoutThrowsNotFoundAndToleratesInProgress() async throws {
    let (missing, _) = tool(CommandResult(exitCode: 3))
    await #expect(throws: LaunchctlError.notFound("gui/501/l")) { try await missing.bootout(label: "l") }
    let (inProgress, _) = tool(CommandResult(exitCode: 36))
    try await inProgress.bootout(label: "l")
}

@Test func bootstrapIOErrorIsAlreadyLoadedOnlyIfJobExists() async throws {
    let plist = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).plist")
    try PlistRenderer().render(label: "l", programArguments: ["/bin/true"], stdoutPath: "/o", stderrPath: "/e")
        .write(to: plist)
    defer { try? FileManager.default.removeItem(at: plist) }

    let (loaded, _) = tool(CommandResult(exitCode: 5, stderr: "io"), CommandResult(exitCode: 0, stdout: "x = {\n}\n"))
    await #expect(throws: LaunchctlError.alreadyLoaded("l")) { try await loaded.bootstrap(plistURL: plist) }

    let (broken, _) = tool(CommandResult(exitCode: 5, stderr: "io"), CommandResult(exitCode: 113))
    await #expect(throws: LaunchctlError.ioError("io")) { try await broken.bootstrap(plistURL: plist) }
}

@Test func listLabelsFiltersByPrefix() async throws {
    let output = """
    gui/501 = {
    \tservices = {
    \t\t  12  -  \tcom.olympsis.tender.svc.b.0
    \t\t   0  0  \tcom.apple.x
    \t\t   0  -  \tcom.olympsis.tender.svc.a.0
    \t}
    \tdisabled services = {
    \t\t"com.olympsis.tender.svc.z.0" => disabled
    \t}
    }
    """
    let (launchctl, _) = tool(CommandResult(exitCode: 0, stdout: output))
    #expect(try await launchctl.listLabels(prefix: "com.olympsis.tender.svc.")
        == ["com.olympsis.tender.svc.a.0", "com.olympsis.tender.svc.b.0"])
}

@Test func realRunnerCapturesOutputAndExitCode() async throws {
    let result = try await ProcessLaunchctlRunner().run(["print", "gui/\(getuid())/com.olympsis.tender.test.missing"])
    #expect(result.exitCode == 113)
    #expect(result.stderr.contains("Could not find service"))
}
