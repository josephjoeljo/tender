import Foundation
import Hummingbird
import TenderCore

/// A request that can't be fulfilled, as an HTTP status plus a stable error code.
struct APIFailure: Error {
    var status: HTTPResponse.Status
    var code: String
    var message: String
}

/// The operations behind the `/v1/processes` endpoints.
struct ProcessController: Sendable {
    let environment: TenderEnvironment
    let store: StateStore
    let reconciler: Reconciler

    func list() async throws -> ProcessList {
        try await reconciler.status()
    }

    /// Idempotent: starting an unchanged running service does nothing.
    func start(_ spec: ServiceSpec) async throws -> ProcessList {
        try validate(spec)
        try store.upsert(spec)
        return try await finish(try await reconciler.reconcile(), service: spec.name)
    }

    func start(service: String) async throws -> ProcessList {
        try requireExisting(service, try store.setDesired(.running, service: service))
        return try await finish(try await reconciler.reconcile(), service: service)
    }

    /// Idempotent for a known service. An unknown name is a 404: it is probably a typo.
    func stop(service: String) async throws -> ProcessList {
        try requireExisting(service, try store.setDesired(.stopped, service: service))
        return try await finish(try await reconciler.reconcile(), service: service)
    }

    /// Also starts a stopped service.
    func restart(service: String) async throws -> ProcessList {
        try requireExisting(service, try store.setDesired(.running, service: service))
        return try await finish(try await reconciler.restart(service: service), service: service)
    }

    /// Idempotent: deleting an unknown service succeeds, since it is already gone.
    func delete(service: String) async throws -> ProcessList {
        try store.deleteService(service)
        return try await finish(try await reconciler.reconcile(), service: service)
    }

    func collectGarbage() async throws -> ProcessList {
        let report = try await reconciler.collectGarbage()
        if let failure = report.failures.first {
            throw APIFailure(status: .internalServerError, code: "launchd_failed",
                             message: "\(failure.label): \(failure.message)")
        }
        return try await reconciler.status()
    }

    private func requireExisting(_ service: String, _ exists: Bool) throws {
        guard exists else {
            throw APIFailure(status: .notFound, code: "service_not_found", message: "No service named '\(service)'.")
        }
    }

    private func finish(_ report: ReconcileReport, service: String) async throws -> ProcessList {
        let prefix = "\(environment.serviceLabelPrefix).\(service)."
        if let failure = report.failures.first(where: { $0.label.hasPrefix(prefix) }) {
            throw APIFailure(status: .internalServerError, code: "launchd_failed",
                             message: "\(failure.label): \(failure.message)")
        }
        return try await reconciler.status()
    }

    private func validate(_ spec: ServiceSpec) throws {
        guard ServiceSpec.isValidName(spec.name) else {
            throw APIFailure(status: .badRequest, code: "invalid_name",
                             message: "Service names may only use letters, digits, '-' and '_', up to 64 characters.")
        }
        guard (1...64).contains(spec.instances) else {
            throw APIFailure(status: .badRequest, code: "invalid_instances",
                             message: "instances must be between 1 and 64.")
        }
        let path: String
        switch spec.program {
        case .executable(let executable):
            guard executable.hasPrefix("/") else {
                throw APIFailure(status: .badRequest, code: "invalid_executable",
                                 message: "'\(executable)' is not an absolute path.")
            }
            path = executable
        case .release(let sha12):
            path = environment.releaseBinary(service: spec.name, sha12: sha12).path(percentEncoded: false)
        }
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw APIFailure(status: .badRequest, code: "invalid_executable",
                             message: "'\(path)' does not exist or is not executable.")
        }
    }
}

/// Routes of the local HTTP/JSON API. The head serves the same API in milestone 2.
func makeRouter(controller: ProcessController) -> Router<BasicRequestContext> {
    let router = Router()

    router.get("/v1/processes") { _, _ in
        await respond { try await controller.list() }
    }
    router.post("/v1/processes") { request, _ in
        await respond {
            var request = request
            let body = try await request.collectBody(upTo: 1 << 20)
            let spec: ServiceSpec
            do {
                spec = try JSONDecoder().decode(ServiceSpec.self, from: Data(body.readableBytesView))
            } catch {
                throw APIFailure(status: .badRequest, code: "invalid_body", message: "Expected a ServiceSpec: \(error)")
            }
            return try await controller.start(spec)
        }
    }
    router.post("/v1/processes/:name/:action") { _, context in
        await respond {
            let name = try context.parameters.require("name")
            switch try context.parameters.require("action") {
            case "start": return try await controller.start(service: name)
            case "stop": return try await controller.stop(service: name)
            case "restart": return try await controller.restart(service: name)
            case let action:
                throw APIFailure(status: .notFound, code: "unknown_action", message: "Unknown action '\(action)'.")
            }
        }
    }
    router.delete("/v1/processes/:name") { _, context in
        await respond { try await controller.delete(service: try context.parameters.require("name")) }
    }

    router.post("/v1/gc") { _, _ in
        await respond { try await controller.collectGarbage() }
    }

    // Part of the API surface, delivered by later milestone 1 steps (D, E, F).
    router.get("/v1/processes/:name/logs") { _, _ in notImplemented("logs") }
    router.get("/v1/releases/:service") { _, _ in notImplemented("releases") }
    router.post("/v1/releases/:service/rollback") { _, _ in notImplemented("rollback") }
    router.post("/v1/adopt") { _, _ in notImplemented("adopt") }

    return router
}

private func respond(_ operation: () async throws -> ProcessList) async -> Response {
    do {
        return json(try await operation(), status: .ok)
    } catch let failure as APIFailure {
        return json(APIErrorBody(code: failure.code, message: failure.message), status: failure.status)
    } catch {
        return json(APIErrorBody(code: "internal", message: "\(error)"), status: .internalServerError)
    }
}

private func notImplemented(_ feature: String) -> Response {
    json(APIErrorBody(code: "not_implemented", message: "\(feature) is not implemented yet."), status: .notImplemented)
}

private func json(_ value: some Encodable, status: HTTPResponse.Status) -> Response {
    let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
    return Response(
        status: status,
        headers: [.contentType: "application/json"],
        body: ResponseBody(byteBuffer: ByteBuffer(bytes: data))
    )
}
