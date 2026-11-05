# GCP Secret Manager secrets

A service can reference a secret in GCP Secret Manager wherever it can reference a
node-local one: in `--env` values, in arguments and in `secret_files`. Each node fetches
what its own services need with its own credentials and caches the value in its secret
store (the System Keychain in production), so services restart, and start after a reboot,
while GCP or the head is unreachable.

## Set up GCP

1. Enable the API in each project that holds secrets:

   ```bash
   gcloud services enable secretmanager.googleapis.com --project olympsis-prod
   ```

2. Each node authenticates as a service account. If it doesn't have one yet (releases and
   log offload use the same one), create a key and install it:

   ```bash
   sudo tender credentials set --file key.json
   ```

3. Grant `roles/secretmanager.secretAccessor` per secret, to the service account of each
   node that runs a service using it. Grant it on the secret, not the project, so a node
   can read only what its services need:

   ```bash
   gcloud secrets add-iam-policy-binding MONGO_PASSWORD --project olympsis-prod \
     --member serviceAccount:mac-1@olympsis-prod.iam.gserviceaccount.com \
     --role roles/secretmanager.secretAccessor
   ```

4. Optionally set the node's default project in `/etc/tender/cloud.json` (dev mode:
   `<root>/config/cloud.json`), so references can leave it out:

   ```json
   {"secrets": {"project": "olympsis-prod"}}
   ```

## Reference syntax

| Reference | Means |
|---|---|
| `${secret:gcp:NAME}` | The latest version of `NAME` in the default project |
| `${secret:gcp:NAME@4}` | Version 4 of `NAME`, pinned |
| `${secret:gcp:projects/P/secrets/S}` | The latest version of `S` in project `P` |
| `${secret:gcp:projects/P/secrets/S@4}` | Version 4 of `S` in project `P` |

`@latest` is accepted and means the same as no version. `P` is a project ID or number.
Version aliases other than `latest` aren't supported. In `secret_files` and
`tender start --secret-file PATH=REF`, write the part between `${secret:` and `}`, for
example `gcp:projects/olympsis-prod/secrets/GCP_KEY`.

## When values are fetched

- **On start or apply:** `tender start` (and an apply, which starts each service) fetches
  the service's GCP secrets before its instances start, re-checking `latest`. If one has
  never been fetched on that node and can't be, the start fails, the service isn't stored,
  and the error names the secret and the `roles/secretmanager.secretAccessor` role.
- **`latest` every 5 minutes:** each node re-checks the `latest` references its services use.
  A new value bumps the secret's revision, which restarts exactly the services using it.
  A new version with the same bytes restarts nothing.
- **Pinned versions are fetched once:** they only change when the reference does.
- **Outages:** a failed refresh leaves the cached value in place and instances keep
  starting from it. `tender secret list` marks the reference `stale` with the error, and
  the head's `/metrics` counts failures in `tender_secret_fetch_errors_total{node}`. A
  reference that was never fetched is retried every 30 seconds, and its instances exit with
  code 78 meanwhile.
- **Every payload's CRC32C is checked** against `payload.dataCrc32c`. A mismatch stores nothing.
- **Unused values are dropped** from the cache once no service on the node references them.

Values never appear in logs, errors, the API, the CLI or the audit log: error messages
name the secret and the HTTP status, never a response body.
