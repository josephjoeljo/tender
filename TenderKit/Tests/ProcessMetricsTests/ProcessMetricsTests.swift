import Foundation
import Testing
@testable import ProcessMetrics

@Test func readsThisProcess() throws {
    let sample = try #require(ProcessSample.read(pid: getpid()))
    #expect(sample.residentBytes > 1 << 20)
    #expect(sample.cpuNanoseconds > 0)
    #expect(sample.startTime < Date())
    #expect(sample.startTime > Date().addingTimeInterval(-3600))
}

@Test func missingProcessIsNil() {
    #expect(ProcessSample.read(pid: 999_999) == nil)
}

@Test func cpuTimeIsInPlausibleUnits() throws {
    // Burn about 300 ms; a units bug (ticks vs ns) would be off by a factor of 40.
    let before = try #require(ProcessSample.read(pid: getpid())).cpuNanoseconds
    let start = Date()
    var x = 0.0
    while Date().timeIntervalSince(start) < 0.3 { x += sqrt(Double.random(in: 0...1)) }
    #expect(x > 0)
    let used = try #require(ProcessSample.read(pid: getpid())).cpuNanoseconds - before
    #expect(used > 150_000_000)
    #expect(used < 3_000_000_000)
}

@Test func cpuIsARateBetweenSamples() async {
    let sampler = UsageSampler()
    let start = Date(timeIntervalSince1970: 1000)
    func sample(_ seconds: Double) -> ProcessSample {
        ProcessSample(cpuNanoseconds: UInt64(seconds * 1e9), residentBytes: 42, startTime: start)
    }
    // Lifetime average on the first sample: 1 s of CPU over 10 s.
    let first = await sampler.usage(pid: 1, sample: sample(1), now: start.addingTimeInterval(10))
    #expect(abs(first.cpu - 10) < 0.001)
    #expect(first.uptime == 10)
    #expect(first.rss == 42)
    // Then the rate since: 2 s of CPU over 2 s.
    let second = await sampler.usage(pid: 1, sample: sample(3), now: start.addingTimeInterval(12))
    #expect(abs(second.cpu - 100) < 0.001)
}

@Test func readsDetailedStatsOfThisProcess() throws {
    let sample = try #require(ProcessSample.read(pid: getpid()))
    #expect((sample.footprintBytes ?? 0) > 1 << 20)
    #expect((sample.threads ?? 0) >= 1)
    #expect((sample.openFiles ?? 0) >= 3) // stdin, stdout, stderr
}

@Test func diskAndEnergyBecomeRates() async {
    let sampler = UsageSampler()
    let start = Date(timeIntervalSince1970: 1000)
    func sample(read: UInt64, energy: UInt64) -> ProcessSample {
        ProcessSample(cpuNanoseconds: 1, residentBytes: 1, startTime: start, diskReadBytes: read,
                      energyNanojoules: energy)
    }
    _ = await sampler.usage(pid: 1, sample: sample(read: 0, energy: 0), gpuNanoseconds: 0,
                            now: start.addingTimeInterval(10))
    // 4 MB, 10 J and 1 s of GPU over 2 s.
    let second = await sampler.usage(pid: 1, sample: sample(read: 4_000_000, energy: 10_000_000_000),
                                     gpuNanoseconds: 1_000_000_000, now: start.addingTimeInterval(12))
    #expect(second.stats.diskReadRate == 2_000_000)
    #expect(abs((second.stats.power ?? 0) - 5) < 0.001)
    #expect(abs((second.stats.gpuPercent ?? 0) - 50) < 0.001)
}

@Test func reusedPidStartsOver() async {
    let sampler = UsageSampler()
    let first = Date(timeIntervalSince1970: 1000)
    _ = await sampler.usage(pid: 1, sample: ProcessSample(cpuNanoseconds: 5_000_000_000, residentBytes: 1, startTime: first),
                            now: first.addingTimeInterval(10))
    // A new process with the same pid: lifetime average, not a delta against the old one.
    let second = Date(timeIntervalSince1970: 1011)
    let usage = await sampler.usage(pid: 1, sample: ProcessSample(cpuNanoseconds: 1_000_000_000, residentBytes: 1, startTime: second),
                                    now: second.addingTimeInterval(1))
    #expect(abs(usage.cpu - 100) < 0.001)
}

@Test func parsesGPUClientCreator() {
    #expect(GPUClients.pid(fromCreator: "pid 1234, WindowServer") == 1234)
    #expect(GPUClients.pid(fromCreator: "kernel") == nil)
}

@Test func cpuPercentSurvivesTickWraparound() {
    // user, system, idle, nice. User wrapped past UInt32.max.
    let then: [UInt32] = [UInt32.max - 49, 0, 0, 0]
    let now: [UInt32] = [50, 0, 100, 0]
    #expect(SystemSampler.cpuPercent(now: now, then: then) == 50)
}

@Test func samplesThisMachine() async {
    let sampler = SystemSampler()
    let first = await sampler.sample()
    #expect(first.cpuCores > 0)
    #expect(first.memoryTotal > 0)
    #expect((first.memoryUsed ?? 0) > 0)
    #expect((first.diskTotal ?? 0) > 0)
    #expect(first.loadAverage.count == 3)
    #expect(first.diskReadRate == nil) // no rates without an earlier sample
}

@Test func powerChannelsSortIntoDomains() {
    // M1-style names: per-cluster CPU channels, summed when there's no total.
    var clustered = NodePower()
    for (name, watts) in [("EACC_CPU", 0.5), ("PACC0_CPU", 2.0), ("GPU0", 1.0), ("ANE0", 0.25), ("DRAM0", 0.5)] {
        PowerSampler.add(watts, channel: name, to: &clustered)
    }
    let stats = clustered.stats
    #expect(stats.cpu == 2.5)
    #expect(stats.gpu == 1.0)
    #expect(stats.neuralEngine == 0.25)
    #expect(stats.total == 4.25)

    // Later chips report a "CPU Energy" total next to the clusters; it wins.
    var totalled = NodePower()
    for (name, watts) in [("EACC_CPU", 0.5), ("CPU Energy", 3.0), ("PACC0_CPU", 2.0), ("GPU Energy", 1.0)] {
        PowerSampler.add(watts, channel: name, to: &totalled)
    }
    #expect(totalled.stats.cpu == 3.0)
    #expect(totalled.stats.neuralEngine == nil)
}

@Test func powerReadsOnThisMac() async throws {
    // Private API: if this Mac's IOReport has no Energy Model group, there's nothing to test.
    guard let sampler = PowerSampler() else { return }
    #expect(sampler.sample() == nil) // the first reading is only a baseline
    try await Task.sleep(for: .milliseconds(300))
    let power = try #require(sampler.sample())
    // On an M3 Max every mJ channel ("CPU Energy", EACC/PACC, ANE, DRAM) reads 0, even
    // over 1.5 s under load; only the nJ "GPU Energy" channel moves.
    withKnownIssue("CPU energy channels read 0 on some chips") {
        #expect((power.stats.cpu ?? 0) > 0)
    }
}
