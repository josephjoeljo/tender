# Releases, log offload and metrics

Each node reads `/etc/tender/cloud.json` (dev mode: `<root>/config/cloud.json`) and holds its
own credentials. Credentials never cross the network, and no API can read them back.

```json
{
  "releases": {"kind": "gcs", "bucket": "olympsis-releases", "prefix": "tender"},
  "offload": {"bucket": "olympsis-tender-logs", "prefix": "cluster-1"}
}
```

For Artifact Registry instead of GCS:

```json
{
  "releases": {"kind": "artifactRegistry", "project": "olympsis", "location": "us-central1", "repository": "tender"}
}
```

## Authentication

Tender authenticates with a GCP service account key:

```bash
sudo tender credentials set --file key.json
```

Delete the file afterwards. Give each role the least it needs:

| Node | Purpose | IAM role |
|---|---|---|
| Every node | GCS releases | `roles/storage.objectViewer` on the releases bucket |
| Every node | Artifact Registry releases | `roles/artifactregistry.reader` on the repository |
| Head | Log offload | `roles/storage.objectCreator` on the logs bucket |
| Each node using it | A `${secret:gcp:…}` reference | `roles/secretmanager.secretAccessor` on that secret ([details](gcp-secrets.md)) |

Don't give workers write access to the logs bucket. `objectCreator` can't overwrite or read.

## Publishing a release (CI in the platform repo)

Tender only reads, and refuses a release without a sha256.

### GCS

Upload two objects:

```
gs://<bucket>/<prefix>/<service>/<version>/<service>
gs://<bucket>/<prefix>/<service>/<version>/manifest.json
```

```json
{"sha256": "<64 hex digits>"}
```

An optional `"artifact"` names a differently named file beside the manifest. Upload the
binary first and the manifest last, so that a node never sees a manifest without its binary.

### Artifact Registry

Upload to a generic repository, with package and file both named after the service:

```bash
gcloud artifacts generic upload --repository=tender --location=us-central1 \
  --package=api --version=1.2.3 --source=api
```

Rename the build output to the service name first. The registry records the file's SHA256.

## Deploying

```bash
tender deploy api --release 1.2.3
```

Each node running `api` downloads the release, verifies its sha256, strips quarantine and
restarts on it. Failures are reported per node, and a node that fails keeps running what it
had. `tender rollback api` goes back. Versions may contain letters, digits, `.`, `_`, `-`
and `+`.

## Logs

- `tender logs api -f` follows every node. `tender logs api --since 1h --grep timeout`
  searches. On a worker's own daemon, only its local logs are available.
- Workers spool up to 1 GiB or 7 days. Beyond that the oldest lines are dropped, and the
  head shows a gap saying how many.
- The head keeps 30 days and at most 5 GB. The bucket keeps everything: add a lifecycle rule
  there if you ever want otherwise.
- Closed day files and audit logs upload after midnight UTC, as `logs/logs-YYYY-MM-DD.db` and
  `audit/audit-YYYY-MM-DD.jsonl`. They're plain SQLite and JSON lines. A failed upload is
  retried every 30 minutes. A day older than the retention limit is deleted locally
  whether or not it was uploaded.

## Metrics

`http://<head>:7072/metrics` has no authentication, because it binds to the tailnet address
only and carries no log lines or secrets. Allow your Prometheus host in the Tailscale ACL:

```json
{"action": "accept", "src": ["tag:monitoring"], "dst": ["tag:tender-head:7072"]}
```
