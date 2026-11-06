import Foundation
import IOKit

/// Small helpers over the I/O Registry. Everything here is readable without root.
enum IORegistry {
    /// Calls `body` for each service of the class. Returns how many there were.
    @discardableResult
    static func forEachService(matching className: String, _ body: (io_registry_entry_t) -> Void) -> Int {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return 0 }
        defer { IOObjectRelease(iterator) }
        return forEach(iterator, body)
    }

    static func forEachChild(of entry: io_registry_entry_t, _ body: (io_registry_entry_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        forEach(iterator, body)
    }

    @discardableResult
    private static func forEach(_ iterator: io_iterator_t, _ body: (io_registry_entry_t) -> Void) -> Int {
        var count = 0
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            body(entry)
            IOObjectRelease(entry)
            count += 1
            entry = IOIteratorNext(iterator)
        }
        return count
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

/// GPU use, from the Apple GPU driver's registry entries. Each process that opens the GPU
/// gets a user client under the accelerator, carrying its cumulative GPU time.
enum GPUClients {
    /// Cumulative GPU nanoseconds per pid. Nil when there's no accelerator to read.
    static func timeByPID() -> [Int32: UInt64]? {
        var times: [Int32: UInt64] = [:]
        let accelerators = IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            IORegistry.forEachChild(of: accelerator) { client in
                guard let creator = IORegistry.property(client, "IOUserClientCreator") as? String,
                      let pid = pid(fromCreator: creator),
                      let usage = IORegistry.property(client, "AppUsage") as? [[String: Any]] else { return }
                for entry in usage {
                    if let time = (entry["accumulatedGPUTime"] as? NSNumber)?.uint64Value {
                        times[pid, default: 0] &+= time
                    }
                }
            }
        }
        return accelerators > 0 ? times : nil
    }

    /// "pid 1234, WindowServer" → 1234.
    static func pid(fromCreator creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        return Int32(creator.dropFirst(4).prefix { $0.isNumber })
    }

    /// Whole-GPU busy percent and memory in use, from the busiest accelerator.
    static func utilization() -> (percent: Double, memory: UInt64?)? {
        var best: (percent: Double, memory: UInt64?)?
        IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            guard let stats = IORegistry.property(accelerator, "PerformanceStatistics") as? [String: Any],
                  let percent = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            let memory = (stats["In use system memory"] as? NSNumber)?.uint64Value
            if best == nil || percent > best!.percent { best = (percent, memory) }
        }
        return best
    }
}

/// Cumulative bytes read and written across every block storage driver.
enum BlockStorage {
    static func totals() -> (read: UInt64, write: UInt64)? {
        var read: UInt64 = 0
        var write: UInt64 = 0
        var found = false
        IORegistry.forEachService(matching: "IOBlockStorageDriver") { driver in
            guard let stats = IORegistry.property(driver, "Statistics") as? [String: Any] else { return }
            found = true
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return found ? (read, write) : nil
    }
}
