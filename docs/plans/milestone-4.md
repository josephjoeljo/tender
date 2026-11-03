# Milestone 4 — MCP server

Goal: AI agents can inspect and operate the cluster safely through MCP, with the
same capabilities as the CLI and clear limits.

Builds on milestones 2–3 (public API, tokens, log store, releases).

## Definition of done

- Claude Desktop / Claude Code connect through `tender mcp` (stdio bridge) or
  directly to the head's MCP endpoint (streamable HTTP on the tailnet).
- With a `read` token an agent can list nodes and processes, describe one,
  search logs, and read a metrics summary; write tools are refused.
- With a `write` token it can start/stop/restart processes, deploy and roll
  back releases; every call is in the audit log with the token's identity.
- Every tool response is bounded (line/byte limits, time windows, errors first).

Out of scope: health checks, discovery, rolling deploys.

## Work breakdown

### 1. MCP server — `TenderMCP`
- MCP Swift SDK, streamable HTTP transport, hosted by the head on its tailnet IP.
- Tools call head services directly (no extra hop through HTTP).

### 2. Tools
- Read: `list_nodes`, `list_processes`, `describe_process`,
  `search_logs(service?, node?, since, query?, stream?, limit ≤ 500)`,
  `get_metrics_summary`, `list_releases`.
- Write: `start_process`, `stop_process`, `restart_process`, `deploy_release`,
  `rollback_release`.
- Descriptions state limits and that cross-node log ordering is approximate.
- `search_logs` defaults: last 15 min, errors first, 200 lines.

### 3. Auth + audit
- Reuse milestone-2 API tokens (`read` / `write`); token name = agent identity.
- Audit log (SQLite on the head, offloaded nightly): time, token, tool,
  arguments, result, duration.
- Per-token rate limit on write tools.

### 4. `tender mcp` stdio bridge
- CLI subcommand speaking MCP over stdio and forwarding to the head with the
  configured context/token, so local agent apps need no network setup.

### 5. Docs + tests
- Setup snippets for Claude Desktop and Claude Code.
- Tests: tool schemas, bounds, scope enforcement, audit entries; manual pass
  with the MCP Inspector.

## Suggested sequence

| Step | Delivers | Depends on |
|---|---|---|
| A | 1 + read tools | milestone 3 |
| B | 3 (auth scopes, audit) | A |
| C | write tools | B |
| D | 4 (stdio bridge) + 5 (docs) | A–C |

## Risks

- Agents flooding context with logs → strict limits, summaries, errors-first.
- Destructive actions by agents → `write` scope opt-in, audit, rate limits.

## Decisions

- Write tools take `dry_run`: it returns the planned action from the current
  process list, changes nothing, and isn't rate limited.
- The HTTP endpoint is stateless streamable HTTP (one JSON response per POST, no
  sessions, GET → 405), with a fresh MCP server per request so that JSON-RPC ids
  from different clients can't collide.
- `tender mcp` runs the tools locally over `TenderClient` instead of forwarding MCP
  frames: the head then checks the bridge's token and audits each forwarded call
  like any CLI call.
- MCP requests are audited per tool call (read tools too), not per HTTP request.
- Per-node secrets from milestone 1.5 (§4–6) ship in this milestone.
