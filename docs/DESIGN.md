# Tender — Design

Status: draft, phase 1 in progress. See `CLAUDE.md` for conventions and milestones.

## 1. Goals

- Manage any launchd process (Go services, MongoDB, Postgres, workers) across a
  fleet of Macs from one head node.
- Centralized, durable, searchable logs from every machine.
- AI agents can inspect and operate the cluster safely, through the CLI and a
  Claude Code skill, with the same token scopes and audit as people.
- Prometheus metrics.
- Later: health checks, service discovery, rolling deploys, load balancing.

Non-goals (for now): Linux support, containers/VMs, HA control plane (Raft),
cross-node volume migration.

## 2. Topology

```
 CLI / app / AI agents (skill)
          │  (tailnet + mTLS)
          ▼
 ┌──────────── Head node (tenderd --role head) ────────────┐
 │ API server · Node registry · Command router             │
 │ Log store (SQLite/day + FTS5) · Audit log · /metrics    │
 │ Internal CA                                             │
 └──────────────────────────────────────────────────────────┘
          ▲  mTLS (tenderd agent port) — workers dial the head; every node
          │  also listens, so nodes can reach each other
 ┌────────┴────────┐  ┌─────────────────┐  ┌─────────────────┐
 │ Mac 1 (worker)  │  │ Mac 2 (worker)  │  │ Mac 3 (worker)  │
 │ tenderd agent   │  │ tenderd agent   │  │ tenderd agent   │
 │   └ launchd     │  │   └ launchd     │  │   └ launchd     │
 │     └ api, api  │  │     └ api, wkr  │  │     └ mongod, pg│
 └─────────────────┘  └─────────────────┘  └─────────────────┘
```

The head also runs a worker agent; a one-Mac cluster is valid.

## 3. Security

Two independent layers:

1. **Tailscale**: every node listens only on its tailnet IP. ACLs:
   - `tag:tender-head`, `tag:tender-worker` ↔ each other on 7070 (tenderd
     actor transport, mTLS)
   - service-to-service traffic between nodes on each service's own ports
   - admins / `tag:tender-agents` → head API port, `/metrics`
2. **mTLS**: head runs an internal CA.
   - `tender join <head> --token <t>`: worker generates key locally, sends CSR,
     receives cert with SAN = node ID. Key never leaves the worker.
   - Join tokens are single-use, short-lived, minted by `tender token create`.
3. **Cross-check**: every node, on every inbound connection, resolves the peer
   IP via Tailscale LocalAPI `whois` and requires it to match the cert's node ID.

API clients authenticate with bearer tokens scoped `read` or `write`.
All mutating calls go to an audit log (who, what, when, result).

## 4. Internal RPC: distributed actors

Head↔worker traffic uses Swift distributed actors (`import Distributed`) over a
custom `DistributedActorSystem`, `TenderActorSystem`. Public interfaces (CLI/app
API, `/metrics`) stay HTTP/JSON so non-Swift tools can use them.

### Contract: `@Resolvable` distributed protocols (decision 2a)

A distributed actor must name its actor system, and both sides need each other's
interface (head calls `NodeAgent`; workers call `HeadRegistry`). To avoid each
side importing the other's implementation, the contract lives in
`TenderProtocol` (layer 0) as `@Resolvable` protocols, generic over any system
whose serialization requirement is `Codable`:

```swift
// TenderProtocol — contract only, no transport
@Resolvable
public protocol NodeAgentProtocol: DistributedActor
    where ActorSystem: DistributedActorSystem<any Codable> {
    distributed func apply(_ cmd: AgentCommand) async throws -> [InstanceStatus]
    distributed func status() async throws -> [InstanceStatus]
}

@Resolvable
public protocol HeadRegistryProtocol: DistributedActor
    where ActorSystem: DistributedActorSystem<any Codable> {
    distributed func heartbeat(_ hb: Heartbeat) async throws
    distributed func ingest(_ batch: LogBatch) async throws -> UInt64  // acked seq
}

// TenderAgent — implementation
distributed actor NodeAgent: NodeAgentProtocol {
    typealias ActorSystem = TenderActorSystem
    ...
}

// TenderHead — caller, without importing TenderAgent
let agent = try $NodeAgentProtocol.resolve(id: .agent(on: "mac-3"), using: system)
try await agent.apply(.restart(service: "api"))
```

Milestone 2 starts with a spike: two `TenderActorSystem`s over loopback,
cross-module `$NodeAgentProtocol.resolve`, on the macOS version our Macs run
(raise the deployment target if stub resolution needs it).

Fallback (2b) if the spike fails: move `TenderActorSystem` to a transport layer
under `TenderProtocol` and declare thin concrete actors there that forward to a
handler protocol implemented by `TenderAgent` / `TenderHead`. Costs: duplicated
signatures, and the contract module (and anything importing it) links NIO.

Why not the alternatives:
- **apple/swift-distributed-actors (ClusterSystem)**: still 1.0.0-beta.3 (2022),
  Sendable warnings under Swift 6, and assumes full-mesh peer dialing.
- **gRPC**: works, but needs protobuf codegen and duplicate model types.

`TenderActorSystem` responsibilities:
- Transport: SwiftNIO + NIOSSL (mTLS). Any node can dial any node; one
  connection per peer pair, used in both directions (multiplexed by call ID).
- Framing: length-prefixed envelopes `{callID, actorID, target, args, ...}`,
  JSON-encoded `Codable` arguments (switch to a binary codec later if needed).
- Identity: `ActorID = {node, name}`; well-known names `agent` and `registry`.
- Dispatch via `executeDistributedTarget`; replies matched by call ID.
- Reconnect with backoff; in-flight calls fail with a retryable error.
- Handshake: protocol version + node ID (cross-checked with mTLS cert + Tailscale whois).

Compatibility rules: never change or remove a shipped `distributed func`; add a
new one instead. Version mismatches are rejected at handshake.

Testing: `LocalTestingDistributedActorSystem` for logic; in-process
`TenderActorSystem` pairs over loopback for transport tests.

The head's built-in worker is the same `NodeAgent` implementation, resolved locally, so a
one-Mac cluster and a multi-Mac cluster share one code path.

### Mesh-ready (node ↔ node)

We build our own transport rather than adopt apple/swift-distributed-actors
(beta since 2022, ~2 years without updates). Rules:

1. `ActorID` always includes the node (`{node: "mac-3", name: "agent"}`), so any
   node can address any actor.
2. Every node runs a listener on its tailnet IP (not just the head). All nodes
   hold certs from the same internal CA, so peer mTLS needs no extra setup.
3. Node → address resolution goes through a pluggable `NodeResolver`.
   Phase 1: ask the head's registry. Later: gossiped membership.
4. Connections are lazy: calling an actor on an unconnected node dials it.
   One connection per peer pair, reused in both directions.

Future uses this enables:
- **Head failover**: workers detect head loss and elect a new head (SWIM-style
  failure detection + leader election; evaluate apple/swift-cluster-membership
  or write our own).
- **Peer-to-peer release distribution**: fetch a release from a neighbor that
  already has it.
- **Cross-node health probes**: check a service from another node's vantage.
- **Drain/handoff**: node-to-node coordination during maintenance.

## 5. Process management

### Commands (phase 1)

```
tender start <name> [--node n] [--instances k] [--env K=V] -- <exec> [args...]
tender stop|restart|delete <name> [--node n]
tender list                      # all nodes, one table
tender adopt <launchd-label> --node n
tender nodes
tender logs <name> [-f] [--node n] [--since 1h] [--grep text]
```

### Agent flow

1. Receive command → persist to local desired-state file (`/opt/tender/state.json`
   or SQLite) so it survives head outages and reboots.
2. Render plist: `Label`, `ProgramArguments`, `EnvironmentVariables`,
   `KeepAlive`, `RunAtLoad`, `StandardOutPath`/`StandardErrorPath`
   (`/var/log/tender/<service>/<instance>.{out,err}.log`), `WorkingDirectory`,
   `UserName = _tender` (never root; per-service `--user` override).
   Labels are stable per instance slot (`svc.<service>.<i>`) and reused.
3. Write to `/Library/LaunchDaemons/com.olympsis.tender.svc.<svc>.<i>.plist`.
4. `launchctl bootstrap system <plist>`; stop = `bootout`; restart = `kickstart -k`.
5. Report status by parsing `launchctl print system/<label>` (state, pid,
   last exit code) + libproc for CPU/RSS.

### Adopted jobs

Adopted labels are read and controlled (start/stop/restart/logs) but their plist
is not rewritten unless the user runs `tender adopt --takeover`.

Logs: `tender adopt <label> --log-path <file>` (repeatable) tails the given files
(e.g. mongod's own log). Without it, Tender reads `StandardOutPath` /
`StandardErrorPath` from the job's plist.

### Service user

Dev mode (`--dev`) uses the `gui/<uid>` domain, where launchd ignores
`UserName`: services run as you, not `_tender`. Tests that assert the service
user must run against the `system` domain.

`_tender` is a dedicated hidden system user + group created at install. Release
dirs and log dirs are readable/writable by it; `/opt/tender` itself stays
root-owned.

### Background Items notifications

macOS shows "Background Items Added" when new launch daemons appear. Tender:
- reuses stable per-instance labels instead of minting labels per release, and
- ships a configuration profile (Service Management managed login items) that
  allow-lists the `com.olympsis.tender.` label prefix.
Open: confirm whether a manually installed profile is honored or MDM is needed.

## 6. Release sources (binary folder)

Milestones 1–2: a local folder on each Mac (for remote starts in milestone 2,
binaries are placed on the worker by hand). Milestone 3: Tender fetches
releases from GCP Artifact Registry / GCS / S3 (sha256-verified) into the same
`releases/` layout, so everything downstream is unchanged.

```
/opt/tender/bin/<service>/<binary>        ← drop new builds here
/opt/tender/releases/<service>/<sha12>/   ← immutable copies Tender runs from
```

1. FSEvents fires for `/opt/tender/bin/`.
2. Debounce: wait until size + mtime are stable for ~2s (recommend writers use
   write-to-temp + rename).
3. sha256 → if new, copy to `releases/<service>/<sha12>/` (new inode).
4. Optionally `codesign --verify`. When Tender fetched the binary itself, strip
   `com.apple.quarantine` (`xattr -d`).
5. Re-render plists for that service to point at the new path, restart instances.
   (Phase 5: becomes a rolling deploy.)
6. Keep last N releases (default 5); `tender rollback <service> [--to sha]`.

Why copy instead of in place: overwriting a running Mach-O on Apple Silicon can
invalidate the cached code signature and the next exec gets SIGKILLed.

## 7. Logging

### Worker
- Tail `*.out.log` / `*.err.log` from persisted offsets (handle rotation by inode).
- Append to spool SQLite (WAL):
  `spool(seq INTEGER PRIMARY KEY, node_ts, service, instance, stream, line)`.
- Stream batches to head; on ACK(seq) delete `<= seq` (keep a small tail).
- Spool limits: max size (default 1 GiB) and max age (default 7 days).
  When exceeded, drop oldest unacked rows, count them in
  `tender_log_spool_dropped_total`, and record a gap marker so the head can show
  "N lines dropped" for that window.
- Rotate the raw files Tender owns (size-based) so disks don't fill.

### Head
- Per-day file `logs/logs-YYYY-MM-DD.db`, chosen by `ingest_ts`:
  `logs(node, seq, node_ts, ingest_ts, service, instance, stream, line, UNIQUE(node, seq))`
  + FTS5 external-content table on `line`.
- Batch inserts in transactions; ACK highest contiguous seq per node.
- Queries ATTACH the relevant day files. Retention = delete old files.
- Nightly offload: closed day files are copied to GCS/S3 (see §10).
- Live follow: subscribers get lines as they're ingested.

### Ordering and clock skew

Each Mac has its own clock (NTP-synced, but it can drift, lag after sleep, or
jump on resync), so timestamps from different nodes are not comparable exactly.
Every line carries three values:

| Field | Source | Guarantee | Used for |
|---|---|---|---|
| `seq` | worker spool counter | strictly increasing per node, never jumps | order within a node, ACKs, dedupe |
| `node_ts` | worker wall clock | human time; may be skewed or jump | display, `--since` filters |
| `ingest_ts` | head clock on arrival | one clock for all lines | day-file partitioning, retention, tie-break |

Rules:
- Within one node: order by `seq` (always correct, even if `node_ts` went backwards).
- Across nodes: order by `node_ts`, presented as approximate, and the CLI,
  app and agent skill say so.
- Day files are chosen by `ingest_ts`, so a node with a wrong clock can't write
  into the wrong day.

Skew detection: heartbeats carry the worker's clock; the head estimates
`offset = head_now - node_ts - rtt/2` and exports
`tender_node_clock_skew_seconds`. `tender nodes` and the app warn when
|skew| > 1s.

## 8. Metrics (`/metrics` on head)

| Metric | Type | Labels |
|---|---|---|
| `tender_node_up` | gauge | node |
| `tender_node_last_heartbeat_seconds` | gauge | node |
| `tender_node_clock_skew_seconds` | gauge | node |
| `tender_process_up` | gauge | node, service, instance |
| `tender_process_restarts_total` | counter | node, service, instance |
| `tender_process_cpu_seconds_total` | counter | node, service, instance |
| `tender_process_resident_bytes` | gauge | node, service, instance |
| `tender_log_lines_ingested_total` | counter | node |
| `tender_log_spool_backlog` | gauge | node |
| `tender_log_spool_dropped_total` | counter | node |
| `tender_release_deploys_total` | counter | service, result |

## 9. Agents

Agents use the `tender` CLI through a Claude Code skill
(`~/.claude/skills/tender/SKILL.md`): read first, bounded log queries (`-n`,
`--since`, `--grep`), `--json` for parsing, and confirmation before any mutating
command. The head enforces the rest: an agent gets its own API token, a `read`
token can't change anything, and every mutating call is audited under the
token's name.

An MCP server was planned and shelved (`docs/plans/milestone-4.md`); revisit it
when an agent without a shell needs the cluster, or when limits must be enforced
by the head rather than asked for.

## 10. Head state (cheap to lose)

- Workers are the source of truth for their own desired state (persisted
  locally) and keep running without the head.
- Head registry = cache rebuilt from worker reports on reconnect.
- Losing the head loses: API tokens (re-issue) and anything since the last
  offload. Nightly, the head copies each closed day's `logs-YYYY-MM-DD.db` and
  the audit log to GCS/S3, so log history survives losing the head.
- Must be backed up: the internal CA private key (else every node re-joins).
  Store in the head's Keychain plus an offline backup.

## 11. Later phases

- **Health checks**: http/tcp/exec probes run by the agent; readiness gates
  discovery and deploys.
- **Service discovery**: registry of healthy endpoints; small DNS server for
  `<svc>.svc.tender.internal`; env injection (`MONGO_URL=...`).
- **Rolling deploys**: surge instances use extra stable slot labels + allocated
  ports so old/new run side by side; start new → healthy N times → register → deregister + drain old →
  bootout; `maxSurge`/`maxUnavailable`; auto-rollback on failed health.
- **Declarative manifests** (`tender apply -f`):

```yaml
kind: Service
name: api
replicas: 3
binary: api                 # from /opt/tender/bin/api/
exec: ["./api", "--port", "${PORT}"]
env: { MONGO_URL: "mongodb://${svc:mongo}" }
health: { http: "/healthz", interval: 5s, threshold: 3 }
rollout: { maxSurge: 1, maxUnavailable: 0 }
placement: { labels: { role: app } }
---
kind: Service
name: mongo
replicas: 1
strategy: recreate
placement: { node: mac-3 }
```

## 12. Prior art

- SRM (Swift, PM2-like, single machine, ShellOut-based)
- macpmd (Python, PM2 on launchd/systemd)
- Process Compose (Go, YAML, health checks, MCP server, single machine)
- HashiCorp Nomad (multi-node, raw_exec on macOS)
- apple/swift-distributed-actors and apple/swift-sample-distributed-actors-transport (reference for TenderActorSystem)
- emorydunn/LaunchAgent (Swift launchd plist library)
