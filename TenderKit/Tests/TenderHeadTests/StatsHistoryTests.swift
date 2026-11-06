import Foundation
import Testing
import TenderCore
import TenderProtocol
@testable import TenderHead

@Test func ringBufferKeepsTheNewestInOrder() {
    var ring = RingBuffer<Int>(capacity: 3)
    #expect(ring.isEmpty)
    #expect(ring.first == nil)
    for value in 1...2 { ring.append(value) }
    #expect(ring.elements == [1, 2])
    for value in 3...7 { ring.append(value) }
    #expect(ring.count == 3)
    #expect(ring.elements == [5, 6, 7])
    #expect(ring.first == 5)
}

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func point(_ second: Double, cpu: Double = 10, crashed: Int = 0, gap: TimeInterval? = 5) -> NodeStatsPoint {
    NodeStatsPoint(date: start.addingTimeInterval(second), cpuPercent: cpu, memoryTotal: 100, heartbeatGap: gap,
                   instanceCount: 2, crashedCount: crashed)
}

@Test func mergeAveragesUsageAndKeepsTheWorstSpikes() throws {
    let merged = try #require(NodeStatsPoint.merged([point(0, cpu: 10, gap: 5), point(5, cpu: 30, crashed: 1, gap: 40),
                                                     point(10, cpu: 20, gap: nil)]))
    #expect(merged.date == start.addingTimeInterval(10))
    #expect(merged.cpuPercent == 20)
    #expect(merged.gpuPercent == nil)
    #expect(merged.heartbeatGap == 40)
    #expect(merged.crashedCount == 1)
    #expect(merged.instanceCount == 2)
    #expect(NodeStatsPoint.merged([NodeStatsPoint]()) == nil)
}

@Test func downsamplingStaysUnderTheLimit() {
    let points = (0..<10).map { point(Double($0) * 5, cpu: Double($0)) }
    #expect(NodeStatsPoint.downsampled(points, to: 20) == points)
    let three = NodeStatsPoint.downsampled(points, to: 3)
    #expect(three.count == 3)
    #expect(three.map(\.cpuPercent) == [1.5, 5.5, 8.5])
    #expect(three.last?.date == points.last?.date)
    #expect(NodeStatsPoint.downsampled(points, to: 0).isEmpty)
}

@Test func recorderFallsBackToMinutesOnceRawPointsRollOff() {
    var recorder = NodeStatsRecorder(recentCapacity: 6, minuteCapacity: 10)
    // Three minutes at a 20-second heartbeat: 9 points, only the last 6 kept raw.
    for index in 0..<9 { recorder.record(point(Double(index) * 20, cpu: Double(index))) }
    let all = recorder.points(since: nil)
    // Minute 0 closed as one merged point; raw starts at 60s; minute 1 is covered by raw.
    #expect(all.map(\.date) == [40, 60, 80, 100, 120, 140, 160].map { start.addingTimeInterval($0) })
    #expect(all.first?.cpuPercent == 1)
    #expect(recorder.points(since: start.addingTimeInterval(100)).count == 4)
}

@Test func registryRecordsHistoryPerHeartbeat() async throws {
    let state = RegistryState(store: nil)
    let node = NodeID("n")
    try await state.register(NodeInfo(id: node, version: "1", macOS: "x", hardware: "y"))
    let stats = NodeStats(sampledAt: start, cpuPercent: 42, cpuCores: 8, memoryTotal: 1000, memoryUsed: 400,
                          networkInRate: 7, power: PowerStats(total: 3))
    for second in [0.0, 5, 12] {
        let now = start.addingTimeInterval(second)
        _ = await state.heartbeat(Heartbeat(node: node, nodeClock: now, processes: [], spoolBacklog: 9, stats: stats),
                                  registeredThisRun: true, now: now)
    }
    let history = try #require(await state.history(of: node, since: nil, limit: 10))
    #expect(history.points.count == 3)
    #expect(!history.downsampled)
    #expect(history.points.map(\.heartbeatGap) == [nil, 5, 7])
    let latest = try #require(history.points.last)
    #expect(latest.cpuPercent == 42)
    #expect(latest.memoryUsed == 400)
    #expect(latest.memoryTotal == 1000)
    #expect(latest.networkInRate == 7)
    #expect(latest.power == 3)
    #expect(latest.spoolBacklog == 9)

    #expect(await state.history(of: node, since: start.addingTimeInterval(5), limit: 10)?.points.count == 2)
    let capped = try #require(await state.history(of: node, since: nil, limit: 2))
    #expect(capped.points.count == 2)
    #expect(capped.downsampled)
    #expect(await state.history(of: NodeID("unknown"), since: nil, limit: 10) == nil)
}
