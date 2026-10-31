import Foundation
import TenderCore

/// What `launchctl print <domain>/<label>` says about a job.
///
/// That output is not a stable API, so every field is optional and anything
/// unrecognized is ignored. Parsing never fails; an unexpected format produces
/// a mostly empty `JobInfo`.
public struct JobInfo: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        case running
        /// launchd is exec'ing the program through xpcproxy.
        case starting
        /// The process is gone and launchd will respawn it (throttled).
        case spawnScheduled
        case notRunning
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "running": self = .running
            case "xpcproxy", "spawning", "spawned": self = .starting
            case "spawn scheduled": self = .spawnScheduled
            case "not running", "exited": self = .notRunning
            default: self = .other(raw)
            }
        }
    }

    public var label: String?
    public var plistPath: String?
    public var state: State?
    public var program: String?
    public var arguments: [String] = []
    public var pid: Int32?
    /// How many times launchd has started the job since it was loaded.
    public var runs: Int?
    public var lastExitCode: Int32?
    /// For example "Killed: 9".
    public var lastTerminatingSignal: String?
    public var stdoutPath: String?
    public var stderrPath: String?

    public init(output: String) {
        var depth = 0
        var section: String?

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line == "}" {
                depth = max(0, depth - 1)
                if depth <= 1 { section = nil }
                continue
            }
            if line.hasSuffix("= {") {
                let name = line.dropLast(3).trimmingCharacters(in: .whitespaces)
                if depth == 0 {
                    label = name.split(separator: "/").last.map(String.init)
                } else if depth == 1 {
                    section = name
                }
                depth += 1
                continue
            }
            if depth == 2, section == "arguments" {
                arguments.append(line)
                continue
            }
            guard depth == 1, let separator = line.range(of: " = ") else { continue }
            let value = String(line[separator.upperBound...])

            switch line[..<separator.lowerBound] {
            case "path": plistPath = value
            case "state": state = State(value)
            case "program": program = value
            case "pid": pid = Int32(value)
            case "runs": runs = Int(value)
            case "stdout path": stdoutPath = value
            case "stderr path": stderrPath = value
            case "last terminating signal": lastTerminatingSignal = value
            case "last exit code":
                // A number, optionally followed by text ("78: EX_CONFIG"), or "(never exited)".
                lastExitCode = Int32(value.prefix { $0.isNumber || $0 == "-" })
            default: break
            }
        }
    }

    /// `runs` counts the first start too. launchd resets it when the job is booted out.
    public var restarts: Int { max((runs ?? 0) - 1, 0) }

    public var instanceState: InstanceState {
        switch state {
        case .running: .running
        case .starting: .starting
        case .spawnScheduled: .crashed
        case .notRunning:
            lastTerminatingSignal != nil || (lastExitCode ?? 0) != 0 ? .crashed : .stopped
        case .other, nil: pid != nil ? .running : .unknown
        }
    }
}

/// Extracts the labels of the `services = { ... }` block in `launchctl print <domain>`.
/// Rows look like `<pid or 0>  <exit status or ->  <label>`.
func parseServiceLabels(domainOutput: String) -> [String] {
    var labels: [String] = []
    var inServices = false
    for rawLine in domainOutput.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if !inServices {
            inServices = line == "services = {"
            continue
        }
        if line == "}" { break }
        let columns = line.split(whereSeparator: \.isWhitespace)
        if columns.count == 3 { labels.append(String(columns[2])) }
    }
    return labels
}
