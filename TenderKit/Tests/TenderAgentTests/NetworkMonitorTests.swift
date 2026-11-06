import Foundation
import Logging
import Synchronization
import Testing
import TenderCore

@testable import TenderAgent

/// Hands out addresses from a script, one per probe; the last one repeats.
private final class Script: Sendable {
    private let steps: Mutex<[String?]>
    init(_ steps: [String?]) { self.steps = Mutex(steps) }
    func next() -> String? { steps.withLock { $0.count > 1 ? $0.removeFirst() : $0[0] } }
}

private func monitor(_ steps: [String?], explicit: String? = nil) -> NetworkMonitor {
    let script = Script(steps)
    return NetworkMonitor(explicitHost: explicit, pollInterval: .milliseconds(10)) { script.next() }
}

@Suite struct NetworkMonitorTests {
    let logger = Logger(label: "test")

    @Test func startsOutWaiting() {
        #expect(monitor([nil]).state.kind == .waitingForTailscale)
    }

    @Test func waitsUntilTailscaleHasAnAddress() async throws {
        let network = monitor([nil, nil, "100.118.53.90"])
        let host = try await network.waitForHost(timeout: .seconds(30), logger: logger)
        #expect(host == "100.118.53.90")
        #expect(network.state == NetworkState(kind: .listening, address: "100.118.53.90"))
    }

    @Test func givesUpAfterTheTimeout() async throws {
        let network = monitor([nil])
        await #expect(throws: NetworkWaitError.self) {
            _ = try await network.waitForHost(timeout: .milliseconds(1500), logger: logger)
        }
        #expect(network.state.kind == .waitingForTailscale)
    }

    @Test func anExplicitAddressIsNeverWaitedFor() async throws {
        let network = monitor([nil], explicit: "127.0.0.1")
        #expect(network.state.kind == .loopbackOnly)
        #expect(try await network.waitForHost(timeout: .seconds(1), logger: logger) == "127.0.0.1")

        let tailnet = monitor([nil], explicit: "100.64.0.9")
        #expect(tailnet.state.kind == .listening)
    }

    @Test func noticesAChangedOrLostAddress() async {
        let changed = monitor(["100.64.0.1", "100.64.0.1", "100.64.0.2"])
        #expect(await changed.waitForChange(from: "100.64.0.1") == "100.64.0.2")

        let lost = monitor(["100.64.0.1", nil])
        #expect(await lost.waitForChange(from: "100.64.0.1") == nil)
        #expect(lost.state.kind == .waitingForTailscale)
    }

    @Test func waitingForChangeStopsWhenCancelled() async {
        let network = monitor(["100.64.0.1"])
        let task = Task { await network.waitForChange(from: "100.64.0.1") }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value == "100.64.0.1")
    }
}
