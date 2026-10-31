# Tender — Design

Status: draft, phase 1 in progress. See `CLAUDE.md` for conventions and milestones.

## 1. Goals

- Manage any launchd process (Go services, MongoDB, Postgres, workers) across a
  fleet of Macs from one head node.
- Centralized, durable, searchable logs from every machine.
- An MCP server so AI agents can inspect and operate the cluster safely.
- Prometheus metrics.
- Later: health checks, service discovery, rolling deploys, load balancing.

Non-goals (for now): Linux support, containers/VMs, HA control plane (Raft),
cross-node volume migration.

## 2. Topology

```
 CLI / AI agents (MCP)
          │  (tailnet + mTLS)
          ▼
 ┌──────────── Head node (tenderd --role head) ────────────┐
 │ API server · Node registry · Command router             │
 │ Log store (SQLite/day + FTS5) · MCP server · /metrics   │
 │ Internal CA                                             │
 └──────────────────────────────────────────────────────────┘
          ▲  long-lived bidi stream, dialed BY workers
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

1. **Tailscale**: head listens only on its tailnet IP. ACLs:
   - `tag:tender-worker` → head:7070 (agent stream)
   - admins / `tag:tender-agents` → head MCP + API ports, `/metrics`
2. **mTLS**: head runs an internal CA.
   - `tender join <head> --token <t>`: worker generates key locally, sends CSR,
     receives cert with SAN = node ID. Key never leaves the worker.
   - Join tokens are single-use, short-lived, minted by `tender token create`.
3. **Cross-check**: on connect, head resolves peer IP via Tailscale LocalAPI
   `whois` and requires it to match the cert's node ID.

MCP/API clients authenticate with bearer tokens scoped `read` or `write`.
All mutating calls go to an audit log (who, what, when, result).

## 4. Process management

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
   optional `UserName`.
3. Write to `/Library/LaunchDaemons/com.olympsis.tender.svc.<svc>.<i>.plist`.
4. `launchctl bootstrap system <plist>`; stop = `bootout`; restart = `kickstart -k`.
5. Report status by parsing `launchctl print system/<label>` (state, pid,
   last exit code) + libproc for CPU/RSS.

### Adopted jobs

Adopted labels are read and controlled (start/stop/restart/logs) but their plist
is not rewritten unless the user runs `tender adopt --takeover`.

## 5. Binary folder watching

```
/opt/tender/bin/<service>/<binary>        ← drop new builds here
/opt/tender/releases/<service>/<sha12>/   ← immutable copies Tender runs from
```

1. FSEvents fires for `/opt/tender/bin/`.
2. Debounce: wait until size + mtime are stable for ~2s (recommend writers use
   write-to-temp + rename).
3. sha256 → if new, copy to `releases/<service>/<sha12>/` (new inode).
4. Optionally `codesign --verify`.
5. Re-render plists for that service to point at the new path, restart instances.
   (Phase 5: becomes a rolling deploy.)
6. Keep last N releases (default 5); `tender rollback <service> [--to sha]`.

Why copy instead of in place: overwriting a running Mach-O on Apple Silicon can
invalidate the cached code signature and the next exec gets SIGKILLed.

## 6. Logging

### Worker
- Tail `*.out.log` / `*.err.log` from persisted offsets (handle rotation by inode).
- Append to spool SQLite (WAL):
  `spool(seq INTEGER PRIMARY KEY, ts, service, instance, stream, line)`.
- Stream batches to head; on ACK(seq) delete `<= seq` (keep a small tail).
- Rotate the raw files Tender owns (size-based) so disks don't fill.

### Head
- Per-day file `logs/logs-YYYY-MM-DD.db`:
  `logs(node, seq, ts, service, instance, stream, line, UNIQUE(node, seq))`
  + FTS5 external-content table on `line`.
- Batch inserts in transactions; ACK highest contiguous seq per node.
- Queries ATTACH the relevant day files. Retention = delete old files.
- Live follow: subscribers get lines as they're ingested.

## 7. Metrics (`/metrics` on head)

| Metric | Type | Labels |
|---|---|---|
| `tender_node_up` | gauge | node |
| `tender_node_last_heartbeat_seconds` | gauge | node |
| `tender_process_up` | gauge | node, service, instance |
| `tender_process_restarts_total` | counter | node, service, instance |
| `tender_process_cpu_seconds_total` | counter | node, service, instance |
| `tender_process_resident_bytes` | gauge | node, service, instance |
| `tender_log_lines_ingested_total` | counter | node |
| `tender_log_spool_backlog` | gauge | node |
| `tender_release_deploys_total` | counter | service, result |

## 8. MCP server (head)

Transport: streamable HTTP on the tailnet. Bearer token with `read`/`write` scope.

Read tools: `list_nodes`, `list_processes`, `describe_process`,
`search_logs(service?, node?, since, query?, level?, limit<=500)`,
`get_metrics_summary`.

Write tools: `start_process`, `stop_process`, `restart_process`,
`rollback_release`.

Rules: every response bounded; log tools default to errors-first and a short
window; every write call is audited.

## 9. Later phases

- **Health checks**: http/tcp/exec probes run by the agent; readiness gates
  discovery and deploys.
- **Service discovery**: registry of healthy endpoints; small DNS server for
  `<svc>.svc.tender.internal`; env injection (`MONGO_URL=...`).
- **Rolling deploys**: per-instance labels + allocated ports so old/new run side
  by side; start new → healthy N times → register → deregister + drain old →
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

## 10. Prior art

- SRM (Swift, PM2-like, single machine, ShellOut-based)
- macpmd (Python, PM2 on launchd/systemd)
- Process Compose (Go, YAML, health checks, MCP server, single machine)
- HashiCorp Nomad (multi-node, raw_exec on macOS)
- emorydunn/LaunchAgent (Swift launchd plist library)
