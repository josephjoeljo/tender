# Milestone 1 — Single-node agent

Goal: pm2-level process management on **one Mac**, built on launchd, with the
same building blocks milestones 2–3 reuse. No head, no networking between Macs.

## Definition of done

On Joël's Mac, in dev mode (`tenderd --dev`, no sudo):

- `tender start api -- /path/to/api --port 8080` starts it under launchd.
- Kill `api` → launchd restarts it; `tender list` shows the restart count.
- Restart `tenderd` or log out/in → `api` is still running / comes back; no
  duplicate jobs.
- `tender list` shows service, instance, state, pid, uptime, CPU, RSS, restarts,
  release — and `--json` for agents.
- `tender stop|restart|delete api` work and are idempotent.
- Drop a new `api` binary into `bin/api/` → within ~5 s Tender copies it to
  `releases/api/<sha12>/` and restarts on the new release. `tender rollback api`
  goes back.
- `tender logs api [-f] [-n 200]` shows stdout/stderr; logs rotate by size.
- `tender adopt homebrew.mxcl.mongodb-community [--log-path …]` lists and
  controls an existing launchd job without rewriting its plist.
- Unit tests + launchd integration tests (labels `com.olympsis.tender.test.*`) pass.

Out of scope: head node, mTLS, TenderActorSystem, log spool/shipping, metrics
endpoint, MCP, menu bar, release fetching from buckets.

## Work breakdown (in order)

### 1. Core models — `TenderCore`
- `ServiceSpec`: name, executable or release ref, args, env, workingDir,
  instances, user (default `_tender`, ignored in dev), logPaths (adopt).
- `InstanceStatus`: + uptime, restarts, release, cpu, rss.
- `Release`: service, sha12, path, createdAt.
- `TenderEnvironment`: add `stateDB`, `socketPath`, per-service log dirs.

### 2. launchd driver — `LaunchdKit`
- `Launchctl` runner: async wrapper over `/bin/launchctl` (Process), captures
  stdout/stderr/exit code, maps known failures to typed errors
  (already loaded, not found, I/O error, permission).
- Operations: `bootstrap(plistURL)`, `bootout(label)`, `kickstart(label, kill:)`,
  `enable/disable(label)`, `print(label) -> JobInfo?`, `listLabels(prefix:)`.
- `JobInfo` parser for `launchctl print`: state, pid, last exit code/reason,
  runs (restart count), program, stdout/stderr paths. `launchctl print` output is
  not a stable API → parse defensively, keep fixtures from the real Mac in
  `Tests/LaunchdKitTests/Fixtures/`.
- Domains: `system` and `gui/<uid>` (already modelled).
- Tests: renderer + parser unit tests; integration test that bootstraps a
  `/bin/sleep` job in `gui/<uid>`, kills it, sees the restart, boots it out.

### 3. Desired state — `TenderAgent/StateStore`
- GRDB `state.db` (WAL) with migrations: `services`, `instances`, `releases`,
  `adopted_jobs`.
- Source of truth for this node (head becomes a cache of this in milestone 2).

### 4. Reconciler — `TenderAgent/Reconciler`
- Compares desired state with `launchctl print` for every
  `com.olympsis.tender.svc.*` label; computes actions (render plist + bootstrap,
  bootout, kickstart); applies them idempotently.
- Triggers: CLI command, new release, and a periodic sweep (10 s).
- Orphan handling: labels with our prefix that aren't in desired state are
  reported, and booted out only with `tender gc`.

### 5. Releases + folder watching — `FileWatch` + `TenderAgent/ReleaseManager`
- FSEvents on `bin/`; debounce until size+mtime stable ~2 s.
- sha256 → copy to `releases/<svc>/<sha12>/` (new inode; never overwrite a
  running binary), chmod +x, keep last 5.
- New release → update desired state → reconciler restarts instances.
- `tender releases <svc>`, `tender rollback <svc> [--to sha]`.

### 6. Logs — `LogTail` + launchd output files
- Plists point stdout/stderr at `logs/<svc>/<i>.{out,err}.log`.
- `tender logs`: read tail N lines, `-f` follows (offset-tracked, handles
  truncation/rotation by inode).
- Rotation by size (default 50 MB, keep 3). launchd keeps the file descriptor
  open with O_APPEND, so rotate by **copy-truncate** (rename would leave launchd
  writing to the old file). Verify on the real Mac early.

### 7. Process metrics — `ProcessMetrics`
- `proc_pid_rusage` / `proc_pidinfo` for CPU time and RSS; uptime from start time.

### 8. Adopt — `TenderAgent/Adoption`
- `launchctl print` the label → record plist path, domain, and log paths
  (`--log-path` overrides; else `StandardOutPath`/`StandardErrorPath`).
- Control via kickstart/bootout/bootstrap of the existing plist. Never rewrite it.
- `tender adopt --forget <label>` stops managing without touching the job.

### 9. Local API — `tenderd` ↔ `tender`
- HTTP/JSON over a Unix domain socket (`tender.sock`, 0600, owned by the user /
  root). Same JSON API the head serves over the tailnet in milestone 2, so
  `TenderClient` only swaps transport.
- Endpoints: `GET /v1/processes`, `POST /v1/processes`, `POST
  /v1/processes/{name}/{stop|restart}`, `DELETE /v1/processes/{name}`,
  `GET /v1/processes/{name}/logs`, `GET /v1/releases/{svc}`,
  `POST /v1/releases/{svc}/rollback`, `POST /v1/adopt`.

### 10. CLI — `tender`
- `start`, `stop`, `restart`, `delete`, `list`, `logs`, `adopt`, `releases`,
  `rollback`, `gc`, `version`. Every command supports `--json`.
- Readable table output for `list`.

### 11. Daemon — `tenderd`
- ServiceLifecycle: StateStore → Reconciler → ReleaseManager → API server;
  graceful shutdown (never stops managed jobs on exit).
- `tender daemon install [--dev]`: writes tenderd's own plist
  (`com.olympsis.tender.agent`) so it survives logout/reboot.

### 12. Production mode check (end of milestone)
- `tender daemon install --system`: creates `_tender` user/group, `/opt/tender`
  dirs and permissions, LaunchDaemon plist.
- Verify `UserName = _tender` works and check the Background Items
  notification + allow-list profile on the real Mac.

## Suggested sequence

| Step | Delivers | Depends on |
|---|---|---|
| A | 1 + 2 (models, LaunchdKit, its tests) | — |
| B | 3 + 4 (state store, reconciler) with a temporary in-process test harness | A |
| C | 9 + 10 + 11 (socket API, CLI, daemon) → first end-to-end `tender start/list/stop` | B |
| D | 6 + 7 (logs, metrics) | C |
| E | 5 (releases + watching, rollback) | C |
| F | 8 (adopt) | C |
| G | 12 (production install, _tender, Background Items) | C–F |

## Risks

- `launchctl print` format changes between macOS versions → fixtures + defensive parser.
- Log rotation with launchd-held file descriptors → copy-truncate; test early.
- Background Items notifications in production mode → may need the profile/MDM.
- FSEvents coalescing/latency → periodic sweep as a backstop.

## Decisions

- Local IPC: HTTP/JSON over a Unix domain socket (same API the head serves in
  milestone 2; `TenderClient` swaps transport).
- Step 12 (production install, `_tender`, system domain) stays in milestone 1.
