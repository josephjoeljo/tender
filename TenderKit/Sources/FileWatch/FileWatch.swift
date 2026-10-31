import CoreServices
import Foundation

/// Calls back when anything below a directory changes, using FSEvents. Events can
/// be coalesced or delayed, so callers should also rescan periodically.
public final class DirectoryWatcher: @unchecked Sendable {
    private let path: String
    private let latency: TimeInterval
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "tender.filewatch")
    private var stream: FSEventStreamRef?

    public init(path: String, latency: TimeInterval = 0.2, onChange: @escaping @Sendable () -> Void) {
        self.path = path
        self.latency = latency
        self.onChange = onChange
    }

    deinit { stop() }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil
            )
            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
            }
            guard let created = FSEventStreamCreate(
                nil, callback, &context, [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
            ) else { return }
            FSEventStreamSetDispatchQueue(created, queue)
            FSEventStreamStart(created)
            stream = created
        }
    }

    public func stop() {
        queue.sync {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}

/// Size and modification time: enough to tell that a file changed.
public struct FileFingerprint: Sendable, Equatable {
    public var size: UInt64
    public var modified: TimeInterval

    public init(size: UInt64, modified: TimeInterval) {
        self.size = size
        self.modified = modified
    }

    public init?(url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attributes[.size] as? UInt64,
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        self.init(size: size, modified: modified.timeIntervalSince1970)
    }
}

/// Debounce: a file counts as stable once its fingerprint hasn't changed for a
/// whole window, so a binary is never picked up while it is still being copied in.
public struct StabilityTracker: Sendable {
    private var seen: [String: (fingerprint: FileFingerprint, since: Date)] = [:]
    public var window: TimeInterval

    public init(window: TimeInterval = 2) { self.window = window }

    public mutating func isStable(key: String, fingerprint: FileFingerprint, now: Date = Date()) -> Bool {
        if let entry = seen[key], entry.fingerprint == fingerprint {
            return now.timeIntervalSince(entry.since) >= window
        }
        seen[key] = (fingerprint, now)
        return false
    }

    public mutating func forget(key: String) { seen[key] = nil }
}
