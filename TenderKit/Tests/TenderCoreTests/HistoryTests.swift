import Foundation
import Testing
import TenderCore

@Test(arguments: [
    ("POST", "/v1/processes/api/restart", "restart", "api"),
    ("DELETE", "/v1/processes/api", "delete", "api"),
    ("PUT", "/v1/secrets/api/MONGO_PASSWORD", "set secret", "api/MONGO_PASSWORD"),
    ("POST", "/v1/releases/api/rollback", "rollback", "api"),
    ("DELETE", "/v1/adopt/homebrew.mxcl.mongodb-community", "abandon", "homebrew.mxcl.mongodb-community"),
    ("PUT", "/v1/nodes/mac-mini/labels", "label node", "mac-mini"),
    ("POST", "/v1/apply", "apply", nil),
    ("PUT", "/v1/settings/history", "set history retention", nil),
    ("PATCH", "/v2/odd", "PATCH /v2/odd", nil),
] as [(String, String, String, String?)])
func auditRecordsNameTheirActionAndTarget(method: String, path: String, action: String, target: String?) {
    let record = AuditRecord(time: Date(), who: "alice", method: method, path: path, status: 200)
    #expect(record.action == action)
    #expect(record.target == target)
}

@Test func aStartsTargetComesFromItsDetail() {
    let record = AuditRecord(time: Date(), who: "a", method: "POST", path: "/v1/processes", status: 502, detail: "service api on mac-1")
    #expect(record.action == "start" && record.target == "api" && !record.succeeded)
}

@Test func auditQueriesFilter() {
    let now = Date()
    let ok = AuditRecord(time: now, who: "alice", method: "POST", path: "/v1/processes/api/restart", status: 200, node: "mac-1")
    let bad = AuditRecord(time: now.addingTimeInterval(-7200), who: "bob", method: "DELETE", path: "/v1/processes/worker", status: 404)
    #expect(AuditQuery().matches(ok) && AuditQuery().matches(bad))
    #expect(!AuditQuery(failedOnly: true).matches(ok) && AuditQuery(failedOnly: true).matches(bad))
    #expect(AuditQuery(who: "bob").matches(bad) && !AuditQuery(who: "bob").matches(ok))
    #expect(AuditQuery(about: "API").matches(ok) && AuditQuery(about: "mac-1").matches(ok) && !AuditQuery(about: "api").matches(bad))
    #expect(!AuditQuery(since: now.addingTimeInterval(-3600)).matches(bad))
    #expect(AuditQuery(limit: 0).limit == 1 && AuditQuery(limit: 99_999).limit == AuditQuery.maxLimit)
    #expect(AuditList(records: [ok, bad]).failures == 1)
}

@Test func labelUpdatesAreValidated() {
    let current = ["rack": "a"]
    #expect(NodeLabels.problem(with: NodeLabelsUpdate(set: ["name": "Prod mini", "zone/home": "basement"]), current: current) == nil)
    #expect(NodeLabels.problem(with: NodeLabelsUpdate(set: ["role": "head"]), current: current)?.contains("set by Tender") == true)
    #expect(NodeLabels.problem(with: NodeLabelsUpdate(set: ["Rack": "b"]), current: current) != nil)
    #expect(NodeLabels.problem(with: NodeLabelsUpdate(set: ["rack": " b"]), current: current) != nil)
    #expect(NodeLabels.problem(with: NodeLabelsUpdate(set: ["rack": "b\nc"]), current: current) != nil)
    #expect(NodeLabels.problem(with: NodeLabelsUpdate(set: ["rack": "b"], remove: ["rack"]), current: current) != nil)
    let many = Dictionary(uniqueKeysWithValues: (0...NodeLabels.maxCount).map { ("k\($0)", "v") })
    #expect(NodeLabels.problem(with: NodeLabelsUpdate(set: many), current: [:])?.contains("at most") == true)
    #expect(NodeLabelsUpdate(set: ["b": "2"], remove: ["rack"]).applied(to: current) == ["b": "2"])

    var info = NodeInfo(id: NodeID("1234"), version: "1", macOS: "", hardware: "", labels: ["role": "head"], hostname: "mac-mini")
    #expect(info.displayName == "mac-mini" && info.userLabels.isEmpty)
    info.labels["name"] = "Prod"
    #expect(info.displayName == "Prod" && info.userLabels == ["name": "Prod"])
}
