# Tender

Tender is a bare-metal process orchestrator for macOS, written in Swift. It brings
Kubernetes-style management (head node + worker nodes) to Macs without VMs or
containers, built on top of launchd. First user: the Olympsis backend
(Go API, MongoDB, Postgres, workers).

Full design: `docs/DESIGN.md`.

## Core principles

- **launchd supervises, Tender decides.** Tender never babysits processes itself.
  launchd handles keep-alive, crash restarts, and boot persistence. Tender writes
  plists and drives `launchctl` (`bootstrap`, `bootout`, `kickstart`).
- **macOS only.** No Linux/systemd abstraction. Use Apple APIs freely
  (FSEvents, libproc, Keychain, Network.framework where useful).
- **Workers are autonomous.** If the head is down, workers keep running their
  last-known workloads. The head is required for changes, not for uptime.
- **Agent-first.** Everything the CLI can do, the MCP server can do. Output to
  agents must be bounded (limits, time windows, errors first).

## Naming conventions

| Thing | Name |
|---|---|
| CLI | `tender` |
| Daemon (single binary) | `tenderd --role head\|worker` |
| Daemon launchd label | `com.olympsis.tender.agent` |
| Managed process labels | `com.olympsis.tender.svc.<service>.<instance>` |
| Metric prefix | `tender_` |
| Binaries (watched) | `/opt/tender/bin/<service>/` |
| Release copies | `/opt/tender/releases/<service>/<sha12>/` |
| Log spool (worker) | `/opt/tender/spool/` |
| Logs | `/var/log/tender/` |
| Config | `/etc/tender/` |
| Service user (runs managed processes) | `_tender` |

## Architecture (phase 1)

- **Head node**: public API server (HTTP/JSON), node registry, command routing,
  durable log store (SQLite), MCP server, Prometheus `/metrics`. The head also
  runs a worker agent, so a single Mac is a valid one-node cluster.
- **Worker node**: keeps a long-lived mTLS connection to the head carrying
  distributed actor calls in both directions, and also listens on its tailnet IP
  (agent port) so nodes can reach each other. Receives commands, reports state +
  heartbeats, ships logs. Services on different nodes talk to each other
  directly over the tailnet on their own ports.
- **Networking**: Tailscale (encryption, stable IPs, ACL tags `tag:tender-head`,
  `tag:tender-worker`) **and** mTLS (head runs an internal CA; workers get certs
  via `tender join --token`). Every node, on every inbound connection,
  cross-checks the peer cert's node ID against Tailscale LocalAPI `whois` for
  the peer IP.

## Key decisions

- **Binaries come from a folder** (`/opt/tender/bin/<service>/`) watched via
  FSEvents. Phase 1: a local folder on the (single) head node. Future: Tender
  fetches releases from GCP Artifact Registry / GCS / S3. On change: debounce until stable → sha256 → copy to
  `releases/<service>/<sha12>/` → restart instances from the new path. Keep last
  N releases for rollback.
  - When Tender itself fetches a binary, it strips `com.apple.quarantine`.
  - NEVER overwrite a running binary in place. On Apple Silicon the kernel caches
    code signatures per vnode; overwriting can SIGKILL the new process
    ("Killed: 9"). Always copy to a new path.
- **Durable logs**: worker tails each instance's stdout/stderr from saved offsets
  into a local SQLite spool (WAL) with per-node sequence numbers → streams to
  head → head ACKs highest seq → worker prunes. Lines carry `seq` (order within
  a node), `node_ts` (worker clock, display), `ingest_ts` (head clock, day-file
  choice); cross-node order is approximate; skew exported as
  `tender_node_clock_skew_seconds`. Head dedupes on `(node, seq)`,
  batch-inserts, indexes with FTS5. Retention via one SQLite file per day
  (`logs-YYYY-MM-DD.db`, queried with ATTACH); expiring = deleting a file.
- **Head is cheap to lose.** Workers are the source of truth for their own
  workloads; the head's registry is a cache rebuilt from worker reports. Losing
  the head loses only log history and audit trail. The one thing that must be
  backed up is the internal CA key (losing it = every node re-joins).
- **Log spool limits**: max size + max age per worker, drop-oldest when full,
  counted in `tender_log_spool_dropped_total`.
- **Prometheus**: head exposes one aggregated `/metrics` (tailnet only), labels
  `node`, `service`, `instance`. Per-process CPU/RSS via `proc_pid_rusage`
  (libproc) in worker heartbeats. Keep label cardinality low (no PIDs).
- **Adopt existing jobs**: `tender adopt <launchd-label> --node <n> [--log-path p]`
  brings existing launchd jobs (e.g. Homebrew mongod) under management. Without
  `--log-path`, logs come from the job's `StandardOutPath`/`StandardErrorPath`.
- **Managed processes never run as root.** Plists set `UserName = _tender`
  (dedicated service user, created at install); per-service override allowed.
- **Background Items allow-list.** macOS notifies when new launch daemons appear;
  allow-list the `com.olympsis.tender.` label prefix with a configuration
  profile (Service Management managed login items) and reuse stable
  per-instance labels.
- **Internal vs public traffic**: head↔worker traffic uses Swift distributed
  actors over our own `TenderActorSystem` (custom transport on the worker-dialed
  mTLS connection). Everything public stays plain HTTP/JSON: `TenderClient` API
  (CLI, app), MCP, `/metrics`. Rules for distributed actors:
  - The contract lives in `TenderProtocol` as `@Resolvable` distributed protocols
    (`NodeAgentProtocol`, `HeadRegistryProtocol`) constrained to
    `DistributedActorSystem<any Codable>`; no transport dependency. Concrete
    actors live in `TenderAgent` / `TenderHead`; callers use `$Protocol.resolve`.
    Fallback if the milestone-2 spike fails: thin forwarding actors (DESIGN.md §4).
  - Arguments/returns are `Codable` types from `TenderCore`/`TenderProtocol`.
  - Never change or remove a shipped `distributed func`; add new ones instead
    (calls are matched by mangled name). Connections start with a protocol
    version handshake; mismatches are rejected with a clear error.
  - Unit-test head↔worker logic with `LocalTestingDistributedActorSystem`.
  - The head's built-in worker is the same `NodeAgent`, called in-process.
  - Keep the transport mesh-ready: ActorIDs include the node, every node listens
    on its tailnet IP, addresses come from a pluggable `NodeResolver`, connections
    dial lazily (DESIGN.md §4, "Mesh-ready").
- **Stateful services** (Mongo, Postgres): pinned to a node, never rescheduled,
  `recreate` strategy only.

## Tech stack

- Swift 6, Swift Package Manager, macOS 15+, Xcode workspace (Xcode 16+)
- Testing: Swift Testing (`import Testing`, `@Test`, `#expect`)
- SwiftNIO + NIOSSL (mTLS), Hummingbird (public HTTP API)
- Swift `Distributed` (distributed actors) for head↔worker traffic, via our own
  `TenderActorSystem` (no grpc-swift, no apple/swift-distributed-actors)
- swift-argument-parser (CLI), swift-service-lifecycle (daemons), swift-log
- GRDB (SQLite, WAL, FTS5)
- swift-prometheus
- MCP Swift SDK (streamable HTTP transport)

## Repository layout

Open `Tender.xcworkspace` in Xcode. It contains:

```
Tender.xcworkspace        ← open this
TenderKit/                ← Swift package: every module + tenderd + tender CLI
  Package.swift
  Sources/
    # 0 Foundation
    TenderCore/           models (NodeID, ServiceSpec, InstanceStatus), TenderEnvironment paths
    TenderProtocol/       Codable messages + @Resolvable distributed protocols (the node contract)
    # 1 macOS platform — NO networking deps
    LaunchdKit/           plist rendering + launchctl wrapper
    ProcessMetrics/       libproc CPU/RSS
    FileWatch/            FSEvents + debounce/stability detection
    LogTail/              offset-tracked tailing, rotation by inode
    # 2 Features
    TenderActorSystem/    custom DistributedActorSystem over NIO + mTLS (internal traffic only)
    TenderAgent/          worker runtime
    TenderLogStore/       head log store (per-day SQLite + FTS5)
    TenderPKI/            internal CA, CSR signing, join tokens
    TenderScheduler/      placement (phase 1: explicit --node)
    TenderMetrics/        Prometheus registry
    TenderClient/         typed client for the head API (CLI, MCP, app all use this)
    TenderMCP/            MCP tools (hosted by head; `tender mcp` = stdio bridge)
    TenderHead/           composes head services
    # 3 Executables — thin: parse args, wire, run
    tenderd/              daemon, --role head|worker, --dev
    tender/               CLI
  Tests/
App/
  TenderApp.xcodeproj     Xcode project (objectVersion 77: TenderApp/ is a synchronized folder,
                          so new files are picked up automatically; Info.plist is generated)
  TenderApp/              SwiftUI app: MenuBarExtra (glance) + Window "dashboard"
```

Layering rule: a target only imports targets in its own layer or below. The app
only imports `TenderClient` and `TenderCore` — never head/agent internals.

### Dev mode

`tenderd --dev` / `TenderEnvironment.development` uses
`~/Library/Application Support/Tender/`, `~/Library/LaunchAgents`, and the
`gui/<uid>` launchd domain so everything runs from Xcode without sudo. In dev
mode services run as you (launchd ignores `UserName` in the gui domain).
Production uses `/opt/tender`, `/Library/LaunchDaemons`, and the `system` domain.

## Milestones

Detailed plans: `docs/plans/milestone-{1..5}.md`.

1. **Single-node agent** — pm2 parity on launchd: start/stop/restart/delete/list,
   logs, adopt, binaries-folder watching. Done.
2. **Head + join** (binaries placed on workers by hand for now) — spike: `@Resolvable` across modules over loopback on our
   macOS version; then TenderActorSystem, node registration, mTLS, remote commands,
   cluster-wide `tender list`.
   Plus the head's public HTTP/JSON API + `TenderClient`, and the TenderApp menu
   bar (cluster health at a glance, quick start/stop/restart).
3. **Log shipping + releases** — spool, ACKs, daily SQLite files, FTS5, nightly
   offload of closed day files to GCS/S3, `tender logs -f` across nodes; release
   fetching from GCP Artifact Registry / GCS / S3.
   Plus the TenderApp dashboard: nodes, processes, logs (search + follow), releases.
   Plus Prometheus `/metrics` on the head.
4. **Per-node secrets + agent skill** — milestone 1.5 §4–6 (`tender secret`,
   `${secret:NAME}`, `tenderd exec`). The MCP server is shelved: agents use the
   `tender` CLI through a Claude Code skill (`~/.claude/skills/tender`), with API
   token scopes enforced by the head. The MCP plan stays in
   `docs/plans/milestone-4.md` for when a shell-less agent needs it.
5. **Later** — health checks → service discovery (registry + DNS) → rolling
   deploys (per-instance labels/ports, maxSurge/maxUnavailable) → load balancer.

## Open questions

- Release source after phase 1: GCP Artifact Registry vs GCS bucket vs S3.
- Background Items allow-list: confirm whether a manually installed profile is
  honored or MDM enrollment is required.

## Working agreements

- Keep `LaunchdKit` free of networking so it is testable in isolation.
- Integration tests that touch real launchd must use labels under
  `com.olympsis.tender.test.*` and clean up after themselves.
- Prefer `launchctl bootstrap/bootout/kickstart/print` over legacy `load/unload`.
