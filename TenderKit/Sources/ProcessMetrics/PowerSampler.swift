import CoreFoundation
import Darwin
import Foundation
import TenderCore

/// EXPERIMENTAL. Per-domain power (CPU, GPU, Neural Engine, DRAM) from IOReport's
/// "Energy Model" group: the same counters `powermetrics` reads, without root.
///
/// IOReport is a private library with no SDK stub, so it's loaded with `dlopen` and every
/// symbol is looked up at runtime. Apple can rename channels in any macOS update: anything
/// missing becomes "no reading", never an error. Not thread-safe; `SystemSampler` owns it.
final class PowerSampler {
    // C signatures, with every CF object passed as a raw pointer.
    private typealias CopyChannelsInGroup = @convention(c) (
        UnsafeRawPointer?, UnsafeRawPointer?, UInt64, UInt64, UInt64) -> UnsafeMutableRawPointer?
    private typealias CreateSubscription = @convention(c) (
        UnsafeRawPointer?, UnsafeMutableRawPointer?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?,
        UInt64, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias CreateSamples = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesDelta = @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias ChannelGetString = @convention(c) (UnsafeRawPointer?) -> UnsafeRawPointer?
    private typealias SimpleGetIntegerValue = @convention(c) (UnsafeRawPointer?, Int32) -> Int64

    private let createSamples: CreateSamples
    private let createSamplesDelta: CreateSamplesDelta
    private let channelName: ChannelGetString
    private let unitLabel: ChannelGetString
    private let integerValue: SimpleGetIntegerValue

    /// Kept for the sampler's lifetime: the subscription was made from it.
    private let desired: CFMutableDictionary
    /// Both retained for the sampler's lifetime.
    private let subscription: UnsafeMutableRawPointer
    private let channels: UnsafeMutableRawPointer
    private var previous: (samples: UnsafeMutableRawPointer, at: Date)?

    /// Nil when IOReport or the Energy Model group isn't there.
    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func symbol<T>(_ name: String, _: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let copyChannels = symbol("IOReportCopyChannelsInGroup", CopyChannelsInGroup.self),
              let createSubscription = symbol("IOReportCreateSubscription", CreateSubscription.self),
              let createSamples = symbol("IOReportCreateSamples", CreateSamples.self),
              let createSamplesDelta = symbol("IOReportCreateSamplesDelta", CreateSamplesDelta.self),
              let channelName = symbol("IOReportChannelGetChannelName", ChannelGetString.self),
              let unitLabel = symbol("IOReportChannelGetUnitLabel", ChannelGetString.self),
              let integerValue = symbol("IOReportSimpleGetIntegerValue", SimpleGetIntegerValue.self)
        else { return nil }
        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.channelName = channelName
        self.unitLabel = unitLabel
        self.integerValue = integerValue

        let group = "Energy Model" as CFString
        guard let energy = copyChannels(Unmanaged.passUnretained(group).toOpaque(), nil, 0, 0, 0) else { return nil }
        let energyDictionary = Unmanaged<CFDictionary>.fromOpaque(energy).takeRetainedValue()
        // The subscription wants a mutable copy, and fills in the channels it subscribed to.
        guard let desired = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, energyDictionary) else { return nil }
        var subscribed: UnsafeMutableRawPointer?
        guard let subscription = createSubscription(nil, Unmanaged.passUnretained(desired).toOpaque(),
                                                    &subscribed, 0, nil),
              let subscribed
        else { return nil }
        self.desired = desired
        self.subscription = subscription
        channels = subscribed
    }

    deinit {
        if let previous { Unmanaged<CFTypeRef>.fromOpaque(previous.samples).release() }
        Unmanaged<CFTypeRef>.fromOpaque(channels).release()
        Unmanaged<CFTypeRef>.fromOpaque(subscription).release()
    }

    /// Average power since the previous call. Nil on the first call, or if sampling fails.
    func sample(now: Date = Date()) -> NodePower? {
        guard let current = createSamples(subscription, channels, nil) else { return nil }
        defer { previous = (current, now) }
        guard let baseline = previous else { return nil }
        defer { Unmanaged<CFTypeRef>.fromOpaque(baseline.samples).release() }

        let elapsed = now.timeIntervalSince(baseline.at)
        guard elapsed > 0.1, let deltaPointer = createSamplesDelta(baseline.samples, current, nil) else { return nil }
        let delta = Unmanaged<CFDictionary>.fromOpaque(deltaPointer).takeRetainedValue() as NSDictionary
        guard let items = delta["IOReportChannels"] as? NSArray else { return nil }

        var power = NodePower()
        for case let item as NSDictionary in items {
            let pointer = Unmanaged.passUnretained(item).toOpaque()
            guard let name = string(channelName(pointer)),
                  let joules = joules(integerValue(pointer, 0), unit: string(unitLabel(pointer)))
            else { continue }
            Self.add(joules / elapsed, channel: name, to: &power)
        }
        return power
    }

    /// Sorts a channel into a domain. Names vary by chip: "CPU Energy", "EACC_CPU" and
    /// "PACC0_CPU" on some, "GPU Energy" or "GPU0", "ANE", "ANE0", "DRAM", "DRAM0".
    /// Per-cluster CPU channels are skipped when a "CPU Energy" total exists.
    static func add(_ watts: Double, channel name: String, to power: inout NodePower) {
        if name == "CPU Energy" {
            power.cpu = watts
            power.hasCPUTotal = true
        } else if name.hasSuffix("_CPU") || name.hasSuffix("CPU Energy") {
            if !power.hasCPUTotal { power.cpuClusters += watts }
        } else if name == "GPU Energy" || (name.hasPrefix("GPU") && name.dropFirst(3).allSatisfy(\.isNumber)) {
            power.gpu = (power.gpu ?? 0) + watts
        } else if name.hasPrefix("ANE") {
            power.ane = (power.ane ?? 0) + watts
        } else if name.hasPrefix("DRAM") {
            power.dram = (power.dram ?? 0) + watts
        }
    }

    private func string(_ pointer: UnsafeRawPointer?) -> String? {
        pointer.map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String }
    }

    private func joules(_ value: Int64, unit: String?) -> Double? {
        let divisor: Double
        switch unit {
        case "mJ": divisor = 1e3
        case "uJ", "µJ": divisor = 1e6
        case "nJ": divisor = 1e9
        default: return nil
        }
        return Double(max(value, 0)) / divisor
    }
}

/// Accumulator for one reading; becomes `NodeStats.power`.
struct NodePower {
    var cpu: Double?
    var cpuClusters = 0.0
    var hasCPUTotal = false
    var gpu: Double?
    var ane: Double?
    var dram: Double?

    var stats: PowerStats {
        let cpuWatts = cpu ?? (cpuClusters > 0 ? cpuClusters : nil)
        let parts = [cpuWatts, gpu, ane, dram].compactMap { $0 }
        return PowerStats(cpu: cpuWatts, gpu: gpu, neuralEngine: ane, dram: dram,
                          total: parts.isEmpty ? nil : parts.reduce(0, +))
    }
}
