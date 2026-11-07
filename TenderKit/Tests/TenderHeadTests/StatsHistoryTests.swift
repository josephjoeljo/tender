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

@Test func subSecondPointsStillFillTheLimit() {
    // Heartbeats right after a node joins can be a fraction of a second apart.
    let points = (0..<5).map { point(Double($0) * 0.2) }
    let span = points.first!.date...points.last!.date
    #expect(NodeStatsPoint.downsampled(points, to: 2, over: span).count == 2)
    #expect(NodeStatsPoint.downsampled(points, to: 4, over: span).count == 4)
    let instant = Array(repeating: point(0), count: 5)
    #expect(NodeStatsPoint.downsampled(instant, to: 2, over: instant[0].date...instant[0].date).count == 2)
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

// MARK: Process history

private func instance(_ service: String, _ number: Int = 0, cpu: Double? = 10, pid: Int32? = 42,
                      restarts: Int = 0, files: Int = 8) -> InstanceStatus {
    InstanceStatus(service: service, instance: number, node: NodeID("n"), state: pid == nil ? .crashed : .running,
                   pid: pid, restarts: restarts, cpu: cpu, rss: 500,
                   stats: ProcessStats(footprint: 300, threads: 4, openFiles: files, diskReadRate: 7, power: 0.5))
}

@Test func processPointsMergeAndPreferTheFootprint() throws {
    let at = start
    let running = ProcessStatsPoint(instance("api", cpu: 10, restarts: 1), at: at)
    #expect(running.memory == 300, "footprint over RSS")
    #expect(running.openFiles == 8)
    #expect(running.diskReadRate == 7)
    #expect(!running.down)
    var old = instance("api")
    old.stats = nil
    #expect(ProcessStatsPoint(old, at: at).memory == 500, "RSS from an older tenderd")
    let crashed = ProcessStatsPoint(instance("api", cpu: nil, pid: nil, restarts: 2), at: at.addingTimeInterval(5))
    #expect(crashed.down)

    let merged = try #require(ProcessStatsPoint.merged([running, crashed,
                                                        ProcessStatsPoint(instance("api", cpu: 30, restarts: 2, files: 12),
                                                                          at: at.addingTimeInterval(10))]))
    #expect(merged.cpuPercent == 20, "a down point has no CPU to average in")
    #expect(merged.openFiles.map { ($0 * 100).rounded() / 100 } == 9.33)
    #expect(merged.restarts == 2)
    #expect(merged.down)
    #expect(merged.date == at.addingTimeInterval(10))
}

@Test func registryRecordsHistoryPerInstance() async throws {
    let state = RegistryState(store: nil)
    let node = NodeID("n")
    try await state.register(NodeInfo(id: node, version: "1", macOS: "x", hardware: "y"))
    for (index, second) in [0.0, 5, 10].enumerated() {
        let now = start.addingTimeInterval(second)
        let processes = [instance("api", 0, cpu: Double(index)), instance("api", 1, cpu: 50), instance("db", cpu: 1)]
        _ = await state.heartbeat(Heartbeat(node: node, nodeClock: now, processes: processes, spoolBacklog: 0),
                                  registeredThisRun: true, now: now)
    }
    let api = try #require(await state.history(of: node, service: "api", instance: 0, since: nil, limit: 10))
    #expect(api.points.map(\.cpuPercent) == [0, 1, 2])
    #expect(api.service == "api" && api.instance == 0 && api.node == node)
    #expect(await state.history(of: node, service: "api", instance: 1, since: nil, limit: 10)?.points.map(\.cpuPercent) == [50, 50, 50])
    #expect(await state.instances(of: "api", on: node) == [0, 1])
    let capped = try #require(await state.history(of: node, service: "api", instance: 0, since: nil, limit: 2))
    #expect(capped.points.count == 2 && capped.downsampled)
    #expect(await state.history(of: node, service: "nope", instance: 0, since: nil, limit: 10)?.points == [])
    #expect(await state.history(of: NodeID("unknown"), service: "api", instance: 0, since: nil, limit: 10) == nil)

    // An instance that stops being reported is forgotten from memory.
    let now = start.addingTimeInterval(15)
    _ = await state.heartbeat(Heartbeat(node: node, nodeClock: now, processes: [instance("api")], spoolBacklog: 0),
                              registeredThisRun: true, now: now)
    #expect(await state.history(of: node, service: "db", instance: 0, since: nil, limit: 10)?.points == [])
    #expect(await state.history(of: node, service: "api", instance: 0, since: nil, limit: 10)?.points.count == 4)
}

@Test func processHistoryIsStoredStitchedPrunedAndForgottenWithTheNode() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let node = NodeID("n")
    let store = try HeadStore(environment: env)
    func old(_ daysAgo: Double, tier: StatsTier, cpu: Double, service: String = "api") -> HeadStore.ClosedProcessPoint {
        .init(service: service, instance: 0, tier: tier,
              point: ProcessStatsPoint(date: start.addingTimeInterval(-daysAgo * 86400), cpuPercent: cpu))
    }
    try store.saveProcessStats(node: node, [
        old(100, tier: .hour, cpu: 1),
        old(200, tier: .hour, cpu: 99),           // past the hour tier's retention
        old(30, tier: .quarterHour, cpu: 2),
        old(3, tier: .minute, cpu: 99),           // past the minute tier's retention
        old(30, tier: .quarterHour, cpu: 5, service: "gone"), // a deleted service, still kept for its retention
    ])
    let state = RegistryState(store: store)
    try await state.register(NodeInfo(id: node, version: "1", macOS: "x", hardware: "y"))
    // An hour and two minutes of heartbeats: the first hour closing prunes.
    for second in stride(from: 0.0, through: 3720, by: 30) {
        let now = start.addingTimeInterval(second)
        _ = await state.heartbeat(Heartbeat(node: node, nodeClock: now, processes: [instance("api", cpu: 7)], spoolBacklog: 0),
                                  registeredThisRun: true, now: now)
    }
    let minutes = try store.processStats(node: node, service: "api", instance: 0, tier: .minute, since: nil)
    #expect(minutes.count == 62, "minutes 0...61 closed; the 3-day-old one was pruned")
    #expect(try store.processStats(node: node, service: "api", instance: 0, tier: .hour, since: nil).map(\.cpuPercent) == [1, 7])
    #expect(try store.processStats(node: node, service: "gone", instance: 0, tier: .quarterHour, since: nil).count == 1)

    // A restarted head: stored tiers first, then memory.
    let restarted = RegistryState(store: try HeadStore(environment: env))
    let all = try #require(await restarted.history(of: node, service: "api", instance: 0,
                                                   since: start.addingTimeInterval(-182 * 86400), limit: 2000))
    #expect(all.points.prefix(2).map(\.cpuPercent) == [1, 2])
    #expect(all.points.dropFirst(2).allSatisfy { $0.cpuPercent == 7 })
    #expect(all.points.map(\.date) == all.points.map(\.date).sorted())

    await state.remove(node)
    #expect(try store.processStats(node: node, service: "api", instance: 0, tier: .minute, since: nil).isEmpty)
    #expect(try store.processStats(node: node, service: "gone", instance: 0, tier: .quarterHour, since: nil).isEmpty)
}

// MARK: Retention

@Test func tierRetentionFollowsTheSetting() {
    #expect(StatsTier.hour.retention(keepingDays: 190) == 190 * 86400)
    #expect(StatsTier.quarterHour.retention(keepingDays: 190) == 35 * 86400)
    #expect(StatsTier.minute.retention(keepingDays: 190) == 2 * 86400)
    #expect(StatsTier.quarterHour.retention(keepingDays: 7) == 7 * 86400)
    #expect(StatsTier.minute.retention(keepingDays: 1) == 86400)
    #expect(HistoryRetention().isValid)
    #expect(!HistoryRetention(nodeDays: 0).isValid)
    #expect(!HistoryRetention(processDays: 731).isValid)
}

@Test func loweringRetentionSavesPrunesAndHidesOlderPoints() async throws {
    let env = try makeEnvironment()
    defer { try? FileManager.default.removeItem(at: env.root) }
    let node = NodeID("n")
    let now = start
    let store = try HeadStore(environment: env)
    try store.saveNode(NodeInfo(id: node, version: "1", macOS: "x", hardware: "y"))
    func daysAgo(_ days: Double, cpu: Double) -> NodeStatsPoint {
        NodeStatsPoint(date: now.addingTimeInterval(-days * 86400), cpuPercent: cpu)
    }
    try store.saveStats(node: node, tier: .hour, point: daysAgo(100, cpu: 1))
    try store.saveStats(node: node, tier: .hour, point: daysAgo(20, cpu: 2))
    try store.saveStats(node: node, tier: .quarterHour, point: daysAgo(5, cpu: 3))
    try store.saveProcessStats(node: node, [
        .init(service: "api", instance: 0, tier: .hour, point: ProcessStatsPoint(date: now.addingTimeInterval(-60 * 86400), cpuPercent: 1)),
        .init(service: "api", instance: 0, tier: .quarterHour, point: ProcessStatsPoint(date: now.addingTimeInterval(-3 * 86400), cpuPercent: 2)),
    ])

    let state = RegistryState(store: store)
    #expect(await state.retention == HistoryRetention())
    let all = try #require(await state.history(of: node, since: nil, limit: 100, now: now))
    #expect(all.points.map(\.cpuPercent) == [1, 2, 3])

    let changed = try await state.setRetention(HistoryRetentionUpdate(nodeDays: 30, processDays: 7), now: now)
    #expect(changed == HistoryRetention(nodeDays: 30, processDays: 7))
    #expect(try store.stats(node: node, tier: .hour, since: nil).map(\.cpuPercent) == [2], "100 days old is pruned")
    #expect(try store.processStats(node: node, service: "api", instance: 0, tier: .hour, since: nil).isEmpty)
    #expect(await state.history(of: node, service: "api", instance: 0, since: nil, limit: 100, now: now)?
        .points.map(\.cpuPercent) == [2])
    // A later query hides what has aged past the retention before the next prune.
    #expect(await state.history(of: node, since: nil, limit: 100, now: now.addingTimeInterval(20 * 86400))?
        .points.map(\.cpuPercent) == [3])

    // Kept across a restart; a bad value changes nothing.
    let restarted = RegistryState(store: try HeadStore(environment: env))
    #expect(await restarted.retention == changed)
    await #expect(throws: NodeCallError.self) { try await restarted.setRetention(HistoryRetentionUpdate(processDays: 0)) }
    #expect(await restarted.retention == changed)
}
