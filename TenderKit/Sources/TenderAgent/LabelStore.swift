import Foundation
import Hummingbird
import TenderCore

/// The node's own labels, in `<configDirectory>/labels.json`. The node is their source of
/// truth: the head learns them when the node registers.
struct LabelStore: Sendable {
    let environment: TenderEnvironment
    /// Shared, since every caller makes its own `LabelStore`.
    private static let lock = NSLock()

    init(environment: TenderEnvironment) { self.environment = environment }

    var file: URL { environment.configDirectory.appending(path: "labels.json") }

    /// Empty when there's no file or it can't be read, so a bad edit never stops the node.
    func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let labels = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return labels.filter { NodeLabels.isValidKey($0.key) && NodeLabels.isValidValue($0.value) && !NodeLabels.reservedKeys.contains($0.key) }
    }

    func update(_ update: NodeLabelsUpdate) throws -> [String: String] {
        try Self.lock.withLock {
            let current = load()
            if let problem = NodeLabels.problem(with: update, current: current) {
                throw APIFailure(status: .badRequest, code: "invalid_labels", message: problem)
            }
            let labels = update.applied(to: current)
            try FileManager.default.createDirectory(at: environment.configDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(labels).write(to: file, options: .atomic)
            return labels
        }
    }
}
