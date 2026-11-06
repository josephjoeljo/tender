import Foundation
import Testing
import TenderCore
@testable import TenderLogStore

private func makeStore(limits: LogStoreLimits = LogStoreLimits()) throws -> (LogStore, URL) {
    let directory = URL(filePath: "/tmp/tender-test-\(UUID().uuidString.prefix(8))")
    return (try LogStore(directory: directory, limits: limits), directory)
}

private func record(_ seq: UInt64, _ line: String, service: String = "api", at time: Date = Date(timeIntervalSince1970: 1000)) -> LogRecord {
    LogRecord(seq: seq, nodeTime: time, service: service, instance: 0, stream: .out, line: line)
}

private let node = NodeID("mac-2")
private let day1 = Date(timeIntervalSince1970: 1_700_000_000)

@Test func ingestAcksAndDedupes() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try await store.ingest(LogBatch(node: node, previousSeq: 0, records: [record(1, "a"), record(2, "b")]), now: day1) == 2)
    // A redelivered batch adds nothing and acks the same.
    #expect(try await store.ingest(LogBatch(node: node, previousSeq: 0, records: [record(1, "a"), record(2, "b")]), now: day1) == 2)
    #expect(try await store.search(LogQuery()).entries.map(\.line) == ["a", "b"])
    #expect(await store.ingestedLines()[node] == 2)
}

@Test func missingLinesAreRefusedSoTheWorkerRewinds() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await store.ingest(LogBatch(node: node, previousSeq: 0, records: [record(1, "a")]), now: day1)
    #expect(try await store.ingest(LogBatch(node: node, previousSeq: 5, records: [record(6, "f")]), now: day1) == 1)
    #expect(try await store.search(LogQuery()).entries.count == 1)
}

@Test func declaredGapIsAcceptedAndReported() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await store.ingest(LogBatch(node: node, previousSeq: 0, records: [record(1, "a")]), now: day1)
    let gap = LogGap(droppedLines: 4, throughSeq: 5, recordedAt: day1)
    #expect(try await store.ingest(LogBatch(node: node, previousSeq: 5, records: [record(6, "f")], gaps: [gap]), now: day1) == 6)
    let result = try await store.search(LogQuery())
    #expect(result.entries.map(\.line) == ["a", "f"])
    #expect(result.gaps.first?.droppedLines == 4)
    #expect(result.gaps.first?.node == node)
}

@Test func headWithNoStateAcceptsWhateverArrives() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try await store.ingest(LogBatch(node: node, previousSeq: 90, records: [record(91, "x")]), now: day1) == 91)
}

@Test func progressSurvivesARestart() async throws {
    let directory = URL(filePath: "/tmp/tender-test-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = try LogStore(directory: directory)
    _ = try await first.ingest(LogBatch(node: node, previousSeq: 0, records: [record(1, "a")]), now: day1)
    let second = try LogStore(directory: directory)
    #expect(try await second.ingest(LogBatch(node: node, previousSeq: 7, records: [record(8, "h")]), now: day1) == 1)
    #expect(await second.ingestedLines()[node] == 1)
}

@Test func fullTextSearchFindsWordsAndCantInjectSyntax() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await store.ingest(LogBatch(node: node, previousSeq: 0, records: [
        record(1, "connection timeout to mongo"), record(2, "all good"), record(3, "timeout reading body"),
    ]), now: day1)
    #expect(try await store.search(LogQuery(text: "timeout")).entries.map(\.seq) == [1, 3])
    #expect(try await store.search(LogQuery(text: "timeout mongo")).entries.map(\.seq) == [1])
    #expect(try await store.search(LogQuery(text: "absent")).entries.isEmpty)
    for hostile in ["\"", "a AND", "NEAR(", "*", "line:x", "' OR 1=1 --", "(((", "a\"b"] {
        _ = try await store.search(LogQuery(text: hostile))
    }
}

@Test func filtersCombineAndNewestWinTheLimit() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await store.ingest(LogBatch(node: node, previousSeq: 0, records: [
        record(1, "one", service: "api", at: day1), record(2, "two", service: "web", at: day1.addingTimeInterval(1)),
        record(3, "three", service: "api", at: day1.addingTimeInterval(2)),
        LogRecord(seq: 4, nodeTime: day1.addingTimeInterval(3), service: "api", instance: 1, stream: .err, line: "four"),
    ]), now: day1)
    _ = try await store.ingest(LogBatch(node: NodeID("mac-3"), previousSeq: 0, records: [record(1, "other", at: day1)]), now: day1)
    #expect(try await store.search(LogQuery(service: "web")).entries.map(\.line) == ["two"])
    #expect(try await store.search(LogQuery(node: "mac-3")).entries.map(\.line) == ["other"])
    #expect(try await store.search(LogQuery(stream: .err)).entries.map(\.line) == ["four"])
    #expect(try await store.search(LogQuery(service: "api", node: "mac-2", limit: 2)).entries.map(\.line) == ["three", "four"])
    #expect(try await store.search(LogQuery(node: "mac-2", since: day1.addingTimeInterval(2))).entries.count == 2)
    #expect(try await store.search(LogQuery(node: "mac-2", until: day1)).entries.map(\.line) == ["one"])
    // An oversize or nonsense limit stays bounded.
    #expect(try await store.search(LogQuery(limit: -5)).entries.count == 1)
}

@Test func dayFileFollowsTheHeadClockNotTheNodeClock() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let wrongClock = day1.addingTimeInterval(-90 * 86400)
    _ = try await store.ingest(LogBatch(node: node, previousSeq: 0, records: [record(1, "a", at: wrongClock)]), now: day1)
    #expect(try await store.dayFiles() == [LogStore.dayName(day1)])
    _ = try await store.ingest(LogBatch(node: node, previousSeq: 1, records: [record(2, "b", at: wrongClock)]), now: day1.addingTimeInterval(86400))
    #expect(try await store.dayFiles().count == 2)
    #expect(try await store.search(LogQuery()).entries.count == 2)
}

@Test func retentionDeletesByAgeThenSizeButNeverToday() async throws {
    let (filling, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    var seq: UInt64 = 0
    for daysAgo in [40, 2, 1, 0] {
        seq += 1
        _ = try await filling.ingest(LogBatch(node: node, previousSeq: seq - 1, records: [record(seq, "x")]),
                                     now: day1.addingTimeInterval(-TimeInterval(daysAgo) * 86400))
    }
    #expect(try await filling.dayFiles().count == 4)
    let store = try LogStore(directory: directory, limits: LogStoreLimits(maxAgeDays: 30, maxBytes: 1))
    let removed = try await store.enforceRetention(now: day1)
    #expect(removed.count == 3)
    #expect(try await store.dayFiles() == [LogStore.dayName(day1)])
}

@Test func retentionByAgeKeepsRecentDays() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await store.ingest(LogBatch(node: node, previousSeq: 0, records: [record(1, "old")]), now: day1.addingTimeInterval(-31 * 86400))
    _ = try await store.ingest(LogBatch(node: node, previousSeq: 1, records: [record(2, "new")]), now: day1.addingTimeInterval(-29 * 86400))
    #expect(try await store.enforceRetention(now: day1).count == 1)
    #expect(try await store.search(LogQuery()).entries.map(\.line) == ["new"])
}

@Test func ingestStopsAcceptingWhenOverTheLimitSoTheDiskCantFill() async throws {
    let (store, directory) = try makeStore(limits: LogStoreLimits(maxBytes: 1))
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try await store.ingest(LogBatch(node: node, previousSeq: 0, records: [record(1, "a")]), now: day1) == 1)
    // Not acknowledged, so the worker keeps the line in its spool.
    #expect(try await store.ingest(LogBatch(node: node, previousSeq: 1, records: [record(2, "b")]), now: day1) == 1)
    #expect(try await store.search(LogQuery()).entries.map(\.line) == ["a"])
}

@Test func subscribersGetMatchingLines() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    var iterator = await store.subscribe(LogQuery(service: "api", text: "HIT")).makeAsyncIterator()
    _ = try await store.ingest(LogBatch(node: node, previousSeq: 0, records: [
        record(1, "miss"), record(2, "hit", service: "web"), record(3, "a hit here"),
    ]), now: day1)
    #expect(await iterator.next()?.seq == 3)
}

@Test func offloadListsClosedDaysUntilMarked() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await store.ingest(LogBatch(node: node, previousSeq: 0, records: [record(1, "a")]), now: day1)
    #expect(try await store.closedDaysToOffload(now: day1).isEmpty, "today isn't closed")
    let tomorrow = day1.addingTimeInterval(86400)
    let days = try await store.closedDaysToOffload(now: tomorrow)
    #expect(days.count == 1)
    let url = try #require(days.first?.url)
    #expect(try Data(contentsOf: url).count > 0)
    try await store.markOffloaded(url.lastPathComponent)
    #expect(try await store.closedDaysToOffload(now: tomorrow).isEmpty)
}

/// Throughput guard for the plan's named risk: FTS5 on busy services.
@Test func ingestThroughputIsReasonable() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let line = "2026-10-31T12:00:00Z INFO request handled path=/v1/events status=200 duration=12ms user=abc123"
    var seq: UInt64 = 0
    let clock = ContinuousClock()
    let elapsed = try await clock.measure {
        for _ in 0..<100 {
            let start = seq
            let records = (0..<1000).map { record(start + UInt64($0) + 1, line) }
            seq = try await store.ingest(LogBatch(node: node, previousSeq: start, records: records), now: day1)
        }
    }
    let rate = 100_000 / (Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)
    print("log store ingest: \(Int(rate)) lines/s")
    #expect(seq == 100_000)
    #expect(rate > 5_000, "ingest fell to \(rate) lines/s")
    let searchStart = clock.now
    let found = try await store.search(LogQuery(text: "duration", limit: 200)).entries.count
    let searchTime = clock.now - searchStart
    #expect(found == 200)
    print("log store search: \(searchTime)")
    #expect(searchTime < .seconds(2))
}

@Test func forgettingANodeClearsItsProgressAndCanPurgeItsLines() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let other = NodeID("other")
    _ = try await store.ingest(LogBatch(node: node, previousSeq: 0, records: [record(1, "timeout here"), record(2, "fine")]), now: day1)
    _ = try await store.ingest(LogBatch(node: other, previousSeq: 0, records: [record(1, "timeout there")]), now: day1)

    // Keeping the lines: only the progress goes, so a node that takes the ID starts clean.
    #expect(try await store.forget(node: node, purgeLines: false) == 0)
    #expect(await store.ingestedLines()[node] == nil)
    #expect(try await store.search(LogQuery()).entries.count == 3)

    #expect(try await store.forget(node: node, purgeLines: true) == 2)
    #expect(try await store.search(LogQuery()).entries.map(\.node) == [other])
    // Search by text no longer finds the purged lines (the FTS index was cleaned too).
    #expect(try await store.search(LogQuery(text: "timeout")).entries.map(\.line) == ["timeout there"])
    #expect(await store.ingestedLines()[other] == 1)
}
