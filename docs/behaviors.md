# Behaviors worth remembering

Things about how Tender works that may not be what you'd assume.

## Services

- **Working directory:** services default to `/`, not the directory you ran
  `tender start` from. Set one with `--cwd`. A path under `~/Documents` will probably
  fail: launchd jobs were denied access there (`getcwd: Operation not permitted`).
- **Root:** a service can't run as root. `--user root` is rejected.
- **Starting without a command:** `tender start api` starts an existing service. If
  there's no service but a binary was dropped in `bin/api/`, it creates the service
  from the newest release.
- **Restart count:** it comes from launchd's run count, so manual restarts count too,
  and it resets to 0 after `tender stop` or anything else that reloads the job.
- **Unknown names:** `stop` and `restart` return an error, since it's probably a typo.
  `delete` succeeds, since the service is already gone.

## Service files

- **Unchanged means untouched:** `tender apply` leaves a service whose spec didn't change
  completely alone: no restart, and a service someone stopped stays stopped. A service whose
  spec changed is replaced and started, even if it was stopped.
- **`binary:` keeps the node's release:** it means "whichever release this node runs", so a
  rollback survives the next apply. A new service gets the node's newest release, and fails
  with `no release` if `bin/<service>/` never had a binary. `binary` must be the service's own
  name, because releases are kept per service.
- **`env_file` is read by the CLI:** its values are merged into the spec, so the node never
  sees the file, and `tender export` prints them inline under `env:`, as literal values. Keep
  credentials in `${secret:…}` references, which stay references everywhere.
- **The diff hides environment values:** it says a variable was added, removed or changed.
  The audit log records the file's hash and the diff's counts and names, never values.
- **`--prune` abandons adopted jobs** the file doesn't list, leaving them running, and
  deletes services the file doesn't list, but only on the nodes the file names: each item's
  `node:`, and the head (or the local node) for items without one. A file that names only
  `mac-1` never prunes `mac-2`. `--prune-all` (`pruneAll` in the API) prunes every node
  that's up; a node that's down is reported and not pruned. The diff starts with
  `Pruning on <nodes>`.
- **Reading specs remotely takes a `write` token:** `GET /v1/specs` (`tender export`)
  returns environments as stored, which can include literal credentials.
- **Removing `log_path`** from an adopted job re-adopts it with the job's own log paths,
  which needs the job to be loaded.
- **Setting `log_path` takes the local socket:** like `tender adopt --log-path`, it makes
  the daemon (root) read that file. Through the head with `--remote`, a file may keep an
  adopted job's current `log_path` (so an export applies) but not set a new one: that's a
  403. Run `tender apply` on the job's node instead.
- **5c keys:** `health`, `rollout`, `replicas` and `placement` are rejected with "not
  supported yet" rather than ignored.

## Releases

- **Rollback:** it holds even with a newer binary still in `bin/`. Only a change to that
  file deploys again.

## Logs

- **Rotation gap:** rotation is copy-truncate, so lines written between the copy and the
  truncate are lost.

## Adopted jobs

- **Stop doesn't survive login:** `tender stop` on an adopted job in
  `~/Library/LaunchAgents` lasts only until the next login. launchd reloads its plist,
  and Tender never edits it.
- **Delete is refused:** use `tender abandon <label>`, which stops managing the
  job and leaves it as it is.
- **Labels with `@`:** Homebrew labels such as `homebrew.mxcl.postgresql@18` work in
  every command; the API decodes percent-encoded path parameters.
- **Logs:** Tender reads an adopted job's logs but never rotates them.

## Secrets

- **The plist never holds a value:** a service whose environment or arguments contain
  `${secret:…}` (or `$${`) starts through `tenderd exec`, which fills the values in and
  then becomes the program, keeping the same PID. Services without references keep a
  plain plist.
- **Where the values are at launch:** `tenderd` writes each such service's resolved
  secrets to `env/<service>/secrets.json` under Tender's root (`/opt/tender/env/` in
  production): `0400`, owned by the service's user, in a `0711` directory root owns, so
  the service can read it but not replace it. It's outside `run/` because that directory
  is root's alone. It's what lets a service restart while `tenderd` is down.
- **Isolation is per user, not per service:** a secrets file is readable by the service's
  user, and so is the environment of its running processes. Services that share a user,
  as they all do by default (`_tender`), can read each other's secrets. Give each service
  that holds secrets its own `--user`.
- **Exit code 78:** a referenced secret that isn't set makes `tenderd exec` exit with
  78 (`EX_CONFIG`) and name the secret on stderr. launchd keeps retrying, throttled.
  `tender secret list` lists unset references under `missing`.
- **Changing a secret restarts its users:** the plist carries `TENDER_SECRETS_REV`, one
  revision number per reference. Setting or deleting a secret changes it, and the
  reconciler replaces those jobs. Revisions never repeat, even after a delete.
- **Upgrades:** service secrets and cached GCP values are in the same Keychain as the
  node's keys, so `tender daemon install --system` carries them across with `secrets-export`.
- **No service may be named `shared`:** `shared/NAME` always means the shared scope.
- **Deleting a service keeps its secrets:** `tender delete api` leaves `api/*` on the node,
  so redeploying by delete and start needs no new secrets, and a new service named `api`
  gets the old ones. `tender secret list` shows them; `tender secret delete api/NAME`
  removes one.
- **A stopped service with an unwritable secrets file** still stops and deletes; only
  its running jobs are left as they were.
- **Secret files are written by the service's user, never by root:** `tenderd exec` runs
  after launchd has switched to the service's user, and writes each `secret_files` entry
  before `execve`: a fresh temp name in the target's directory, created with
  `O_CREAT | O_EXCL | O_NOFOLLOW`, `0400`, then renamed over the target. A symlink at the
  target is replaced, not followed, and a path the user controls can only make it write
  where that user could anyway. Missing parent directories are created `0700`. The plist
  carries paths and references, never values, so changing either restarts the service.
- **Secret file paths:** absolute, without `.`, `..` or empty components, at most 32 per
  service, and not inside Tender's root, logs, config or plist directories (checked as
  written and with symlinks resolved).
- **A missing file secret** removes that file, writes none of the others and exits 78, so
  deleting a secret also removes its file at the next start.
- **Stale secret files:** when a spec drops a path, or the service is deleted, `tenderd`
  removes the file, walking the path with `openat` and `O_NOFOLLOW` and removing only a
  regular `0400` file owned by the service's user. It follows a symlink only when root owns
  it in a directory only root can change (`/tmp`, `/var`, `/etc`). Not removed: files whose
  path went through any other symlink, files the service rewrote with another mode, and
  files of a service that was stopped rather than deleted.
- **GCP Secret Manager references** (`${secret:gcp:…}`) are fetched by the node when a
  service starts and by the sweep, cached in the same store as local secrets, and delivered
  the same way. `latest` is re-checked every 5 minutes and a new value restarts the
  services using it; a pinned version is fetched once. With GCP unreachable, instances
  start from the cache and `tender secret list` marks the reference `stale`; a reference
  never fetched fails `tender start` with the secret's name and the IAM role it needs.
  Payloads are checked against their CRC32C. See [ops/gcp-secrets.md](ops/gcp-secrets.md).
- **Default GCP project:** `${secret:gcp:NAME}` uses `secrets.project` in `cloud.json`.
  Without one, a start with such a reference is refused. Changing it restarts the services
  that use unqualified references, since they now name other secrets.

## Orphans

- Jobs with Tender's service prefix that aren't in the desired state are only reported
  by `tender list`. Only `tender gc` boots them out.

## Security

- **Secrets:** `state.db` and service plists are `0600`, because they can hold secrets
  from `--env`.
- **Production CLI:** the socket is root-only, so `tender` needs sudo against a
  production daemon. The manual production check is in
  [production-install.md](production-install.md).

## Cluster

- **Node IDs:** a node's ID is a UUID made on first run and kept in `/opt/tender/node-id`
  (`--node-id` overrides it). The hostname is only a label, so renaming a Mac changes nothing.
  An ID already in use can't be joined until `tender node revoke` or `tender node remove` frees it.
- **Tailscale pinning:** the first Tailscale machine a node ID connects from is remembered in
  `peer-pins.json` (trust on first use), and later connections must come from the same machine,
  whatever either is called. After moving a node to new hardware, `tender node remove` it first.
- **Waiting for Tailscale:** `tenderd` doesn't listen for peers until Tailscale has an address
  (it never falls back to loopback). It retries with backoff, exits after `--tailscale-wait`
  seconds (default 300) so launchd restarts it, and rebinds if the address changes.
  `tender status` shows where it stands. The plist's `ThrottleInterval` applies after a
  reinstall (`tender daemon install --system`).
- **Commands flow from the head:** a node only takes commands from its head. Workers can't
  command each other, even with valid certificates.
- **Write tokens run code:** an API token with `write` scope can start any executable on any
  node, as any account except root. Treat it like SSH access.
- **Write tokens can read secrets:** values never leave a node through the API, but a
  `write` token can start a process that prints any secret on that node, and logs are
  readable with `read` scope. Guard `write` tokens as you would the secrets themselves.
- **Protocol version 4:** service files (`specs`, `applyManifest`) and GCP secrets (heartbeats
  carry the fetch error count, secret lists the GCP references) changed the head↔worker
  protocol, as secrets did for version 3. Upgrade the head and workers together; a mismatched
  node is refused at the handshake.
- **Socket-only:** `tender adopt`, join and API tokens, CA export and cloud credentials work
  over the local socket only, never with `--remote`.
- **Certificates expire** after 2 years and aren't renewed automatically yet. The head reissues
  its own at each start, but a worker needs `tender node remove` on the head, then `tender leave` and `tender join`.
- **Upgrades:** Keychain items trust the binary that wrote them, so `tender daemon install
  --system` moves secrets from the old `tenderd` to the new one. Replacing the binary by hand
  would lock it out. If an upgrade stops partway, `secrets-handoff.json` stays in the run
  directory with the secrets in plaintext, and installing again is refused until they're imported.
- **Half a CA:** a head missing either `ca.crt` or `ca.key` refuses to start rather than creating a new CA.

## Cluster logs

- **Head over its limit:** if the head can't get under 5 GB by deleting old days, it stops
  accepting lines. They wait in the workers' spools (1 GiB, 7 days), then get dropped oldest first.
- **Order:** within a node, lines are in order. Across nodes it's approximate, because clocks differ.
- **Long lines:** cut at 64 KB before shipping.

## Shortcuts and Siri

- **Access:** the actions use the head and token the app is connected to, so a `read` token can
  get status and search logs, but starting, stopping or restarting needs `write`.
- **Confirmation:** stop and restart ask first, because they interrupt a running service. Start
  doesn't.
- **Log search:** returns 50 lines at most, from up to the past 7 days.

## Menu bar

- **Font:** the node meters use the system font.
- **Names:** cut to 8 characters.
- **More than 4 nodes:** the labelled meters become one unlabelled dot per node, because macOS
  silently hides menu bar items that don't fit. The popover says which node is which.
