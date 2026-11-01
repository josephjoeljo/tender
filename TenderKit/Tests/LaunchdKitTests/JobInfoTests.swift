import Foundation
import Testing
@testable import LaunchdKit

/// Fixtures are real `launchctl print` output captured on macOS 27.2.
private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func parsesRunningJob() throws {
    let info = JobInfo(output: try fixture("running"))
    #expect(info.label == "com.olympsis.tender.test.fixture")
    #expect(info.state == .running)
    #expect(info.instanceState == .running)
    #expect(info.pid == 21641)
    #expect(info.runs == 2)
    #expect(info.restarts == 1)
    #expect(info.program == "/bin/sleep")
    #expect(info.arguments == ["/bin/sleep", "1000"])
    #expect(info.stdoutPath == "/tmp/tender-fixture.out")
    #expect(info.stderrPath == "/tmp/tender-fixture.err")
    #expect(info.plistPath == "/tmp/com.olympsis.tender.test.fixture.plist")
    #expect(info.lastTerminatingSignal == "Killed: 9")
    #expect(info.lastExitCode == nil)
}

@Test func parsesJobBeingSpawned() throws {
    let info = JobInfo(output: try fixture("starting"))
    #expect(info.state == .starting)
    #expect(info.instanceState == .starting)
    #expect(info.restarts == 0)
    #expect(info.lastExitCode == nil) // "(never exited)"
}

@Test func parsesKilledJobAwaitingRespawn() throws {
    let info = JobInfo(output: try fixture("spawn_scheduled"))
    #expect(info.state == .spawnScheduled)
    #expect(info.instanceState == .crashed)
    #expect(info.pid == nil)
    #expect(info.lastTerminatingSignal == "Killed: 9")
}

@Test func parsesCleanlyExitedJob() throws {
    let info = JobInfo(output: try fixture("exited"))
    #expect(info.state == .notRunning)
    #expect(info.instanceState == .stopped)
    #expect(info.lastExitCode == 0)
}

@Test func parsesSystemDomainJob() throws {
    let info = JobInfo(output: try fixture("system_syslogd"))
    #expect(info.label == "com.apple.syslogd")
    #expect(info.program == "/usr/sbin/syslogd")
    #expect(info.instanceState == .running)
}

@Test func nestedSectionsDoNotLeakIntoTopLevelFields() throws {
    // Coalition sections have their own `state = active`.
    let info = JobInfo(output: try fixture("running"))
    #expect(info.state != .other("active"))
}

@Test(arguments: ["", "garbage", "}\n}\n", "x = {\n\tstate = \n\tpid = abc\n\truns = many\n", "a = {\n\tb = {\n\t\tc = {\n"])
func unexpectedOutputDoesNotCrash(output: String) {
    let info = JobInfo(output: output)
    #expect(info.pid == nil)
    #expect(info.runs == nil)
    #expect(info.restarts == 0)
}

@Test func unknownStateIsKeptAndFallsBackToPid() {
    let info = JobInfo(output: "a/b = {\n\tstate = wibbling\n\tpid = 7\n}\n")
    #expect(info.state == .other("wibbling"))
    #expect(info.instanceState == .running)
    #expect(JobInfo(output: "a/b = {\n\tstate = wibbling\n}\n").instanceState == .unknown)
}

@Test func nonZeroExitIsCrashed() {
    #expect(JobInfo(output: "a/b = {\n\tstate = not running\n\tlast exit code = 78: EX_CONFIG\n}\n").instanceState == .crashed)
}

@Test func parsesDomainServiceList() throws {
    let labels = parseServiceLabels(domainOutput: try fixture("domain"))
    #expect(labels.contains("com.olympsis.tender.test.fixture"))
    #expect(labels.contains("com.apple.mlhostd"))
    #expect(!labels.contains { $0.contains("disabled") || $0.contains("=>") })
}
