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

## Named sources: separate credentials per service

The default credentials serve every service on the node. When a service's secrets should be
readable only by that service, say `billing-api`'s Stripe key, give it a named source with
its own service account:

1. Define the source in the node's `cloud.json`, with the services allowed to use it:

   ```json
   {
     "secrets": {
       "project": "olympsis-prod",
       "sources": {
         "billing": {"kind": "gcp", "project": "billing-123", "services": ["billing-api"]}
       }
     }
   }
   ```

   `kind` defaults to `gcp`, the only kind so far. `project` is the source's default project.
   Leave out `services` to allow every service on the node, but then a separate key buys
   little: anyone who can edit a service's spec could point it at the source.

2. Install its key on the node. The source must already be in `cloud.json`, so a typo can't
   hide a key under a name nothing uses:

   ```bash
   sudo tender credentials set --source billing --file billing-key.json
   ```

3. Grant `roles/secretmanager.secretAccessor` to that account, as for the default one.

4. Reference it by name in place of `gcp`: `${secret:billing:STRIPE_KEY}`,
   `${secret:billing:STRIPE_KEY@3}`, `${secret:billing:projects/P/secrets/S}`, or
   `billing:STRIPE_KEY` in `secret_files`.

What it guarantees:

- **The allow-list is checked on the node** at every start, fetch and delivery. A service
  that isn't in `services` is refused at `tender start` / apply, never has the reference
  fetched, and its `tenderd exec` gets no value even if `cloud.json` changes after it
  started.
- **Each source keeps its own cached copy** (`gcpsrc.<source>.…` in the store), so a value
  fetched through `billing` is never handed to a service through the default source, even
  when both name the same project and secret.
- **A source without a key fails only its own references**; the default source keeps working.
- **Sources are per node**, like credentials. A service that moves to another node needs the
  source defined, with its key, there too: the start fails with the setup step otherwise.

Source names are lowercase letters, digits and `-`, start with a letter, and are at most 32
characters. `gcp` (the default source) and `shared` are reserved. Release fetching and log
offload always use the default credentials.

`tender credentials show` lists a node's sources: account (never the key), project, allowed
services, which services use it and what's failing. `--node <n>` asks the head for any
node's latest report, and `tender nodes` has a `SECRETS` column (`gcp,billing!`, where `!`
marks a source with a problem). The app shows the same on each node's page.
`tender credentials delete [--source <name>]` forgets a key; cached values stay until they
change.

## Check that it's hooked up

`tender credentials set` checks only that the file is a service account key (and prints its
`client_email`). It doesn't contact Google, so a revoked key, a disabled API or a missing IAM
binding shows up the first time a secret is fetched. To check:

1. Reference the secret from a service and apply (or `tender start`). If the first fetch
   fails, the start fails and the error names the secret and the missing role. `tender apply`
   also prints a `warning:` for every reference that doesn't resolve.
2. `tender secret list` (add `--node <n>` through a head) shows a `GCP SECRET` table. `STATUS`
   is `ok` when the node holds the value, `stale: <error>` when a refresh failed and instances
   are using the cache, and `not fetched: <error>` when instances can't start. `CHECKED` is
   the last successful fetch since the daemon started.
3. `tender secret list --json | jq '.gcp[] | select(.fetchError != null)'` gives the same
   for scripts, and the head's `/metrics` counts failures in
   `tender_secret_fetch_errors_total{node}`.

Common errors: HTTP 403 means the node's service account lacks
`roles/secretmanager.secretAccessor` on that secret, or the API isn't enabled. HTTP 404 means
a wrong secret, version or project. "No GCP credentials on this node" means
`tender credentials set` hasn't been run on that node: credentials are per node, set
through its local socket, so run it on the node itself (over SSH).

## Reference syntax

| Reference | Means |
|---|---|
| `${secret:gcp:NAME}` | The latest version of `NAME` in the default project |
| `${secret:gcp:NAME@4}` | Version 4 of `NAME`, pinned |
| `${secret:gcp:projects/P/secrets/S}` | The latest version of `S` in project `P` |
| `${secret:gcp:projects/P/secrets/S@4}` | Version 4 of `S` in project `P` |
| `${secret:billing:NAME}` (any form above) | The same, through the named source `billing`, with its own key and default project |

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
