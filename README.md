# Tender

A bare-metal process orchestrator for macOS, built in Swift on top of launchd.
A head node manages processes, logs, and metrics across a fleet of worker Macs.

launchd keeps your processes running, including through crashes and reboots. Tender decides what should run and writes the launchd jobs. If the head goes down, workers keep running their last-known workloads.

> Early development. See `docs/DESIGN.md` for the design and `CLAUDE.md` for conventions and milestones.

## Requirements

- macOS 15+
- Xcode 16+ (Swift 6)
- [Tailscale](https://tailscale.com) on every node, for a multi-Mac cluster

## Build

From the command line:

```sh
swift build --package-path TenderKit
```

This puts `tender` and `tenderd` in `TenderKit/.build/debug/`. The examples below assume `tender` is on your `PATH`:

```sh
export PATH="$PWD/TenderKit/.build/debug:$PATH"
```

To work in Xcode, open the workspace and wait for it to resolve Swift packages:

```sh
open Tender.xcworkspace
```

Then pick a scheme and build (⌘B):

- `TenderApp`: menu bar app + dashboard
- `tenderd`: the daemon (head or worker)
- `tender`: the CLI

## Run it on one Mac

Dev mode needs no `sudo`. It uses `~/Library/Application Support/Tender/` and your user's launchd domain, and services run as you.

Install the daemon. A head also runs a worker, so one Mac is a complete cluster:

```sh
tender daemon install --dev --role head
```

Start a service and look at it:

```sh
tender start hello -- /bin/sh -c 'echo hi; exec /bin/sleep 1000'
```

```sh
tender list
```

```sh
tender logs hello
```

Then stop and remove it:

```sh
tender stop hello
```

```sh
tender delete hello
```

To remove the daemon, run `tender daemon uninstall --dev`. Services you've started keep running.

### Run the daemon from Xcode

To debug the daemon instead of installing it, add these launch arguments to the `tenderd` scheme (Product → Scheme → Edit Scheme → Run → Arguments):

```
--dev --role worker
```

## Everyday commands

| Command | What it does |
|---|---|
| `tender start <name> -- <command>` | Create or update a service and start it |
| `tender start <name>` | Start an existing service |
| `tender stop <name>` | Stop a service and keep its definition |
| `tender restart <name>` | Restart a service, starting it if it's stopped |
| `tender delete <name>` | Stop a service and remove its definition |
| `tender list` | List managed processes |
| `tender logs <name> -f` | Follow a service's logs |
| `tender adopt <label>` | Manage an existing launchd job, such as Homebrew's `mongod` |
| `tender abandon <label>` | Stop managing an adopted job; the job keeps running untouched |
| `tender releases <name>` | List a service's releases |
| `tender rollback <name>` | Go back to an earlier release |
| `tender deploy <name> --release <version>` | Fetch a release and restart on it. Needs a [release source](docs/ops/releases-and-logs.md) |
| `tender nodes` | List the cluster's nodes |
| `tender apply -f services.yaml` | Create or update every service a [service file](#service-files) describes |
| `tender export` | Print what runs as a service file |

`tender start` also takes `--instances`, `--env KEY=VALUE`, `--cwd`, `--user`, `--node` and `--secret-file PATH=REF`. Services start in `/` unless you set `--cwd`. Run `tender help <command>` for the rest.

### Secrets

Keep passwords and keys out of `--env` values: those end up in the job's plist. Store a secret on the node instead, and reference it:

```sh
tender secret set api/MONGO_PASSWORD          # prompts; or pipe it in, or --from-file
tender start api --env 'MONGO_URL=mongodb://app:${secret:MONGO_PASSWORD}@db/olympsis' -- ./api
```

`${secret:NAME}` is the service's own secret and `${secret:shared/NAME}` one any service can use. They work in `--env` values and in arguments, and `$${` stands for a literal `${`. Through a head, `tender secret set api/NAME` goes to every node running `api`; a shared secret needs `--node <n>` or `--all-nodes`.

| Command | What it does |
|---|---|
| `tender secret set <service>/<NAME>` | Store a secret and restart the services that use it |
| `tender secret list` | List secrets by name, node and the services using them. Values are never shown |
| `tender secret delete <service>/<NAME>` | Delete a secret. Services still using it exit with code 78 |

A value that mustn't be in the environment, such as a key file, can be written as a file before each start instead:

```sh
tender start api --secret-file /opt/olympsis/api/gcp.json=GCP_KEY -- ./api
```

The file is written by `tenderd exec` as the service's own user, `0400`, and replaced whole at each start. The path must be absolute and outside Tender's own directories, and the service's user must be able to create files in its directory. The reference is what goes between `${secret:` and `}`: `GCP_KEY`, `shared/GCP_KEY` or a `gcp:` reference.

Secrets can also come from GCP Secret Manager: `${secret:gcp:NAME}` (latest, re-checked every 5 minutes), `${secret:gcp:NAME@4}` (pinned) and `${secret:gcp:projects/P/secrets/S[@4]}`. Each node fetches them with its own credentials and caches them, so services still start while GCP is down. Setup, IAM roles and the full behaviour are in [docs/ops/gcp-secrets.md](docs/ops/gcp-secrets.md).

Values stay on the node: in the System Keychain in production, and in 0600 files in dev mode. The head passes them on and keeps nothing. A Mac that dies takes its secrets with it, so keep your own copy, for example a script that pipes each one into `tender secret set`.

Secrets are isolated by user, not by service. At launch a service reads them from a file owned by its user, so services sharing a user (by default all of them, as `_tender`) can read each other's secrets and environments: start each service that holds secrets with its own `--user`. A `write`-scoped API token can start a process that prints any secret, so treat write tokens as secrets too. `tender delete <service>` keeps the service's `<service>/*` secrets; remove them with `tender secret delete`.

### Service files

Describe services in YAML, one document per service or adopted job, and apply the file. [docs/examples/services.yaml](docs/examples/services.yaml) runs the Olympsis backend.

```yaml
kind: Service
name: api
binary: api                       # the release from bin/api/; or exec: /absolute/path
args: ["--port", "8080"]
cwd: /opt/olympsis/api
instances: 2
node: mac-1                       # defaults to the node you're talking to
env_file: ./api.env               # relative to this file, read by the CLI
env:
  LOG_LEVEL: info
  MONGO_URL: "mongodb://app:${secret:MONGO_PASSWORD}@10.0.0.3/olympsis"
secret_files:
  /opt/olympsis/api/gcp.json: GCP_KEY
---
kind: Adopted
label: homebrew.mxcl.mongodb-community
node: mac-1
log_path: /opt/homebrew/var/log/mongodb/mongo.log
```

```sh
tender apply -f services.yaml --dry-run   # only print what would change
tender apply -f services.yaml             # print the changes, ask, apply
tender apply -f services.yaml --prune     # also remove what the file doesn't list
tender export > services.yaml             # what runs now, as a file that applies as a no-op
```

Applying the same file twice changes nothing and restarts nothing. Without `--prune`, services the file doesn't list are left alone. Unknown keys are errors, inline `env` wins over `env_file`, and `--yes` (or a stdin that isn't a terminal) skips the question. Through a head, each node applies its part; a node that fails is reported and the others go ahead. Use one file per environment (`services.prod.yaml`, `services.staging.yaml`).

### Ship a new binary

Tender watches a folder for each service: `/opt/tender/bin/<service>/` in production and `~/Library/Application Support/Tender/bin/<service>/` in dev mode. Drop a new binary there, and Tender copies it to a new release. It uses `<service>/<service>` if that file exists, and otherwise the newest file in the folder.

If the service already exists, Tender restarts it on the new release. If it doesn't, nothing runs until you create it with `tender start <service>`.

## Run it in production

Production uses `/opt/tender`, `/Library/LaunchDaemons`, and the system launchd domain. Services run as a dedicated `_tender` account. The daemon's socket is root-only, so the CLI needs `sudo` on the node itself.

On each Mac, build a release and copy both binaries somewhere `sudo` can find them. `tender` looks for `tenderd` next to itself:

```sh
swift build -c release --package-path TenderKit
```

```sh
sudo mkdir -p /usr/local/bin
```

```sh
sudo install -m 755 TenderKit/.build/release/tender TenderKit/.build/release/tenderd /usr/local/bin/
```

On the head, preview the install. The preview needs no root and changes nothing:

```sh
tender daemon install --system --role head --dry-run
```

Then install it. Re-running the same command upgrades the daemon:

```sh
sudo tender daemon install --system --role head
```

### Add workers

Each node's Tailscale machine name must match its Tender node ID, and your tailnet needs the ACL in [`docs/ops/cluster.md`](docs/ops/cluster.md#tailscale-acl).

On the head, create a join token. It works once and expires after 15 minutes:

```sh
sudo tender token create
```

On the worker:

```sh
sudo tender daemon install --system
```

```sh
sudo tender join <head-address> --token <token>
```

Then check the node from the head with `sudo tender nodes`.

### Back up the CA

The head creates an internal CA on first start. If you lose it, every node has to join again, so keep a backup offline. Anyone holding the backup can issue certificates for your cluster.

```sh
sudo tender ca export > tender-ca-backup.pem
```

To restore it, use `tenderd ca-import`. See [`docs/ops/cluster.md`](docs/ops/cluster.md#restore-the-ca) for the steps.

### Use it from a laptop

On the head, create an API token. It's shown once:

```sh
sudo tender api-token create laptop --scope write
```

On your laptop, save the head's address and the token. Passing the token through `TENDER_TOKEN` keeps it out of `ps`:

```sh
TENDER_TOKEN=<token> tender context set --head <head-address>
```

If a dev daemon is also running on the laptop, the CLI talks to that instead. Add `--remote` to reach the head, as in `tender list --remote`.

For the menu bar app, enter the same two values in Settings.

## Test

Run all the tests from the command line:

```sh
swift test --package-path TenderKit
```

In Xcode, each test module has its own scheme, such as `TenderPKITests`. Pick one and press ⌘U.

## Layout

```
Tender.xcworkspace   open this
TenderKit/           Swift package: all modules, tenderd, tender CLI
App/                 TenderApp (menu bar + dashboard)
docs/                design, plans, and operations guides
```

## More documentation

- [`docs/DESIGN.md`](docs/DESIGN.md): architecture and decisions
- [`docs/behaviors.md`](docs/behaviors.md): behaviors worth remembering
- [`docs/ops/cluster.md`](docs/ops/cluster.md): running a cluster
- [`docs/ops/releases-and-logs.md`](docs/ops/releases-and-logs.md): releases, log offload, and metrics
- [`docs/production-install.md`](docs/production-install.md): checking a production install
