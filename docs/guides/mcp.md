# MCP server registrations

`mcp` discovers, validates, and manages MCP server registrations in native
harness configuration files. Claude, Codex, Pi, and Antigravity each retain
their distinct native schema.

## Static checks only

Every `mcp` report is a **static** check: no server is launched, no
connection is attempted, no authentication is tested, and no credential is
read or activated. Validation reports carry `"verification": "static"` with
an explicit claim, and inspection/list output states the same boundary. A
successful static report means the declaration is schema- and
reference-correct — never that the server works, connects, or that a
referenced credential resolves.

## Read surfaces

```text
agent-resource mcp list [--scope project|user|all]
agent-resource mcp inspect --name <name> --harness claude|codex|pi|antigravity --scope project|user
agent-resource mcp validate --harness claude|codex|pi|antigravity --scope project|user
```

These are read-only. Credential values are never printed; native credential
*references* (such as `${NAME}`) may be reported without exposing secrets.

## Register and unregister

```text
agent-resource mcp register --name <name> --harness claude|codex|pi|antigravity --scope project|user (--command <cmd>|--url <url>) [--args <arg> ...] [--env NAME=${VAR} ...] [--header <name>=<ref> ...] [--type <type>] [--dry-run] [--yes]
agent-resource mcp unregister --name <name> --harness <harness> --scope <scope> [--yes]
agent-resource mcp adopt --name <name> --harness <harness> --scope <scope>
```

Registration requires name, harness, scope, and exactly one transport
(`--command` or `--url`). Interactive invocations review a plan before
publication; unattended invocations supply every required choice and
`--yes`. Claude user and local MCP scopes are inspect-only for mutation.

## Declarative replacement

`mcp replace` takes a managed registration and a **complete desired entry**,
not a field-by-field patch:

```text
agent-resource mcp replace --name <name> --harness <harness> --scope <scope> (--command <cmd>|--url <url>) [--args ...] [--env ...] [--header ...] [--dry-run] [--yes]
```

Supply every argument, environment reference, header, and type to retain.
Omitted fields — including old credentials, unknown native settings, and
fields of a previous transport — are removed. Review the redacted
`observedEntry` and `proposedEntry` with `--dry-run` before approval;
unrelated entries in the shared native file are preserved.

## Credential references

New `--env` and `--header` values require a supported native credential
reference, not a literal. Claude project registrations accept `${NAME}`; Pi
accepts `${NAME}` or `!command` (which can execute code); Codex accepts
`${NAME}` and writes `env_vars` for matching stdio variable names or
`env_http_headers` for HTTP headers; defaults and renamed Codex stdio
variables are refused. Antigravity substitutions are refused because native
support has not been established. Do not put literal secrets in helper
commands. Reference correctness is checked statically; working
authentication is not verified.

## Recovery

```text
agent-resource mcp recover [<transaction-id>] [--action rollback|complete]
agent-resource mcp backup list
```

Mutations run through the same journaled lifecycle as other resources:
retained backups, quarantine, and evidence-backed recovery that acts only on
validated persisted state. `mcp convert` republishes a registration across
harnesses as a separate reviewed operation.
