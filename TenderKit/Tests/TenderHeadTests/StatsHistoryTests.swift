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

// MARK: Long-term history

@Test func recorderClosesMinutesQuarterHoursAndHours() {
    var recorder = NodeStatsRecorder()
    var closed: [StatsTier: [NodeStatsPoint]] = [:]
    // A heartbeat every 30 seconds for 2h05m.
    for second in stride(from: 0.0, through: 7500, by: 30) {
        for (tier, merged) in recorder.record(point(second, cpu: second < 900 ? 10 : 30)) {
            closed[tier, default: []].append(merged)
        }
    }
    // Minutes 0...124 have closed; 125 is still open. Quarters 0...7 and hours 0...1 likewise.
    #expect(closed[.minute]?.count == 125)
    #expect(closed[.quarterHour]?.count == 8)
    #expect(closed[.hour]?.count == 2)
    #expect(closed[.quarterHour]?.first?.cpuPercent == 10)
    #expect(closed[.quarterHour]?.first?.date == start.addingTimeInterval(14 * 60 + 30), "dated by its last heartbeat")
    #expect(closed[.quarterHour]?[1].cpuPercent == 30)
    #expect(closed[.hour]?.first?.cpuPercent.map { ($0 * 100).rounded() / 100 } == 25, "a quarter at 10, three at 30")
}

@Test func timeSlicesKeepCoarseStretchesFromBeingCrowdedOut() {
    // Ten hourly points, then 500 points in the last half hour.
    let coarse = (0..<10).map { point(Double($0) * 3600) }
    let fine = (0..<500).map { point(36_000 + Double($0) * 3.6) }
    let all = coarse + fine
    let span = all.first!.date...all.last!.date
    let sliced = NodeStatsPoint.downsampled(all, to: 50, over: span)
    #expect(sliced.count <= 50)
    #expect(sliced.prefix(10).map(\.date) == coarse.map(\.date), "each hourly point keeps its own slice")
    #expect(sliced.last?.date == all.last?.date)
    #expect(NodeStatsPoint.downsampled(coarse, to: 50, over: span) == coarse)
    #expect(NodeStatsPoint.downsampled(all, to: 0, over: span).isEmpty)
}

@Test func storedHistorySurvivesARestartAndStitchesTiers() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let node = NodeID("n")
    let now = start.addingTimeInterval(200 * 86400)
    let store = try HeadStore(environment: env)
    try store.saveNode(NodeInfo(id: node, version: "1", macOS: "x", hardware: "y"))
    func day(_ daysAgo: Double, cpu: Double) -> NodeStatsPoint {
        NodeStatsPoint(date: now.addingTimeInterval(-daysAgo * 86400), cpuPercent: cpu)
    }
    try store.saveStats(node: node, tier: .hour, point: day(100, cpu: 1))
    try store.saveStats(node: node, tier: .hour, point: day(20, cpu: 99))   // covered by quarter hours
    try store.saveStats(node: node, tier: .quarterHour, point: day(30, cpu: 2))
    try store.saveStats(node: node, tier: .quarterHour, point: day(1, cpu: 99)) // covered by minutes
    try store.saveStats(node: node, tier: .minute, point: day(1.5, cpu: 3))
    try store.saveStats(node: node, tier: .minute, point: day(1.2, cpu: 4))

    // A head that just started: nothing in memory, everything from disk.
    let state = RegistryState(store: try HeadStore(environment: env))
    let all = try #require(await state.history(of: node, since: now.addingTimeInterval(-182 * 86400), limit: 2000))
    #expect(all.points.map(\.cpuPercent) == [1, 2, 3, 4])
    let week = try #require(await state.history(of: node, since: now.addingTimeInterval(-7 * 86400), limit: 2000))
    #expect(week.points.map(\.cpuPercent) == [3, 4])
}

@Test func heartbeatsAreStoredPrunedAndForgottenWithTheNode() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let node = NodeID("n")
    let store = try HeadStore(environment: env)
    // Old enough that the first hourly prune drops it.
    try store.saveStats(node: node, tier: .minute, point: NodeStatsPoint(date: start.addingTimeInterval(-3 * 86400)))
    try store.saveStats(node: node, tier: .quarterHour, point: NodeStatsPoint(date: start.addingTimeInterval(-30 * 86400)))
    let state = RegistryState(store: store)
    try await state.register(NodeInfo(id: node, version: "1", macOS: "x", hardware: "y"))
    for second in stride(from: 0.0, through: 3720, by: 30) {
        let now = start.addingTimeInterval(second)
        _ = await state.heartbeat(Heartbeat(node: node, nodeClock: now, processes: [], spoolBacklog: 0),
                                  registeredThisRun: true, now: now)
    }
    let minutes = try store.stats(node: node, tier: .minute, since: nil)
    #expect(minutes.count == 62, "minutes 0...61 closed; the 3-day-old one was pruned")
    #expect(minutes.allSatisfy { $0.date >= start })
    #expect(try store.stats(node: node, tier: .quarterHour, since: nil).count == 5, "30 days old is still kept")
    #expect(try store.stats(node: node, tier: .hour, since: nil).count == 1)

    await state.remove(node)
    #expect(try store.stats(node: node, tier: .minute, since: nil).isEmpty)
    #expect(try store.stats(node: node, tier: .quarterHour, since: nil).isEmpty)
}
