# Running a cluster

## Tailscale ACL

Each node's Tailscale machine name must equal its Tender node ID: the transport rejects
a peer whose certificate and Tailscale identity differ.

```json
{
  "tagOwners": {
    "tag:tender-head": ["autogroup:admin"],
    "tag:tender-worker": ["autogroup:admin"]
  },
  "acls": [
    {"action": "accept", "src": ["tag:tender-head", "tag:tender-worker"],
     "dst": ["tag:tender-head:7070", "tag:tender-worker:7070"]},
    {"action": "accept", "src": ["tag:tender-worker"], "dst": ["tag:tender-head:7071"]},
    {"action": "accept", "src": ["autogroup:admin"], "dst": ["tag:tender-head:7071"]}
  ]
}
```

Port 7070 is node-to-node mTLS. Port 7071 is the head's HTTPS API, which joining workers
need too.

## Start the head

```bash
sudo tender daemon install --system --role head
```

The first start creates the internal CA in the System Keychain. Back it up, and store the
output offline: anyone holding it can issue certificates for your cluster.

```bash
sudo tender ca export > tender-ca-backup.pem
```

## Join a worker

On the head:

```bash
sudo tender token create
```

Tokens work once and expire after 15 minutes. On the worker:

```bash
sudo tender daemon install --system
sudo tender join <head-address> --token <token>
sudo tender nodes
```

The worker generates its key locally, and it never leaves the machine. The token carries
the CA's fingerprint, so the worker can verify the head before trusting it.

To remove a node, run `sudo tender node revoke <id>`. Its connection drops at once, and its
certificate is refused from then on. Joining with a new token lets it back in.

## Place binaries

In milestone 2, binaries are placed on each worker by hand:

```bash
scp ./api mac-2:/tmp/api
ssh mac-2 sudo install -d /opt/tender/bin/api
ssh mac-2 sudo install -m 755 /tmp/api /opt/tender/bin/api/api
```

## Remote CLI and the menu bar app

On the head:

```bash
sudo tender api-token create laptop --scope write
```

The token is shown once, and tokens are `read` or `write`. Then on your laptop:

```bash
tender context set --head <head-address> --token <token>
```

For the app, enter the same two values in Settings.

## Identity check modes

`tenderd --identity-mode` is `enforce` by default. `warn` logs a mismatch and lets the
peer in. `off` skips the check. Dev installs use `warn`.
