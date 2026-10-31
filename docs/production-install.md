# Production install check

Milestone 1 step 12. These steps need sudo and a real Mac, so they are run by hand.

## 1. Build and preview

```bash
swift build -c release --package-path TenderKit
TenderKit/.build/release/tender daemon install --system --dry-run
```

`--dry-run` needs no root and changes nothing. It prints each command and the plist.

## 2. Install

```bash
sudo TenderKit/.build/release/tender daemon install --system
```

This creates the hidden `_tender` account (id 400–499, no shell, no home), root-owned
`/opt/tender`, `/var/log/tender` and `/etc/tender`, copies `tenderd` to
`/opt/tender/libexec/tenderd`, and loads `/Library/LaunchDaemons/com.olympsis.tender.agent.plist`.
Re-running upgrades the daemon.

The socket is root-only, so the CLI needs sudo in production.

## 3. Check that services run as `_tender`

```bash
sudo TenderKit/.build/release/tender start api -- /bin/sleep 1000
ps -o user= -p "$(sudo TenderKit/.build/release/tender list --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["processes"][0]["pid"])')"
```

Expect `_tender`. Then check that it restarts after `sudo kill -9 <pid>`, that
`tender logs api` works, and clean up with `sudo tender delete api`.

## 4. Background Items

macOS may notify "Background Items Added" for each new job. Note whether it did, then
install the allow-list:

```bash
open docs/profiles/tender-background-items.mobileconfig
```

Approve it in System Settings > General > Device Management (or Profiles), then start a
new service under a new label and see whether the notification stays away.

**Open question this answers:** whether a manually installed profile is honored or MDM
enrollment is required. Record the result in `CLAUDE.md`.

## 5. Reboot

Reboot, then confirm that `tenderd` and the service came back with no duplicates.

## Removing it

```bash
sudo tender daemon uninstall --system
```

Services keep running. `/opt/tender`, the logs and the `_tender` account stay.
