> **Historical design record** — this document may not describe
> current behavior. See [README.md](../README.md) and
> [docs/guides/](guides/) for current guidance.

# Pi native MCP registration contracts

Research for [issue 99](https://github.com/louiss0/agent_resource/issues/99). Retrieved 2026-11-16. This is documentation and static source evidence, not a runtime certification. Sources are pinned to upstream Pi commit `5a2febe5d7638ab05540b44a60518b41201be170`; installed versions may differ. No MCP servers were executed, credentials accessed, or configuration modified.

## Result and locations

Pi now documents built-in MCP support; it must not be conflated with a separately installed MCP adapter. User entries live in `<agent-dir>/mcp.json` (normally `~/.pi/agent/mcp.json`); `PI_CODING_AGENT_DIR` changes the standard Pi agent directory. Project entries live in `<session-directory>/.pi/mcp.json` and are read only when project trust is granted. Both are JSON objects containing `mcpServers`, keyed by server name. The separate top-level boolean `autoEnableCodemode` defaults to true. [D][C][P]

## Fields and validation

| Field | Contract |
| --- | --- |
| `command`, `args`, `env`, `cwd` | Stdio executable, arguments, environment and working directory. `command` is one executable, not a shell command; relative `cwd` resolves from the session directory. Leading `~/` expands in command, arguments and cwd. |
| `url`, `headers`, `oauth` | Streamable HTTP configuration. Legacy SSE is rejected. `type` is optional; if present it is `stdio`, `http`, or `streamable-http`; command or URL selects the transport. |
| `enabled`, `timeout`, `description` | Disabled entries remain configured; timeout is seconds per request, default 60, reset by progress. Description summarizes server capabilities. |
| `exposure`, `toolExposure` | `codemode` (default), `deferred`, `direct`, or `hidden`; `codemode-deferred` aliases `codemode`. Exact tool overrides win over wildcard patterns; first matching pattern wins. |
| `auth` | HTTP `auth: {"provider": "..."}` sends a Pi provider credential; permitted only in user config, with HTTPS except loopback. |

Names accept letters, digits, underscores and hyphens. Names differing only by hyphen versus underscore collide; invalid entries are reported and skipped. `env` and `headers` values support `${NAME}` and whole-value `!command` substitution. This can execute commands on use, so merely treating configuration as inert data is unsafe. [D][S][C]

OAuth options documented upstream include `clientId`, `clientSecret`, `callbackPort`, `callbackUrl`, `scope`, `clientName`, `clientRegistration` (`auto`, `dcr`, `cimd`) and `authServerMetadataUrl`; consult the pinned documentation for their interaction and validation. Callback URLs must be HTTP loopback; the metadata override requires HTTPS except loopback. OAuth applies to HTTP without an Authorization header. [D]

## Precedence and modification constraints

* A trusted project entry normally replaces the user entry of the same name. A project entry with no `command`, `url`, or `type` is instead an override of an existing user entry and may contain **only** `enabled`, `exposure`, and `toolExposure`; it retains the remaining user fields. An override without a matching user entry is invalid. Top-level project `autoEnableCodemode` overrides the user value. [D][C]
* File-configured servers take precedence over same-name extension registrations. An extension may register session-only servers using `pi.registerMcpServer`; their exposure and enablement changes are not persisted. Shell `pi mcp` commands do not load extensions. An extension registering `/mcp` replaces the built-in session support, so native `mcp.json` is not read for that session; shell commands still use built-in support. SDK sessions do not load built-in extensions automatically. [D]
* Upstream's editor parses JSON, rejects invalid/non-object structures, creates missing parent directories, and serializes the whole object with detected indentation. It retains unrelated parsed content, not byte-for-byte formatting. Add replaces the same-name entry; remove removes only that entry. Enable/exposure edits target the defining file or project override. These are observed upstream mechanics, not a blanket guarantee of concurrent-write, symlink, or crash safety for another tool. [C]
* A running session requires `/reload` after external configuration changes. `pi mcp list` connects enabled servers; it is not a safe passive inspection command. Native exposure settings govern tool availability, not an independent permission boundary: calls still pass through Pi's extension tool pipeline. [D]

## Credentials and security

Keep personal servers and credentials in user scope, not project scope. HTTP OAuth tokens and registration state are stored in `<agent-dir>/mcp-auth.json`, keyed by server name and URL; same name and URL across user/project files share sign-in. Signing out deletes stored credentials. `clientSecret` supports environment or command substitution. Pi's project `auth` prohibition specifically prevents a repository selecting the destination of a provider credential; ordinary project headers and command substitutions remain security-sensitive. Do not copy, inspect, or rewrite OAuth state as part of server registration. [D][C][O]

## Evidence and limits

* [D] [Official MCP documentation](https://github.com/earendil-works/pi/blob/5a2febe5d7638ab05540b44a60518b41201be170/packages/coding-agent/docs/mcp.md).
* [C] [Built-in MCP configuration loader and editor](https://github.com/earendil-works/pi/blob/5a2febe5d7638ab05540b44a60518b41201be170/packages/coding-agent/src/extensions/mcp/config.ts).
* [S] [Core MCP configuration types and validation](https://github.com/earendil-works/pi/blob/5a2febe5d7638ab05540b44a60518b41201be170/packages/coding-agent/src/core/mcp-servers.ts); shared field validation is delegated to `@earendil-works/pi-mcp`.
* [P] [Agent directory resolution](https://github.com/earendil-works/pi/blob/5a2febe5d7638ab05540b44a60518b41201be170/packages/coding-agent/src/config.ts).
* [O] [OAuth credential store](https://github.com/earendil-works/pi/blob/5a2febe5d7638ab05540b44a60518b41201be170/packages/coding-agent/src/extensions/mcp/oauth.ts).

These findings do not establish the first released version containing the feature, behavior of older Pi builds or third-party adapters, or a safe automated write policy for this repository. Those require separate version and filesystem-safety work.
