# Milestone 2 — Head + join + menu bar

Goal: several Macs form one cluster. A head node knows every node and can run
commands anywhere; workers keep running if the head is gone. The menu bar app
shows cluster health and offers quick actions.

Builds on milestone 1 (agent, LaunchdKit, reconciler, releases, local API).

## Definition of done

With 2–3 Macs on the tailnet:

- `tender token create` on the head → `tender join <head> --token …` on a worker
  → it appears in `tender nodes` with a cert issued by the internal CA.
- `tender list` shows processes on every node; `tender start api --node mac-2 …`
  starts it on Mac 2 (binary placed on Mac 2 by hand).
- Stop the head → workers keep running everything. Start it again → the
  registry is rebuilt from worker reports within one heartbeat.
- A peer with a cert that doesn't match its Tailscale identity is rejected.
  A `tenderd` with an incompatible protocol version is rejected with a clear error.
- The menu bar app connects to the head, shows nodes up/down and crashed
  processes, and can start/stop/restart a process.
- Contract, transport, and PKI have unit tests; a loopback multi-node test runs
  two or three `TenderActorSystem`s in one process.

Out of scope: log shipping (`tender logs` stays local to each node), release
fetching, dashboard, MCP, `/metrics`.

## Work breakdown (in order)

### 1. Spike: `@Resolvable` contract (go / no-go)
- Two `TenderActorSystem` stubs over loopback in a test target; a
  `@Resolvable` protocol in one module, implementation in another, caller in a
  third. Confirm it compiles and runs on the macOS version our Macs run.
- Raise the deployment target if stub resolution requires it.
- If it fails: fallback 2b (thin forwarding actors in a transport layer under
  `TenderProtocol`, see DESIGN.md §4). Decide before step 2.

### 2. Contract — `TenderProtocol`
- `NodeAgentProtocol`: `apply(_:)`, `status()`, `releases(service:)`,
  `rollback(service:to:)`, `adopt(_:)`.
- `HeadRegistryProtocol`: `register(_ node: NodeInfo)`, `heartbeat(_:)`.
  (`ingest` arrives in milestone 3.)
- Messages: `NodeInfo` (id, version, macOS, hardware, tailnet IP, labels),
  `Heartbeat` (node clock, instance statuses, CPU/RSS, release ids).
- Protocol version constant + compatibility rule: add, never change.

### 3. Transport — `TenderActorSystem`
- SwiftNIO + NIOSSL server and client; every node listens on its tailnet IP,
  port 7070.
- Framing: length-prefixed JSON envelopes `{callID, recipient, target,
  genericSubs, args}` / `{callID, result | error}`.
- `ActorID = {node, name}`; well-known names `agent`, `registry`.
- `remoteCall` / `remoteCallVoid` → encode, send, await reply by callID with
  timeout; inbound calls → `executeDistributedTarget`.
- `NodeResolver` protocol; phase-2 implementation asks the head's registry
  (the head resolves itself locally).
- Lazy dialing, one connection per peer pair, both directions; reconnect with
  backoff; in-flight calls fail with a retryable error on disconnect.
- Handshake: protocol version + node ID; reject mismatches.
- Tests: `LocalTestingDistributedActorSystem` for logic; loopback pairs for
  framing, timeouts, reconnects, version mismatch.

### 4. PKI — `TenderPKI`
- Internal CA created on first head start (swift-crypto + swift-certificates).
  CA key in the head's System Keychain; `tender ca export` for an offline backup.
- Join tokens: single-use, TTL (default 15 min), stored hashed.
- Join: worker generates its key locally → CSR + token → head verifies token,
  signs cert with SAN = node ID → worker stores cert + key (`/etc/tender/`, 0600,
  or Keychain).
- `tender node revoke <id>`: revocation list checked during handshake.

### 5. Tailscale identity check
- On every inbound connection: resolve the peer IP to a Tailscale node and
  require it to match the cert's node ID (and expected tag).
- Risk: the macOS Tailscale app (App Store / standalone) and the open-source
  `tailscaled` expose LocalAPI differently. Spike: support LocalAPI where
  reachable, else `tailscale whois --json <ip>`. Configurable to warn-only
  during development.

### 6. Head services — `TenderHead`
- Node registry (in-memory cache + small SQLite for last-known info), rebuilt
  from `register` + heartbeats; node up/down by heartbeat timeout.
- Command router: resolve `$NodeAgentProtocol` for the target node and call it.
- The head runs its own `NodeAgent` in-process; it's resolved locally.
- `tenderd --role head` wires PKI, transport, registry, router, public API.

### 7. Public API over the tailnet
- Hummingbird HTTP/JSON on the head's tailnet IP (TLS with the internal CA).
  Same endpoints as the local socket API, plus `/v1/nodes`; process endpoints
  take a `node` field.
- Auth: bearer tokens scoped `read` / `write` (`tender api-token create`);
  the local Unix socket stays unauthenticated (file permissions).
- `TenderClient`: transports for Unix socket and HTTPS (pins the internal CA).

### 8. CLI
- `tender token create`, `tender join`, `tender nodes`, `tender node revoke`,
  `tender ca export`, `tender api-token create|list|revoke`.
- `--node` on process commands; `tender context set --head <addr> --token …`
  stored in `~/.config/tender/` (token in Keychain).

### 9. Menu bar app — `TenderApp`
- Settings: head address + API token (Keychain), CA pinning.
- Polls `/v1/nodes` and `/v1/processes` every 5 s (push later).
- Menu bar icon reflects health (all good / degraded / head unreachable).
- Popover: nodes up/down, crashed or restarting processes, quick
  start/stop/restart; "Open dashboard" stays disabled until milestone 3.
- Optional: macOS notification when a process crash-loops or a node goes down.

### 10. Ops docs
- Tailscale ACL snippet (`tag:tender-head`, `tag:tender-worker` ↔ on 7070;
  admins → API).
- Joining a node, backing up the CA key, placing binaries by hand.

## Suggested sequence

| Step | Delivers | Depends on |
|---|---|---|
| A | 1 (spike) | milestone 1 |
| B | 2 + 3 (contract, transport) with loopback tests | A |
| C | 4 + 5 (PKI, Tailscale check) | B |
| D | 6 + 8 (head services, join/nodes CLI) → first real multi-Mac cluster | C |
| E | 7 (public API, tokens, TenderClient over HTTPS) | D |
| F | 9 (menu bar) | E |
| G | 10 (ops docs) | D–F |

## Risks

- `@Resolvable` cross-module behaviour / OS availability → spike first, fallback ready.
- Tailscale LocalAPI differences between macOS install variants → CLI fallback.
- Writing our own transport (timeouts, reconnects, backpressure) → keep the
  envelope simple, test failure paths on loopback.
- Keychain access from a root LaunchDaemon (System Keychain) → verify early.

## Decisions

- Heartbeat every 5 s; a node is down after 20 s without one.
- Worker certs and keys live in the System Keychain (production). Dev mode and tests
  use 0600 files, because a non-root process can't write the System Keychain.
