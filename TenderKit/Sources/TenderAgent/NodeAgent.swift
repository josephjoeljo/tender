import Distributed
import Foundation
import Hummingbird
import TenderActorSystem
import TenderCore
import TenderProtocol

/// The node contract's implementation. The head reaches it with `$NodeAgentProtocol`,
/// including its own built-in worker, so a one-Mac cluster shares the same code path.
distributed actor NodeAgent: NodeAgentProtocol {
    typealias ActorSystem = TenderActorSystem
    private let controller: ProcessController

    init(controller: ProcessController, actorSystem: TenderActorSystem) {
        self.controller = controller
        self.actorSystem = actorSystem
    }

    private func translating<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let failure as APIFailure {
            throw NodeCallError(code: failure.code, message: failure.message, httpStatus: failure.status.code)
        }
    }

    distributed func apply(_ command: AgentCommand) async throws -> ProcessList {
        let controller = self.controller
        return try await translating {
            switch command {
            case .start(let spec): try await controller.start(spec)
            case .startExisting(let service): try await controller.start(service: service)
            case .stop(let service): try await controller.stop(service: service)
            case .restart(let service): try await controller.restart(service: service)
            case .delete(let service): try await controller.delete(service: service)
            case .collectGarbage: try await controller.collectGarbage()
            }
        }
    }

    distributed func status() async throws -> ProcessList {
        let controller = self.controller
        return try await translating { try await controller.list() }
    }

    distributed func releases(service: String) async throws -> ReleaseList {
        try await controller.releases.list(service: service)
    }

    distributed func rollback(service: String, to sha12: String?) async throws -> ProcessList {
        let controller = self.controller
        return try await translating { try await controller.rollback(service: service, to: sha12) }
    }

    distributed func adopt(_ request: AdoptRequest) async throws -> ProcessList {
        let controller = self.controller
        return try await translating { try await controller.adopt(request) }
    }

    distributed func forgetAdopted(label: String) async throws -> ProcessList {
        let controller = self.controller
        return try await translating { try await controller.forget(label: label) }
    }
}
