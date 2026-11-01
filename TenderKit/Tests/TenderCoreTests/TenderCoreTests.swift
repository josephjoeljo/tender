import Foundation
import Testing
@testable import TenderCore

@Test func serviceLabelFormat() {
    let label = TenderEnvironment.production.serviceLabel(service: "api", instance: 0)
    #expect(label == "com.olympsis.tender.svc.api.0")
}

@Test func environmentPaths() {
    let env = TenderEnvironment.production
    #expect(env.configDirectory.path() == "/etc/tender")
    #expect(env.stateDB.path() == "/opt/tender/state.db")
    #expect(env.socketPath.path() == "/opt/tender/run/tender.sock")
    #expect(env.stdoutLog(service: "api", instance: 2).path() == "/var/log/tender/api/2.out.log")
    #expect(env.stderrLog(service: "api", instance: 2).path() == "/var/log/tender/api/2.err.log")
    #expect(env.releaseBinary(service: "api", sha12: "abc").path() == "/opt/tender/releases/api/abc/api")
}

@Test(arguments: ["api", "api-2", "my_worker", "A1"])
func acceptsServiceName(name: String) {
    #expect(ServiceSpec.isValidName(name))
}

@Test(arguments: ["", "a.b", "../evil", "a/b", "a b", "-flag", String(repeating: "x", count: 65)])
func rejectsServiceName(name: String) {
    #expect(!ServiceSpec.isValidName(name))
}

@Test func specAndStatusRoundTripThroughJSON() throws {
    let spec = ServiceSpec(name: "api", program: .release(sha12: "abc"), arguments: ["--port", "8080"],
                           logPaths: LogPaths(stdout: "/tmp/o"))
    #expect(try JSONDecoder().decode(ServiceSpec.self, from: JSONEncoder().encode(spec)) == spec)
    #expect(spec.user == "_tender")

    let status = InstanceStatus(service: "api", instance: 0, node: NodeID("n"), state: .running,
                                uptime: 3, restarts: 2, release: "abc", cpu: 1.5, rss: 4096)
    #expect(try JSONDecoder().decode(InstanceStatus.self, from: JSONEncoder().encode(status)) == status)
}
