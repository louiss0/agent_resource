# Agents

Native Agent definitions for Claude, Codex, and Pi retain their distinct
schemas. `agent` covers inventory, inspection, validation, installation,
authoring, conversion, and parent configuration.

## Inventory

```text
agent-resource agent list [--scope project|user|all] [--harness claude|codex|pi]
```

`agent list` defaults to project scope. Claude and Codex project inventory
uses the bounded working-directory-to-project-root ancestor chain; Pi uses
the selected project boundary. Reports contain stable occurrence IDs,
source/binding provenance, native validation observations, and explicit
coverage. Occurrence IDs are not managed installation IDs or mutation
selectors. Traversal is bounded; inventory does not claim runtime
activation, native precedence, or modification status without `--verify`.

## Inspect and validate

```text
agent-resource agent inspect ./reviewer.md --harness claude
agent-resource agent validate ./reviewer.toml --harness codex --format json
agent-resource agent inspect --request ./bound-role.json
```

Native Agent files require an explicit harness — Markdown is not
auto-detected. A bound Codex role is selected with a versioned JSON request
naming its declaring config, role key, operation, and working-directory
context. Reports omit instruction bodies by default (`--show-instructions`
is the explicit privacy choice) and are static observations: no agent, hook,
MCP server, credential helper, model registry, or network service is
executed or probed.

## Install and lifecycle

```text
agent-resource agent install ./reviewer.md --source-kind resource --profile claude --target claude --scope project --yes
agent-resource agent adopt <native-file> --harness claude|codex|pi
agent-resource agent replace <installation-id> <native-file>
agent-resource agent remove <installation-id>
agent-resource agent backup list
agent-resource agent recover [<transaction-id>]
```

Agents are copy-only: `--profile` declares a direct file's native schema,
never converts it, and the validated source basename is preserved at the
application-owned native destination. Installation does not create links,
register Codex roles, or edit parent configuration. Agents have no
source-bound update or route migration — re-author the definition and
`agent replace` the managed installation. `agent convert` republishes
across harnesses.

## Authoring

```text
agent-resource agent create --profile claude|codex|pi --name <name> --description <text> --body-file <file>|--body-stdin|--body-text <text>
agent-resource agent clone <request.json>
agent-resource agent edit <request.json>
agent-resource agent compose <request.json>
agent-resource agent convert <request.json>
```

Creation takes named native selections and plain text with an explicit
profile and exactly one body source. On a usable terminal the guided flow
collects missing fields and opens the configured editor; `--unattended` and
`--format json` never prompt. The Codex bound-role route
(`--role-key`/`--config-file`/`--ownership`) publishes the reviewed
definition and registers the role only when `--ownership both` selects it,
with a separate `--ack-clients-stopped` acknowledgement.

Conversion covers all six Claude/Codex/common-Pi directions and reports
per-field outcomes before publication. Static readiness does not claim
runtime activation, behavior-lossless conversion, model/tool availability,
or permission enforcement.

## Parent configuration and bound roles

```text
agent-resource agent config inspect --request <request.json> --scope project|user
agent-resource agent config plan --request <request.json> --scope project|user
agent-resource agent config apply --request <request.json> --scope project|user --yes --ack-clients-stopped
```

Supported typed units include Claude permissions/sandbox/model/environment/
MCP selections and Codex approval/sandbox/model/MCP/registration selections.
Managed, system, authentication, and session-enforced sources remain refusal
or inspect-only. Plans return a stable ID bound to the request, context,
source fingerprint, and selected values; apply requires that exact ID,
approval, and stopped-client acknowledgement. JSON edits preserve unrelated
bytes; TOML edits preserve comments and unknown members. Credential literals
are rejected and existing secrets are not reported.
