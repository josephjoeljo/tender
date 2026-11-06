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
- **Upgrades:** service secrets are in the same Keychain as the node's keys, so
  `tender daemon install --system` carries them across with `secrets-export`.
- **No service may be named `shared`:** `shared/NAME` always means the shared scope.
- **Deleting a service keeps its secrets:** `tender delete api` leaves `api/*` on the node,
  so redeploying by delete and start needs no new secrets, and a new service named `api`
  gets the old ones. `tender secret list` shows them; `tender secret delete api/NAME`
  removes one.
- **A stopped service with an unwritable secrets file** still stops and deletes; only
  its running jobs are left as they were.

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
- **Protocol version 3:** secrets changed the head↔worker protocol. Upgrade a worker before
  it rejoins a version 3 head; a mismatched node is refused at the handshake.
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

- **Font:** the node meters use Berkeley Mono if it's installed on that Mac, and SF Mono if not.
  It isn't bundled, since that takes a licence that allows embedding it.
- **Names:** cut to 8 characters.
- **More than 4 nodes:** the labelled meters become one unlabelled dot per node, because macOS
  silently hides menu bar items that don't fit. The popover says which node is which.
