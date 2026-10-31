# Milestone 3 — Log shipping, releases, dashboard

Goal: every log line from every node is durable, searchable, and followable
from the head; releases are fetched from a bucket instead of placed by hand;
the dashboard shows it all.

Builds on milestone 2 (cluster, contract, transport, public API, menu bar).

## Definition of done

- Kill the network between a worker and the head for an hour → no log lines
  lost (within spool limits); they arrive after reconnect, in order per node.
- `tender logs api -f` follows `api` across all nodes, merged; `tender logs api
  --since 1h --grep timeout` searches with FTS5.
- Lines show node, instance, `node_ts`; `tender nodes` shows clock skew and warns
  above 1 s.
- Closed day files and the audit log appear in the configured bucket each night.
- `tender deploy api --release <version>` → each node running `api` fetches the
  release from the bucket, verifies sha256, strips quarantine, and restarts on it.
- Spool over its limits drops oldest lines, records a gap, and increments
  `tender_log_spool_dropped_total`.
- The dashboard shows nodes, processes, logs (search + follow), and releases
  (list + deploy + rollback).
- `/metrics` serves the metrics in DESIGN.md §8.

Out of scope: MCP, health checks, discovery, rolling deploys.

## Work breakdown

### 1. Worker spool — `TenderAgent/LogSpool`
- `LogTail` feeds lines (from Tender-managed files and adopted `--log-path`s)
  into spool SQLite (WAL): `seq, node_ts, service, instance, stream, line`.
- Limits: 1 GiB / 7 days by default; drop oldest unacked rows, write a gap
  marker, bump `dropped` counter.
- Persist tail offsets with the spool so restarts neither lose nor duplicate.

### 2. Shipping — contract + agent
- `HeadRegistryProtocol.ingest(_ batch: LogBatch) -> UInt64` (acked seq).
  New `distributed func`; protocol version bump per the add-only rule.
- Batching: up to N lines or M ms; one batch in flight per node; on ack, prune
  `<= seq` (keep a small tail).

### 3. Head log store — `TenderLogStore`
- Day files `logs-YYYY-MM-DD.db` chosen by `ingest_ts`; schema
  `logs(node, seq, node_ts, ingest_ts, service, instance, stream, line,
  UNIQUE(node, seq))` + FTS5 external-content index.
- Batch inserts in one transaction; dedupe on `(node, seq)`; ack highest
  contiguous seq.
- Queries: ATTACH the day files in range; order by `node_ts`, ties by
  `ingest_ts`; within a node by `seq`.
- Follow: in-process subscribers fed as batches land.
- Retention: delete day files older than N days (default 30).

### 4. Clock skew
- Heartbeats already carry the node clock; head computes offset with RTT/2.
- `tender_node_clock_skew_seconds`; warning in `tender nodes`, API, app.

### 5. Nightly offload
- After midnight (head clock), upload yesterday's closed day file + audit log
  to the configured bucket; record success; retry with backoff.

### 6. Releases from a bucket — `TenderAgent/ReleaseSources`
- `ReleaseSource` protocol: `LocalFolder` (milestones 1–2), `GCS`, `S3`,
  `ArtifactRegistry` (generic repository).
- Release metadata: service, version, sha256, artifact path.
- `tender deploy <svc> --release <version>`: head records desired release →
  tells each node running the service (`NodeAgentProtocol.deploy`) → node
  downloads into `releases/<svc>/<sha12>/`, verifies sha256, strips
  `com.apple.quarantine`, restarts instances.
- Credentials per node (GCP service account key or AWS profile), stored in
  Keychain / `/etc/tender/`, never sent over the wire.

### 7. Public API additions
- `GET /v1/logs?service&node&since&until&query&limit`, `GET /v1/logs/follow`
  (Server-Sent Events), `GET /v1/releases`, `POST /v1/deploy`.

### 8. `/metrics` — `TenderMetrics`
- Head-aggregated Prometheus endpoint (tailnet only), metrics from DESIGN.md §8,
  fed by heartbeats + log store counters.

### 9. Dashboard — `TenderApp`
- Window with sidebar: Nodes, Processes, Logs, Releases.
- Logs: search field, filters (service/node/stream/time), live follow via SSE,
  per-node gap markers.
- Releases: per service, current + previous, deploy and rollback.
- "Open dashboard" in the menu bar becomes active.

## Suggested sequence

| Step | Delivers | Depends on |
|---|---|---|
| A | 1 + 2 (spool, shipping) | milestone 2 |
| B | 3 + 4 (log store, skew) + log API | A |
| C | 5 (offload) | B |
| D | 6 (bucket releases, deploy) | milestone 2 |
| E | 8 (`/metrics`) | B |
| F | 9 (dashboard) | B, D |

## Risks

- FTS5 index size and insert throughput on busy services → measure with a
  synthetic load early; tune batch sizes.
- Spool + raw log files double disk usage on workers → rotation + spool limits.
- Cloud credentials on every node → least-privilege, read-only bucket access.

## Decisions

- Release backends: GCS and Artifact Registry first (S3 later), authenticated with a
  GCP service account key.
- CI in the platform repo publishes releases. Tender only reads.
- Head log retention: 30 days and at most 5 GB locally. The bucket keeps everything.
