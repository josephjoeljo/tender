# MCP: letting agents run the cluster

The head serves MCP tools, so agents such as Claude can inspect and operate the
cluster with the same limits as the CLI. There are two ways in:

- **`tender mcp`** (stdio). A local agent app starts it as a subprocess. It talks to the
  head the way the CLI does (saved context, pinned CA, token in the Keychain), so it
  needs no network or TLS setup. Use this one unless you have a reason not to.
- **`https://<head>:7071/mcp`** (streamable HTTP on the head's public listener). For
  agents that can't run a local command. They need a bearer token and must trust the
  head's internal CA.

## Tokens and scopes

Every MCP caller is an API token. The token's name is the identity in the audit log,
so give each agent its own:

```sh
sudo tender api-token create claude-read --scope read
sudo tender api-token create claude-ops --scope write
```

- **read**: `list_nodes`, `list_processes`, `describe_process`, `search_logs`,
  `get_metrics_summary`, `list_releases`, `list_secrets` (names only; no tool ever
  returns a secret's value). Write tools aren't even listed.
- **write**: also `start_process`, `stop_process`, `restart_process`,
  `deploy_release`, `rollback_release`. At most 20 write calls per minute per token.
  Every write tool takes `dry_run: true`, which reports what would happen and changes
  nothing (and doesn't count against the limit).

Revoke a token with `sudo tender api-token revoke <name>`; it stops working at once.

## Claude Code

On a laptop that already has a context (`tender context set`, see
[cluster.md](cluster.md)):

```sh
claude mcp add tender -- tender mcp --remote
```

With a read token, add `--read-only` after `mcp` so that write tools aren't offered.

## Claude Desktop

Claude Desktop doesn't inherit your shell's `PATH`, so give the full path to `tender`
(`which tender`). In `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "tender": {
      "command": "/usr/local/bin/tender",
      "args": ["mcp", "--remote"]
    }
  }
}
```

Restart Claude Desktop after editing it.

## Direct HTTP

The endpoint is `POST https://<head>:7071/mcp` with `Authorization: Bearer <token>`.
It is stateless: each request gets one JSON response, there are no sessions, and
`GET` (the optional server-to-client stream) returns 405.

The certificate comes from Tender's internal CA, which the agent's TLS stack doesn't
trust by default. Fetch the CA, and check that its SHA-256 fingerprint matches the
part of the token after the `.`:

```sh
curl -sk https://<head>:7071/v1/ca -o ~/tender-ca.pem
openssl x509 -in ~/tender-ca.pem -outform der | shasum -a 256
```

Then point the client at it. For Claude Code, which runs on Node:

```sh
NODE_EXTRA_CA_CERTS=~/tender-ca.pem claude mcp add --transport http tender \
  https://<head>:7071/mcp --header "Authorization: Bearer <token>"
```

## Limits

Responses are bounded so that an agent's context isn't flooded:

- Process lists: at most 300 rows, crashed instances first.
- `search_logs`: the last 15 minutes and 200 lines by default, at most 500 lines and
  7 days. stderr lines come first. Lines over 1,000 characters are cut.
- Any response: at most 60 KB, cut on a line boundary with a note saying so.
- Log order across nodes is approximate, because node clocks differ. Within one node,
  `seq` gives the exact order. `list_nodes` shows each node's clock skew.

## Audit

Each tool call is one line in the head's audit log (`logstore/audit-<day>.jsonl`,
uploaded nightly with the logs): time, token name, tool, arguments, error if any, and
duration in milliseconds. Read tools are recorded too. MCP requests that aren't tool
calls (`initialize`, `tools/list`) aren't.

## Testing by hand

The MCP Inspector can drive the stdio bridge:

```sh
npx @modelcontextprotocol/inspector tender mcp --remote
```
