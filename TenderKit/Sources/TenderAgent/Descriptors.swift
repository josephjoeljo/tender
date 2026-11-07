import Foundation
import ProcessMetrics
import TenderCore

extension ProcessController {
    /// The ports, open files and descriptor counts of one running instance and its children.
    func descriptors(service: String, instance: Int) async throws -> ProcessDescriptors {
        let processes = try await list().processes.filter { $0.service == service }
        guard !processes.isEmpty else {
            throw APIFailure(status: .notFound, code: "not_found", message: "No service or adopted job named '\(service)'.")
        }
        guard let process = processes.first(where: { $0.instance == instance }) else {
            throw APIFailure(status: .notFound, code: "not_found",
                             message: "'\(service)' has no instance \(instance). It has \(processes.map { String($0.instance) }.joined(separator: ", ")).")
        }
        guard let pid = process.pid else {
            throw APIFailure(status: .conflict, code: "not_running", message: "'\(service)' #\(instance) isn't running.")
        }
        guard let descriptors = DescriptorReader.read(service: service, instance: instance, node: process.node, pid: pid) else {
            throw APIFailure(status: .forbidden, code: "unreadable",
                             message: "Couldn't read pid \(pid)'s descriptors: it exited, or tenderd runs as a user that can't inspect it.")
        }
        return descriptors
    }
}
