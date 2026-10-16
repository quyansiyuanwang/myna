# MCP servers

Myna can connect to external [Model Context Protocol](https://modelcontextprotocol.io)
(MCP) servers over stdio and expose their tools to the language model. This
lets you give the assistant access to capabilities that are not built in, such
as filesystem access, Git, databases, or third-party APIs.

MCP is optional. If no server is configured, Myna spawns no sidecar process and
behaves exactly as before.

## Configuration

Servers are declared in `~/.config/myna/mcp.json`. The file is created
automatically on first run (with an empty `servers` object); a companion
`mcp.README.md` is written next to it. The format is:

```json
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
      "env": {}
    }
  }
}
```

| Field | Required | Description |
|---|---|---|
| `command` | yes | Executable to run. Started through `/usr/bin/env`, so commands resolved via `PATH` (for example `npx`, `uvx`, `python3`) work. |
| `args` | no | Array of arguments passed to the command. |
| `env` | no | Additional or overriding environment variables. `PATH` already includes `/opt/homebrew/bin` and `/usr/local/bin`. |

The configuration file is read once at startup. To apply changes, restart Myna
or call `MCPManager.shared.reload()` (for example from a future menu action).

## Marketplace

MCP servers can also be installed from the community registry: open
Settings → **市场 → MCP** and click install. Myna downloads the server's
`mcp.json`, merges its `command`/`args`/`env` into `servers[<id>]` in
`~/.config/myna/mcp.json` (all other servers are preserved, the file is written
with mode `0600`), and calls `MCPManager.shared.reload()`. Uninstalling removes
the `servers[<id>]` entry and reloads again.

For scripted or offline use, the hidden command installs directly from the
registry:

```bash
myna market-install mcp memory
```

Set `MYNA_HUB_BASE` to override the registry base URL (a mirror or a local
`file://` checkout) when testing.

## Tool naming

Each discovered tool is namespaced as:

```
mcp__<server>__<tool>
```

Both the server key and the tool name are sanitized: any character outside
`[A-Za-z0-9_-]` is replaced with `_`. For the example above, the filesystem
server's `read_file` tool becomes `mcp__filesystem__read_file`.

MCP tools appear in the Settings tool list and can be individually disabled
through `disabled_tools`, exactly like the built-in tools.

## Lifecycle and timeouts

- Servers are started asynchronously after the app launches; the UI is never
  blocked.
- During startup Myna performs the MCP `initialize` handshake, then requests the
  tool list with `tools/list`.
- Every JSON-RPC request has a 20-second timeout. The synchronous bridge used by
  `myna tool` waits at most 25 seconds and then returns a readable error instead
  of hanging.
- On quit, Myna closes the server's stdin, terminates it, and falls back to
  `SIGKILL` after two seconds.

A server's stderr is forwarded to Myna's stderr with a `[mcp:<server>]` prefix,
which is useful for diagnostics.

## Command line

MCP tools are reachable through the CLI, which is convenient for testing a
server configuration:

```bash
# List the configured server's tools (after startup completes)
myna tools

# Call a namespaced MCP tool directly
myna tool mcp__filesystem__read_file '{"path":"/tmp/hello.txt"}'
```

## Self-test

`scripts/mcp-selftest.sh` starts a tiny Python MCP server over stdio, points
Myna at it through the `MYNA_MCP_CONFIG` environment variable, and verifies the
full path from configuration loading to `tools/call`. It exits non-zero on
failure:

```bash
./scripts/mcp-selftest.sh
```

## Environment variables

| Variable | Description |
|---|---|
| `MYNA_MCP_CONFIG` | Overrides the path to `mcp.json`. Useful for tests and for keeping multiple configurations. |

## Security

An MCP server runs as a child process with your user's privileges. Only
configure servers you trust, and prefer pinned package versions (`-y` with an
exact `@version`) over floating tags.
