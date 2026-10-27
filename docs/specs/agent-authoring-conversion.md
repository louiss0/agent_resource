# Native Agent authoring, graph analysis, and conversion

## Commands

```text
agent_resource agent create <request.json>
agent_resource agent clone <request.json>
agent_resource agent edit <request.json>
agent_resource agent compose <request.json>
agent_resource agent convert <request.json>
agent_resource agent inspect <native-file> --harness claude|codex|pi
```

All operation requests are bounded UTF-8 JSON with `schemaVersion: 1`, an
operation matching the selected command, explicit native source/target data,
and `context.workingDirectory`. The request positional is canonical.
`--request` is an exclusive compatibility alias on authoring/conversion
commands. Existing Codex bound-role creation requests remain accepted through
`agent create --request`; they are not reinterpreted as general native
creation.

Planning is the default. `--dry-run` is also read-only. Planning creates no
stored plans, locks, journals, staging, backups, logs, or management records.
Noninteractive publication requires `--apply`, the current `--plan-id`, and
`--yes`. Explicit `--interactive` apply may confirm a fresh plan; a supplied
stale token is not repaired. JSON and interactivity conflict, as do apply and
dry-run. Explicit cancellation returns status 7.

Reports use the versioned success-only envelope. Instruction bodies are
omitted by default in favor of part/byte lengths and SHA-256 observations.
`--show-instructions` deliberately includes exact proposed instructions; it
does not reveal credentials or unrelated configuration and is never enabled
implicitly by apply.

## Authoring request

A native creation request contains a target, explicit native fields, and
ordered instruction parts:

```json
{
  "schemaVersion": 1,
  "operation": "create",
  "target": {
    "harness": "pi",
    "destination": "shared",
    "output": ".agents/agents/worker.md"
  },
  "context": {"workingDirectory": "./"},
  "definition": {
    "name": "worker",
    "description": "Works on tasks.",
    "model": "kimi-coding/k3",
    "tools": "read, grep",
    "thinking": "medium"
  },
  "instructions": ["Complete the selected task."]
}
```

Targets select `claude`, `codex`, or `pi`; output is an eligible native file,
or is derived from the declared name in the selected native root. Shared is
project-only common-Pi `.agents/agents`. Claude and Pi use Markdown bodies;
Codex uses `developer_instructions`. Fields are serialized only for the
selected native profile, then parsed with the same native correctness rules as
inspection. Common Pi never receives provider-private union fields.

Clone and edit add a `source` and omit instruction parts for a pure clone:

```json
{
  "kind": "native-file",
  "path": "./reviewer.md",
  "harness": "claude"
}
```

Managed edit sources use `{"kind":"managed-agent","installationId":"..."}`.
Edit also requires `target.installationId`, must identify the same unchanged
managed file, and publishes through retained-backup lifecycle replacement.
Unmanaged edit targets require separate adoption. Clone creates a separate
location and never copies or installs referenced dependencies.

Compose accepts one optional compatible `source` or `base`. `baseInstructions`
is `include` (base followed by explicit parts), `retain` (base only), or
`replace` (explicit parts only). Conflicting base/explicit fields produce a
complete not-ready plan until a field-specific `field:<name>` decision is
present. Unknown/source-only target fields likewise require explicit
resolution; new credential literals are refused.

## Conversion request and field account

Conversion supports all six directions among Claude, Codex (standalone or
config-bound), and common Pi. Source and target profiles must differ. A Codex
bound source uses:

```json
{
  "kind": "codex-role",
  "configFile": ".codex/config.toml",
  "roleKey": "reviewer"
}
```

Target model, tools, and effort/thinking mappings live in `definition` and
also require matching `map:model`, `map:tools`, or `map:effort` decisions.
Other altered native fields require `map:<field>`. `decisions` may instead
contain identifiers such as `omit:tools`, `omit:effort`, `field:experimental`,
or `inherit:model` where legal. Generic approval never substitutes for those
decisions. `references` maps explicit
source associations to reviewed target associations; equal names do not prove
equivalence.

Every relevant source field receives a typed account with source/target path,
source profile, evidence or decision, and one of `represented`, `altered`,
`inherited`, `unresolved`, `unrepresentable`, or `omitted`. Instructions are
`altered` even when their decoded text is identical because Claude body,
Codex developer-instruction, and Pi host-assembly authority differ. Unresolved
or unrepresentable fields produce a complete `ready: false` plan and block
apply. Missing mandatory Pi model/tools cannot be inherited or omitted.

Conversion keeps source and binding bytes unchanged, uses a separate target
by default, validates and analyzes the proposed target before publication,
and reuses regular-file lifecycle ownership, backup, and recovery gates.
Parent prerequisites and target role registration remain separate explicit
plans; common-Pi parent requirements are report-only. No dependency,
credential, hook, memory, transcript, worktree, or runtime state is migrated.

## Graph and capability analysis

`agent inspect` adds typed nodes and edges for native bindings, model
selection, Skill preloads/exclusions, MCP associations, hooks, and other
inspected declarations. Nodes/edges carry source profile, declaration
provenance, native resolution base, coverage, and blockers. Required missing
Claude Skill preloads block readiness; absent Codex disabled-Skill exclusions
do not. Model, MCP, hook, inherited, dynamic, and runtime-dependent targets
remain qualified observations rather than invented local closure.

Traversal is offline and limited to depth 32, 1,000 nodes, 5,000 edges, and
16 MiB of inspected source. It does not infer references from prose or
scripts, execute resources/hooks/helpers/harnesses, inspect credential stores,
or probe accounts/models/servers. Capability and exposure notes retain native
conditions and contrary evidence; they are not a universal permission model,
security score, effective-tool enumeration, or enforcement certification.

Static readiness is not runtime activation, connectivity, availability,
permission enforcement, behavior-lossless conversion, or round-trip
equivalence.
