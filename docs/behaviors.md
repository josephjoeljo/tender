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
- **Delete is refused:** use `tender adopt --forget <label>`, which stops managing the
  job and leaves it as it is.
- **Logs:** Tender reads an adopted job's logs but never rotates them.

## Secrets

- **The plist never holds a value:** a service whose environment or arguments contain
  `${secret:…}` (or `$${`) starts through `tenderd exec`, which fills the values in and
  then becomes the program, keeping the same PID. Services without references keep a
  plain plist.
- **Where the values are at launch:** `tenderd` writes each such service's resolved
  secrets to `env/<service>/secrets.json` under Tender's root (`/opt/tender/env/` in
  production): `0400`, owned by the service's user, in a `0700` directory it owns. It's
  outside `run/` because that directory is root's alone. It's what lets a service
  restart while `tenderd` is down.
- **Exit code 78:** a referenced secret that isn't set makes `tenderd exec` exit with
  78 (`EX_CONFIG`) and name the secret on stderr. launchd keeps retrying, throttled.
  `tender secret list` lists unset references under `missing`.
- **Changing a secret restarts its users:** the plist carries `TENDER_SECRETS_REV`, one
  revision number per reference. Setting or deleting a secret changes it, and the
  reconciler replaces those jobs. Revisions never repeat, even after a delete.
- **Upgrades:** service secrets are in the same Keychain as the node's keys, so
  `tender daemon install --system` carries them across with `secrets-export`.
- **A service named `shared`** can't have secrets of its own: `shared/NAME` always
  means the shared scope.

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

- **Node names:** a node's ID must match its Tailscale machine name, or the transport refuses
  it. A name already in use can't be joined until `tender node revoke` frees it.
- **Commands flow from the head:** a node only takes commands from its head. Workers can't
  command each other, even with valid certificates.
- **Write tokens run code:** an API token with `write` scope can start any executable on any
  node, as any account except root. Treat it like SSH access.
- **Socket-only:** `tender adopt`, join and API tokens, CA export and cloud credentials work
  over the local socket only, never with `--remote`.
- **Certificates expire** after 2 years and aren't renewed automatically yet. The head reissues
  its own at each start, but a worker needs `tender node revoke` on the head, then `tender leave` and `tender join`.
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
