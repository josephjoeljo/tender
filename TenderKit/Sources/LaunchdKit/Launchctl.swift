import Foundation
import Logging

/// Exit status and output of one `launchctl` invocation.
public struct CommandResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum LaunchctlError: Error, Equatable, CustomStringConvertible {
    case alreadyLoaded(String)
    case notFound(String)
    case ioError(String)
    case permissionDenied(String)
    case failed(exitCode: Int32, message: String)

    public var description: String {
        switch self {
        case .alreadyLoaded(let detail): "launchd job already loaded: \(detail)"
        case .notFound(let detail): "launchd job not found: \(detail)"
        case .ioError(let detail): "launchctl I/O error: \(detail)"
        case .permissionDenied(let detail): "launchctl permission denied: \(detail)"
        case .failed(let code, let message): "launchctl exited with \(code): \(message)"
        }
    }

    /// Maps a failed invocation to a typed error. launchctl has no documented
    /// exit codes; these are the ones observed on macOS 14 through 27.
    static func from(_ result: CommandResult, target: String) -> LaunchctlError {
        let message = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = message.lowercased()
        if lowered.contains("not permitted") || lowered.contains("permission denied") {
            return .permissionDenied(message)
        }
        switch result.exitCode {
        case 3, 113: return .notFound(target)
        case 37: return .alreadyLoaded(target)
        case 5: return .ioError(message)
        case 1, 13, 150: return .permissionDenied(message)
        default: return .failed(exitCode: result.exitCode, message: message)
        }
    }
}

/// Runs the `launchctl` binary. A protocol so tests can script its answers.
public protocol LaunchctlRunning: Sendable {
    func run(_ arguments: [String]) async throws -> CommandResult
}

public struct ProcessLaunchctlRunner: LaunchctlRunning {
    public init() {}

    public func run(_ arguments: [String]) async throws -> CommandResult {
        try await Self.runTool(executable: "/bin/launchctl", arguments: arguments)
    }

    /// Runs any executable and captures its output.
    public static func runTool(executable: String, arguments: [String]) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr

            // Pipes are drained on their own queues: `launchctl print` output can
            // exceed the pipe buffer, which would block the child forever.
            let output = OutputCollector()
            let group = DispatchGroup()
            for (pipe, keyPath) in [(stdout, \OutputCollector.out), (stderr, \OutputCollector.err)] {
                group.enter()
                let handle = pipe.fileHandleForReading
                DispatchQueue.global().async {
                    output.set(keyPath, handle.readDataToEndOfFile())
                    group.leave()
                }
            }
            group.enter()
            process.terminationHandler = { _ in group.leave() }

            do {
                try process.run()
            } catch {
                // Closing the write ends lets the reader queues finish.
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                continuation.resume(throwing: error)
                return
            }
            group.notify(queue: .global()) {
                let (out, err) = output.snapshot()
                continuation.resume(returning: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: String(decoding: out, as: UTF8.self),
                    stderr: String(decoding: err, as: UTF8.self)
                ))
            }
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    var out = Data()
    var err = Data()

    func set(_ keyPath: ReferenceWritableKeyPath<OutputCollector, Data>, _ data: Data) {
        lock.withLock { self[keyPath: keyPath] = data }
    }

    func snapshot() -> (Data, Data) {
        lock.withLock { (out, err) }
    }
}

/// The launchd operations Tender needs, separate from `Launchctl` so the
/// reconciler can be unit tested without touching real launchd.
public protocol LaunchdControlling: Sendable {
    func bootstrap(plistURL: URL) async throws
    func bootout(label: String) async throws
    func kickstart(label: String, kill: Bool) async throws
    func enable(label: String) async throws
    func disable(label: String) async throws
    func print(label: String) async throws -> JobInfo?
    func listLabels(prefix: String) async throws -> [String]
}

/// Async wrapper over `/bin/launchctl` for one domain.
public struct Launchctl: LaunchdControlling {
    public let domain: LaunchdDomain
    private let runner: any LaunchctlRunning

    public init(domain: LaunchdDomain, runner: any LaunchctlRunning = ProcessLaunchctlRunner()) {
        self.domain = domain
        self.runner = runner
    }

    private func serviceTarget(_ label: String) -> String { "\(domain.target)/\(label)" }

    private func check(_ arguments: [String], target: String) async throws {
        let result = try await runner.run(arguments)
        guard result.exitCode == 0 else { throw LaunchctlError.from(result, target: target) }
    }

    /// Throws `.alreadyLoaded` if the plist's job is already in the domain.
    /// launchctl reports that as a generic I/O error, so it is confirmed with a print.
    public func bootstrap(plistURL: URL) async throws {
        do {
            try await check(["bootstrap", domain.target, plistURL.path()], target: plistURL.path())
        } catch LaunchctlError.ioError(let message) {
            if let label = Self.label(ofPlistAt: plistURL), try await print(label: label) != nil {
                throw LaunchctlError.alreadyLoaded(label)
            }
            throw LaunchctlError.ioError(message)
        }
    }

    /// Throws `.notFound` if the job is not loaded.
    public func bootout(label: String) async throws {
        let target = serviceTarget(label)
        let result = try await runner.run(["bootout", target])
        // 36 is EINPROGRESS: launchd accepted the request and is still stopping the job.
        guard result.exitCode == 0 || result.exitCode == 36 else {
            throw LaunchctlError.from(result, target: target)
        }
    }

    public func kickstart(label: String, kill: Bool) async throws {
        let target = serviceTarget(label)
        try await check(["kickstart"] + (kill ? ["-k"] : []) + [target], target: target)
    }

    public func enable(label: String) async throws {
        let target = serviceTarget(label)
        try await check(["enable", target], target: target)
    }

    public func disable(label: String) async throws {
        let target = serviceTarget(label)
        try await check(["disable", target], target: target)
    }

    /// Returns nil if the job is not loaded.
    public func print(label: String) async throws -> JobInfo? {
        let target = serviceTarget(label)
        let result = try await runner.run(["print", target])
        guard result.exitCode == 0 else {
            let error = LaunchctlError.from(result, target: target)
            if case .notFound = error { return nil }
            throw error
        }
        return JobInfo(output: result.stdout)
    }

    public func listLabels(prefix: String) async throws -> [String] {
        let result = try await runner.run(["print", domain.target])
        guard result.exitCode == 0 else { throw LaunchctlError.from(result, target: domain.target) }
        return parseServiceLabels(domainOutput: result.stdout).filter { $0.hasPrefix(prefix) }.sorted()
    }

    private static func label(ofPlistAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["Label"] as? String
    }
}
