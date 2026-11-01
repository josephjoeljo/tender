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
