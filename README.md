# Tender

A bare-metal process orchestrator for macOS, built in Swift on top of launchd.
A head node manages processes, logs, and metrics across a fleet of worker Macs.

> Early development. See `docs/DESIGN.md` for the design and `CLAUDE.md` for conventions and milestones.

## Requirements

- macOS 14+
- Xcode 16+ (Swift 6)

## Getting started

1. Clone the repo and open the workspace:
   ```sh
   open Tender.xcworkspace
   ```
2. Wait for Xcode to resolve Swift packages.
3. Pick a scheme and build (⌘B):
   - `TenderApp`: menu bar app + dashboard
   - `tenderd`: the daemon (head or worker)
   - `tender`: the CLI
4. Run the tests with ⌘U.

### Running the daemon locally

Add these launch arguments to the `tenderd` scheme (Product → Scheme → Edit Scheme → Run → Arguments):

```
--dev --role worker
```

`--dev` uses `~/Library/Application Support/Tender/` and your user's launchd domain, so no `sudo` is needed.

## Back up the CA

The head creates an internal CA on first start. If you lose it, every node has to join again, so keep a backup offline. Anyone holding the backup can issue certificates for your cluster.

```sh
sudo tender ca export > tender-ca-backup.pem
```

To restore it, use `tenderd ca-import`. See [`docs/ops/cluster.md`](docs/ops/cluster.md#restore-the-ca) for the steps.

## Layout

```
Tender.xcworkspace   open this
TenderKit/           Swift package: all modules, tenderd, tender CLI
App/                 TenderApp (menu bar + dashboard)
docs/DESIGN.md       architecture and decisions
```

Behaviors worth remembering: [`docs/behaviors.md`](docs/behaviors.md).
