# Milestone 5+ — Later phases (roadmap)

Less detailed than milestones 1–4; each item gets its own plan when it starts.
Order reflects dependencies.

## 5a. Health checks
- Probes per service: HTTP, TCP, exec; interval, timeout, thresholds.
- Run by the node agent; results in heartbeats, API, app, MCP, `/metrics`.
- Readiness gates everything below.

## 5b. Service discovery
- Registry of healthy endpoints (`service → [node:port]`) on the head, cached on
  nodes.
- Small DNS server: `<svc>.svc.tender.internal`.
- Env injection at launch (`MONGO_URL=mongodb://${svc:mongo}`).
- Port allocation per instance.

## 5c. Declarative manifests
- `tender apply -f services.yaml` (format in DESIGN.md §11); diff and dry-run.

## 5d. Rolling deploys
- Surge instances on extra stable slot labels + allocated ports; start new →
  healthy N times → register → deregister + drain old → bootout.
- `maxSurge` / `maxUnavailable`, automatic rollback on failed health.
- Stateful services keep `recreate`.

## 5e. Load balancer
- Consumes the discovery registry; added when a service needs it.

## 5f. Head failover (optional)
- Uses the mesh-ready transport: failure detection between nodes (SWIM-style)
  and leader election; evaluate apple/swift-cluster-membership vs our own.
- The head stays cheap to rebuild, so failover = elect a node, restore the CA
  key, rebuild the registry from reports.

## Unscheduled
- Push updates to the app (SSE/WebSocket) instead of polling.
- Peer-to-peer release distribution between nodes.
- Cross-node health probes.
