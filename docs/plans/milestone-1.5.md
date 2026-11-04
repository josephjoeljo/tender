# Milestone 1.5 — Service files and secrets (pm2 parity)

Goal: describe services in a YAML file and start them all with one command, the
way pm2 users rely on `ecosystem.config.js`, and keep secrets out of plists.

Numbered 1.5 because it completes pm2 parity; it lands after milestone 3 and
before milestone 4 (MCP), so it uses the cluster, head API and audit log that
already exist. The file format is the milestone 5c format with fields missing,
so 5c only adds `health`, `rollout`, `placement.labels` and `${svc:…}`.

## Definition of done

- `tender apply -f services.yaml` creates or updates every service in the file
  on the nodes it names, prints a diff first, and `--dry-run` stops after the
  diff. Running it twice changes nothing.
- Services in the cluster but not in the file are left alone unless `--prune`.
- `env_file: .env` and inline `env:` both work; inline wins on conflicts.
- `tender export > services.yaml` writes the running services back out, and
  applying that file is a no-op.
- `tender secret set api/MONGO_PASSWORD` stores a secret on the node(s) running
  `api` without the value ever appearing in argv, a plist, `launchctl print`,
  the API, the CLI, the app, logs or the audit log.
- `env: { MONGO_URL: "mongodb://app:${secret:MONGO_PASSWORD}@…" }` reaches the
  process; changing the secret restarts exactly the services that use it.
- With the head down, a worker still restarts a crashed service with its
  secrets (launchd restart, `tenderd` down, reboot).
- Unit tests + launchd integration tests (labels `com.olympsis.tender.test.*`) pass.

Out of scope: health checks, discovery, rolling deploys, `${svc:…}`, label
placement, a head-side secret store. GCP Secret Manager is step G and may slip
to a later milestone without blocking the rest.

## File format

```yaml
kind: Service
name: api
binary: api                       # release from bin/api/ (or exec: absolute path)
args: ["--port", "8080"]
cwd: /opt/olympsis/api
instances: 2
node: mac-1                       # phase 1: explicit node; default = local node
env_file: ./api.env               # relative to the YAML file, read on the CLI side
env:
  LOG_LEVEL: info
  MONGO_URL: "mongodb://app:${secret:MONGO_PASSWORD}@10.0.0.3/olympsis"
  JWT_KEY: "${secret:shared/JWT_KEY}"
secret_files:
  /opt/olympsis/api/gcp.json: GCP_KEY   # optional: secret written as a file
user: _tender                     # optional override
---
kind: Adopted
label: homebrew.mxcl.mongodb-community
node: mac-1
log_path: /opt/homebrew/var/log/mongodb/mongo.log
```

- Unknown keys are errors (typos from agents and humans fail loudly).
- `${secret:NAME}` resolves `<service>/NAME`; `${secret:shared/NAME}` the shared
  scope. `$${` escapes. Interpolation only in `env` values and `args`.
- 5c's keys (`health`, `rollout`, `replicas`, `placement`) are rejected with
  "not supported yet" instead of ignored.

## Work breakdown

### 1. Models — `TenderCore` (done)
- `ServiceSpec`: + `secretRefs: [SecretRef]`, `secretFiles: [String: SecretRef]`
  (derived from the env/args templates; the template itself is stored, never the
  resolved value).
- `SecretRef { scope: service | shared, name, source: local }` (source gains
  `gcp(project, name, version)` in step G).
- `Manifest` = `[ManifestItem]` (`service(ServiceSpec)`, `adopted(AdoptRequest)`),
  Codable, plus validation (names, nodes exist, refs parse).

### 2. YAML parsing + diff — `TenderClient/Manifest` (done)
- Yams for parsing (new dependency, `TenderClient` only — the app and agent
  never parse YAML).
- `env_file` read and merged on the CLI side; the node only sees the final spec.
- `ManifestDiff`: create / update (field-level) / unchanged / prune, computed
  against `GET /v1/processes` so the same code serves the CLI, app and MCP.

### 3. Apply + export — API and CLI (done)
- `POST /v1/apply { items, prune, dryRun } -> ManifestDiff + results` on the
  local socket and the head. The head fans out per node with the existing
  `NodeAgentProtocol.apply(_:)`; per-node failures are reported, not rolled back.
- `tender apply -f <file> [--dry-run] [--prune] [--yes]`: prints the diff,
  asks unless `--yes`/non-TTY, `--json` for agents.
- `tender export [--service s] [--node n]` → YAML, secrets as `${secret:…}`.
- Audit log entry per apply (file hash, diff summary, token).

### 4. Secret store — `TenderAgent/SecretVault`
- Uses the existing `SecretStore` (System Keychain in production, 0600 files in
  dev). Item names `svc.<service>.<NAME>` / `shared.<NAME>`, plus a small table
  in `state.db`: name, updatedAt, revision (no values).
- Contract additions (add-only, protocol version bump):
  `NodeAgentProtocol.setSecret(_ name: String, value: Data) async throws`,
  `deleteSecret(_:)`, `listSecrets() -> [SecretInfo]`. Values travel only over
  the mTLS link; the head relays and never persists them.
- Public API: `PUT /v1/secrets/{scope}/{name}?node=`, `DELETE …`,
  `GET /v1/secrets` (names, nodes, updatedAt, usedBy). No endpoint returns a value.

### 5. Delivery — `tenderd exec` wrapper
- Plists for services with secrets run
  `tenderd exec --service api --instance 0 -- <program> <args…>` instead of the
  program directly. Services without secrets keep the plain plist.
- `_tender` can't read the System Keychain, so when a secret or spec changes
  `tenderd` (root) materializes `run/secrets/<service>.env`, 0400, owned by the
  service's user, in a 0700 directory owned by that user. Secret files go to
  their target paths with the same ownership and mode.
- The wrapper reads the env file, resolves `${secret:…}` in env/args, sets the
  environment and `execve`s the program: same PID, so launchd, restart counts and
  libproc metrics keep working, and it never depends on `tenderd` being up.
- Missing secret → wrapper exits 78 (EX_CONFIG) with the secret's name on stderr;
  launchd throttles retries and `tender list` shows the reason.
- Rotation: the plist carries `TENDER_SECRETS_REV=<n>` (a counter, not a hash of
  the value). Changing a secret bumps it for every service that references it, and
  the reconciler's existing plist-changed path restarts them.
- `tenderd` itself is the wrapper binary: installs and upgrades must replace it by
  writing a new file and renaming (new vnode), never in place.

### 6. CLI + app
- `tender secret set <scope/NAME> [--node n] [--from-file f]`: reads the value
  from a no-echo prompt or stdin, never argv. `--node` defaults to every node
  running that service; `shared/…` requires `--node` or `--all-nodes`.
- `tender secret list|delete`, `--json` everywhere.
- `tender describe` / app / later MCP show `MONGO_PASSWORD=<secret>`.
- App: secrets section lists names, nodes and users; no values, no editing in
  this milestone.
- `scripts/` example: restore a node's secrets from a local file (the user's
  backup script), piping each value to `tender secret set`. Done: `scripts/restore-secrets.sh`.

### 7. GCP Secret Manager source (step G, may slip)
- Ref syntax: `${secret:gcp:NAME}`, `${secret:gcp:NAME@4}`,
  `${secret:gcp:projects/P/secrets/S}`; default project in `CloudConfig.secrets`.
- `GCPSecretSource` in `GoogleCloud.swift` reuses `GoogleTokenProvider` (scope
  `cloud-platform`; access is limited by IAM, grant
  `roles/secretmanager.secretAccessor` per secret to each node's service account).
  `GET …/versions/{v}:access`, verify `payload.dataCrc32c`.
- Fetched on apply and before an instance starts, then cached in the same
  `SecretVault` → delivery and rotation are unchanged.
- `latest` refs re-checked every 5 min; a new version bumps the revision.
  Pinned versions only change with the file.
- GCP unreachable: start from cache and warn (`tender list`, app,
  `tender_secret_fetch_errors_total`); never fetched → instance does not start,
  error names the secret and the missing IAM role.

### 8. Tests (service-file parts done)
- YAML parse/validate fixtures (good, unknown keys, 5c-only keys, bad refs).
- Diff: create/update/unchanged/prune; apply idempotence; export round-trip.
- Interpolation and escaping; `env_file` precedence.
- Vault against `FileSecretStore`; contract calls with
  `LocalTestingDistributedActorSystem`; no value in API/audit output.
- Integration: a `com.olympsis.tender.test.*` job via `tenderd exec` sees the
  secret in its environment; plist and `launchctl print` don't; changing the
  secret restarts it.
- Step G: `GCPSecretSource` against a stubbed `HTTPFetching` (crc mismatch,
  403, 404, latest vs pinned).

## Suggested sequence

| Step | Delivers | Depends on |
|---|---|---|
| A | 1 + 2 (models, YAML, diff) | — |
| B | 3 (apply/export over socket + head) | A |
| C | 4 (vault, contract, secret API) | A |
| D | 5 (`tenderd exec`, materialized env, rotation) | C |
| E | 6 (CLI, app, restore script) | B, D |
| F | 8 (tests and integration pass) | A–E |
| G | 7 (GCP Secret Manager) | D |

## Risks

- Keychain items trust the binary that wrote them; the vault must be written and
  read by `tenderd` only (same rule as the CA key and upgrade handoff).
- The materialized env file is a secret at rest on disk; mitigated by 0400 +
  owner + FileVault. Same exposure as pm2's ecosystem file, much less than plists.
- Env vars are visible to root and the same user (`ps eww`); acceptable, and
  `secret_files` covers values that must not be in the environment.
- A node's local secrets die with the node; the user's restore script is the
  backup until GCP refs are used.

## Decisions

- Secrets live on each node that needs them; the head relays but never stores.
- Delivery via the `tenderd exec` wrapper, never `EnvironmentVariables`.
- Rotation through a revision counter in the plist, reusing plist-diff restarts.
- GCP Secret Manager is an additional source behind the same refs, not a
  replacement.

## Decided while building

- Per-node secrets (§4–6) shipped with milestone 4; this milestone adds service
  files, `secret_files` and GCP refs on top.
- No pm2 `env_<profile>` blocks: one file per environment
  (`services.prod.yaml`, `services.staging.yaml`), with `env_file` for what
  differs.
- `max_memory_restart` / `cron_restart`: later, with health checks (milestone 5).
- `secret_files` values are refs as written inside `${secret:…}`; the spec stores
  the ref, never the value.
- `ManifestDiff` lives in `TenderCore`, not `TenderClient`: each node diffs its part of
  the file against its own `StateStore`, and the head only splits and merges. YAML stays
  in `TenderClient` (Yams).
- The diff needs full specs, which `GET /v1/processes` doesn't carry, so there's
  `GET /v1/specs` (socket and head; a remote token needs `write` scope, since specs can
  hold literal `env_file` values). The head fans out with two add-only distributed funcs,
  `specs()` and `applyManifest(_:)`, rather than `apply(.start(spec))`, so that each node
  pins `binary:` to its own release. Protocol version 4.
- `binary: <name>` must equal the service's name (releases are per service). It means
  "the release this node runs, else its newest", so a rollback survives re-applying;
  export writes `binary:` without a sha.
- Unchanged items aren't touched, so a stopped service stays stopped; a changed one is
  replaced and started. `--prune` also abandons adopted jobs the file doesn't list.
- Diffs never show environment values, only that a variable was added, removed or
  changed. The audit record of an apply gets a `detail`: file sha256, counts and names.
