> **Historical design record** — this document may not describe
> current behavior. See [README.md](../README.md) and
> [docs/guides/](guides/) for current guidance.

# Claude Code MCP registration contracts

Research for [issue #97](https://github.com/louiss0/agent_resource/issues/97), retrieved 2026-11-16. This is documentation evidence, not a tested runtime contract; the live first-party pages may change independently of Claude Code releases. No MCP servers, helpers, Claude commands, or credentials were executed or accessed. HTTP retrieval used official documentation only. Examples are illustrative, not instructions to connect a server.

## Locations and ownership

| Surface | Location and shape | Meaning |
| --- | --- | --- |
| User | `~/.claude.json`, top-level `mcpServers` map | Private servers available across projects. |
| Local | Same home file, `projects["<project-path>"].mcpServers` | Private to the project; default scope for `claude mcp add`. It is **not** `.claude/settings.local.json`. |
| Project | Project-root `.mcp.json`, top-level `mcpServers` map | Shared via version control; project servers have separate approval behavior. |

The official local example explicitly shows the project-path map; the [directory reference](https://code.claude.com/docs/en/claude-directory#ce-claude-json) describes the global file, and the [settings reference](https://code.claude.com/docs/en/settings-reference#mcpservers) documents the top-level user map. See also [MCP installation scopes](https://code.claude.com/docs/en/mcp#mcp-installation-scopes). The home file contains account details, application state, trust and other settings, not just MCP: never replace it with an MCP-only object. Claude reads it at session start and writes it when preferences or trust change; it keeps backups on rewrites. [Directory reference](https://code.claude.com/docs/en/claude-directory#ce-claude-json).

On Windows `~/.claude` resolves under `%USERPROFILE%`; the documentation says `CLAUDE_CONFIG_DIR` relocates both `.claude` paths and `.claude.json` under that directory. It does not explicitly specify the alternate global file's exact basename or migration behavior in that sentence, so do not infer a write target without further evidence. [Directory reference](https://code.claude.com/docs/en/claude-directory). This sharpens, but does not resolve, the relocation uncertainty in [earlier research](agent-parent-configuration.md).

## Entries and transport

The named map contains whole server objects. Official examples document stdio `type: "stdio"`, `command`, `args` and `env`; remote `type: "http"` and `url`, optionally `headers`, `headersHelper` and `oauth`. HTTP also accepts `streamable-http`; SSE is deprecated, HTTP can automatically fall back to SSE since v2.1.265, and WebSocket uses `type: "ws"`. An omitted `type` means stdio, so a URL without a type is rejected. `type: "sdk"` cannot be registered in these files. These examples are not an exhaustive schema or validation guarantee. [Installation options](https://code.claude.com/docs/en/mcp#installing-mcp-servers), [JSON registration](https://code.claude.com/docs/en/mcp#add-mcp-servers-from-json-configuration), [dynamic headers](https://code.claude.com/docs/en/mcp#use-dynamic-headers-for-custom-authentication).

`claude mcp add` and `add-json` are documented registration mechanisms; `--scope` selects the destination, and adding the same name at the same scope fails rather than replacing it. `remove` is documented, but OAuth client-secret replacement requires remove and re-add with the same scope. Registration alone does not validate credentials. [Scopes](https://code.claude.com/docs/en/mcp#mcp-installation-scopes), [authentication](https://code.claude.com/docs/en/mcp#authenticate-with-remote-mcp-servers).

## Precedence and policy

For duplicate names across ordinary scopes, local wins over project, then user. The winner is the **entire entry**, not a field merge. Plugin servers and claude.ai connectors follow; duplicates with those are matched by endpoint rather than scope name. Managed `managedMcpServers` entries rank above ordinary scopes from v2.1.259, subject to session flags and managed policy. [Scope hierarchy](https://code.claude.com/docs/en/mcp#scope-hierarchy-and-precedence), [managed servers](https://code.claude.com/docs/en/managed-mcp#provide-servers-through-managed-settings).

An administrator's `managed-mcp.json` is an exclusive configuration, not another personal write destination: it generally suppresses user/project/plugin servers, but managed-provided servers and documented exceptions can still load. Its platform locations are `/Library/Application Support/ClaudeCode/managed-mcp.json` on macOS, `/etc/claude-code/managed-mcp.json` on Linux and WSL, and `C:\Program Files\ClaudeCode\managed-mcp.json` on Windows. On workstations an active, parseable managed file rejects `--mcp-config`. [Exclusive control](https://code.claude.com/docs/en/managed-mcp#exclusive-control-with-managed-mcp-json).

`allowedMcpServers` and `deniedMcpServers` filter server names, exact stdio commands and arguments, or remote URL patterns; an unset allowlist differs from an empty list, and documented exceptions apply. The denylist also filters managed servers. `allowManagedMcpServersOnly` can lock the managed allowlist. A per-session `--strict-mcp-config` does not bypass these policies. [Policy-based control](https://code.claude.com/docs/en/managed-mcp#policy-based-control-with-allowlists-and-denylists).

Project `.mcp.json` servers normally prompt for approval in interactive sessions; headless and other documented contexts can load them without the prompt. `disabledMcpjsonServers` blocks selected entries, and workspace trust is a separate concern. In particular project/local `headersHelper` is an arbitrary shell command gated by trust in the project folder. Registration is not consent to run arbitrary tools. [Project scope](https://code.claude.com/docs/en/mcp#project-scope), [helper trust](https://code.claude.com/docs/en/mcp#trust-a-folder-before-its-headershelper-runs).

## Credentials and expansion

For `.mcp.json`, `${VAR}` and `${VAR:-default}` expand in `command`, `args`, `env`, `url`, and `headers`; an unset variable without a default normally remains literal with a warning, whereas an empty variable is set. In remote `url` and `headers`, Claude deliberately substitutes empty strings for certain credential variables, ignoring defaults; this does not protect arbitrary names such as `API_KEY`. Do not assume interpolation keeps a secret off a remote server or makes checked-in literal credentials safe. [Expansion](https://code.claude.com/docs/en/mcp#environment-variable-expansion-in-mcp-json).

OAuth login is a separate flow, through `/mcp` or `claude mcp login`; headless sessions require prior interactive authorization. The documented OAuth object includes `clientId`, `callbackPort`, `authServerMetadataUrl`, and `scopes`. A client secret supplied when adding a server is stored in the macOS keychain or a credentials file, not the MCP config; it cannot be added or changed later without removing and re-adding the registration. Configured `Authorization` headers take precedence over OAuth instead of falling back to it. [OAuth](https://code.claude.com/docs/en/mcp#authenticate-with-remote-mcp-servers).

## Modification constraints and open questions

* The documented CLI is the supported way to register/remove servers; project `.mcp.json` is a documented editable shared file. The home file is shared application state, and the reviewed documentation does **not** establish an offline third-party edit protocol, locking, atomicity, concurrent-write semantics, project-path normalization, or a complete schema. Do not invent those guarantees. [Directory reference](https://code.claude.com/docs/en/claude-directory#ce-claude-json), [local scope](https://code.claude.com/docs/en/mcp#local-scope).
* A future implementation should preserve unrelated keys and unknown server fields, avoid logging secrets, fail closed on malformed or ambiguous files, and obtain explicit authorization before modifying any user data. These are safety recommendations, not claims that Anthropic specifies an editor protocol.
* Managed policy and session flags can make a saved entry ineffective; writing configuration is not proof of connection or permission. Do not modify managed files, trust, approvals, or credentials as a side effect of registration. [Managed MCP](https://code.claude.com/docs/en/managed-mcp), [project approval](https://code.claude.com/docs/en/mcp#project-scope).
* Exact relocated home filename, path key canonicalization across platforms/worktrees, and robust concurrent edits remain unverified. No local behavior tests were performed; resolve these before implementing direct home-file writes.
