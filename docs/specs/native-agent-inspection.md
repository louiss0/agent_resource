# Read-only native Agent inspection and validation

## Problem

Agent Resource currently inspects Skills but cannot inspect native Agent definitions without executing a harness or flattening different native contracts into one schema. The next approved roadmap checkpoint is bounded native validation/inspection for Claude, Codex standalone and config-bound roles, and one common Pi profile. Discovery inventory, lifecycle writes, composition, conversion, and parent mutation are separate later work.

## Current command tree

All commands belong under the `agent` group; the user's latest hierarchy decision supersedes any older root-level interpretation. `AgentCommand` owns its related child definitions in `lib/agent.dart`, and the executor registers `AgentCommand` beside `SkillCommand`. No root-level `inspect` or `validate` alias is added.

```text
agent_resource agent inspect [<native-file>] [--request <request.json>]
agent_resource agent validate [<native-file>] [--request <request.json>]
```

Both commands provide `--format text|json` (default `text`) and optional `--cwd <directory/>`. A native file requires explicit `--harness claude|codex|pi`; Markdown is never auto-detected between Claude and Pi. `--show-instructions` is available on inspect only. Bare groups render help. Native source positionals use Mamba `FilePathPositional.optional`; request uses `FilePathOption`, with suffixes as completion hints only.

Native positional and `--request` are mutually exclusive. Request selection implies Codex config-bound form and conflicts with `--harness`. Missing source/harness, blank values, conflicting `--cwd` context, unexpected arguments, and malformed request envelopes fail before native inspection. No `--config`, `--role`, or ownership selector flags are introduced.

## Bound-role request version 1

Inspection and validation requests are bounded UTF-8 JSON, at most 8 MiB, depth 32, and 100,000 parsed nodes. Duplicate keys and unknown envelope fields are rejected. Relative request paths resolve against explicit request working-directory context, not the request file's directory. A relative `workingDirectory` resolves against `--cwd`, or the captured process working directory when `--cwd` is absent; the request file's location is never an implicit base.

```json
{
  "schemaVersion": 1,
  "operation": "inspect",
  "source": {
    "kind": "codex-role",
    "configFile": ".codex/config.toml",
    "roleKey": "reviewer"
  },
  "context": {
    "workingDirectory": "./"
  }
}
```

Exact envelope keys are `schemaVersion`, `operation`, `source`, and `context`; source keys are `kind`, `configFile`, and `roleKey`; context key is `workingDirectory`. `operation` must match the selected command. `kind` is only `codex-role` in this slice. `roleKey` and paths are nonblank strings. `workingDirectory` is required and must agree with `--cwd` when both are present; otherwise it supplies the working directory. Native `config_file` references retain their native base: the declaring config file's parent. Request selection grants read access to that selected binding and referenced definition, not ownership or write authority.

## Evidence profiles

- `claude-agent-native-v1`: recovered Claude official-document snapshot identified by SHA-256 `84b2646c513754ef5f33c6f5a0d7f59960021a65b5a09c35b9158fa116a73d5a`.
- `codex-agent-native-v1`: recovered Codex official-document snapshot SHA-256 `e7469d41c5a18a4ee66ee40ca4a9a2617a697e42554a0198ac4481e1e597357f`, with source-only behavior separately identified by commit `8531184b49bcb160175a84e140b659a83a426df7`.
- `pi-agent-common-v1`: pi-subagents 0.81.0 at `1bc941363cb62fc23c94c5519364b03dc150be3e` and @tintinweb/pi-subagents 0.22.0 at `85a704cb8f35c96c0cabfa665b572bab296942e5`.
- Config-bound roles use the Codex profile plus explicit binding provenance; they are not flattened into standalone definitions.

Profiles are documentation/source-targeted, not runtime certification or minimum-release guarantees. No harness, provider, account, model registry, MCP server, hook, extension, or credential helper is executed or probed.

## Read and parse boundaries

- Definition files are regular, non-link files of at most 1 MiB, read as strict UTF-8 with at most cap+1 bytes and closed on all paths. Explicit linked files are refused without reading their targets. Missing/nondirectory selections are usage/general failures; inaccessible required reads are incomplete inspection failures.
- Markdown frontmatter starts and ends with exact standalone `---` lines and is capped at 64 KiB. LF and CRLF are accepted. The body/instruction string is preserved for hashing and explicit display; native trimming behavior is reported as a runtime qualification, not used to rewrite source.
- Native definition parse depth is 32 and parsed-node budget 10,000. Declaring Codex config is capped at 8 MiB, depth 64, and 100,000 nodes. Requests use the management-document budgets above. Exhaustion is incomplete analysis, never truncated success.
- Duplicate keys are blocking. YAML aliases/anchors, custom tags, and merge keys are blocking product restrictions. Normal block/flow YAML and native TOML constructs are otherwise allowed within field rules. Parsing is non-repairing; malformed native syntax is a failed candidate, not a partially constructed valid definition.
- Reuse fail-closed path observation: `typeSync` `notFound` is absence only after positive parent-listing confirmation. Trusted stable local paths are assumed; no hostile-writer/TOCTOU guarantee is added.

## Native correctness

### Claude

Require string `name` and `description`; do not borrow Skill naming or filename equality. `name` is 1–256 Unicode scalar values, has no colon, and does not start with `-`. Scalar counting is an explicit product choice where native character units are unspecified. Empty description remains permitted because the recovered native contract does not establish a nonblank rule.

Validate documented optional shapes: `tools`/`disallowedTools` string or string list; string `model`; `permissionMode` documented modes plus `manual`; positive integer `maxTurns`; integer `autoCompactWindow` 100000–1000000; `skills` string list with at most 32 distinct names; `mcpServers` list containing strings or maps; map `hooks`; `memory` user/project/local; boolean `background`/`omitClaudeMd`; documented `effort`, `isolation`, and `color` values; string `initialPrompt`; map `experimental` with known `cacheTtl` 5m/1h. Unknown fields are advisory, not proof of native rejection.

### Codex standalone

Require nonblank strings `name`, `description`, and `developer_instructions`. Preserve declared name and report trimmed resolved identity separately. Filename equality is not required. Optional `model` and `model_reasoning_effort` are open strings; summary and verbosity use documented values. `nickname_candidates` follows its separate pinned-source nonblank/unique/ASCII rule and is identified as source-only evidence.

`features` supports only documented keys set to false. Skill config entries require a string path and `enabled: false`; bundled skills and automatic skill instructions support only `enabled: false` and `include_instructions: false` respectively. True values are blocking non-grants, not capability additions. `sandbox_mode`, `approval_policy`, `model_provider`, and `mcp_servers` are blocking known ineffective parent-authority declarations. `personality` and `service_tier` are source-only advisory observations, not portable released-schema guarantees. Unknown fields are advisory because complete nested/live-document behavior is unresolved.

### Codex config-bound role

Read the explicitly selected `[agents.<roleKey>]` declaration without treating unrelated parent keys as Agent fields. Declaration `description`, `config_file`, and `nickname_candidates` retain native types. A referenced role file may omit `name` and `developer_instructions`; role key supplies fallback identity. File description wins, then declaration description; resolved description is required after fallback. File name wins over the role-key hint and disagreement is an advisory observation. This legacy/bound leniency never applies to standalone files. A metadata-only declaration without `config_file` retains inherited instruction state rather than fabricating instructions.

Do not infer cross-layer merging, runtime winner, scope, trust, or activation from one selected declaration. Record declaring config, role key, definition path, and declared-versus-fallback provenance.

### Common Pi

Require nonblank strings `name`, `description`, `model`, and `tools`. Name has no colon or leading/trailing whitespace. Model is explicit `provider/model-id`: nonblank provider and model separated by a slash, with no whitespace or `inherit`/fuzzy/suffix shortcut. Additional slashes in model ID remain opaque.

`tools` is a nonempty comma-separated scalar, not a flow list. Entries are trimmed, nonempty, unique concrete names from the user-approved first catalog: `read`, `grep`, `find`, `ls`. Wildcards, `all`, `none`, `mcp:`, `ext:`, and other names receive product-profile diagnostics. Optional `thinking` is a string from off/minimal/low/medium/high/xhigh/max. Provider-only or semantically incompatible fields are advisory observations, not silently included in a union schema. These rules describe configured metadata compatibility, not identical effective model/tool/context/security behavior.

## Inspection report and privacy

Successful JSON is one success-only envelope with exactly `schemaVersion: 1`, `command`, `outcome`, `data`, and `diagnostics`. Command is `agent inspect` or `agent validate`; outcome is `inspected` or `validated`. Text presents the same facts without decorative snapshots.

`data` contains native `form`, `profile`, `evidence`, `source`, `identity`, `validation`, `instructions`, `references`, `capabilities`, `parentRequirements`, and `ready`. Source and binding paths are normalized absolute lexical paths. Identity distinguishes declared, resolved, and fallback/binding provenance. Validation has sealed `passed|failed|incomplete` status, explicit coverage, and structured diagnostics (`code`, `category`, `severity`, `field`, `message`). Warnings do not make a candidate unready; errors do. No contradictory independent validity boolean is exposed.

References and capabilities are labelled `explicit`, `inherited`, `unresolved`, or `runtime-dependent` as applicable. Record structured Skill/MCP/hook/model/tool/permission declarations and known parent requirements without treating them as effective authority. Do not resolve arbitrary prose, execute commands, expand credentials, inspect external references, or infer read-only enforcement.

Default reports omit whole Markdown bodies and `developer_instructions`. They include instruction byte length, Unicode scalar length, and SHA-256. `--show-instructions` adds exact text only on inspect. Unknown fields are reported by key/type without raw unknown values. Inline MCP/hook configurations and sensitive values are never dumped. Free-form instructions may be private; the flag is not a credential-reveal control.

## Outcomes and statuses

- Inspect is a complete read-only analysis and may succeed with `validation.status: failed` and `ready: false`; this does not mean the candidate passed.
- Validate is the explicit correctness gate. Blocking native/product violations return status 2 with human-readable stderr and no success JSON, including when `--format json` was requested.
- Status 0: successful complete inspection or passed validation.
- Status 1: usage, malformed request, missing selection, or general failure.
- Status 2: blocking validation violations from explicit validate.
- Status 3: required read/parse coverage incomplete, inaccessible input, or budget exhaustion.
- Status 4: linked-file or other unsupported/safety refusal.
- No mutation occurs in either command. Statuses 5–7 are irrelevant to this read-only slice.

Handled failures use stderr through `MambaException`, no partial stdout report. ANSI remains disabled at the executable boundary, so JSON is raw. Success and failure preserve all selected/config/request bytes and create no records, caches, backups, logs, or staging files.

## Acceptance coverage

Use TDD at `createExecutor().fake()` with command paths `agent_resource → agent → inspect|validate`, plus bounded production-process checks. Related assertions may share invocations rather than creating one test per check.

### Command and delivery — 15 checks

1. Root help lists `agent`, not Agent leaf aliases; agent help lists inspect and validate.
2. Leaf help documents explicit harness/source/request/format/privacy behavior.
3. Native positional requires harness and rejects missing/unknown harness.
4. Source and request are exclusive; request rejects harness and conflicting cwd.
5. Missing values, unknown options, unexpected positionals, and blank application values fail.
6. Text is default; JSON has the exact versioned success envelope and canonical command.
7. Inspect failed candidate succeeds with ready false; validate equivalent fails status 2 without success JSON.
8. Operational/incomplete/safety outcomes use statuses 1/3/4 with stderr and no partial stdout.
9. Default output omits instruction sentinels; inspect show-instructions includes exact text.
10. Unknown/sensitive declarations are not dumped by default.
11. Reused adapters do not retain reports, diagnostics, binding, or instructions.
12. Production inspect/validate text and JSON stream/status behavior matches fake results.
13. Help and parser rejection need no source and do not read fixtures.
14. Relative native/request paths resolve against cwd; native config_file resolves against declaring config.
15. Successful and rejected invocations preserve complete sandbox names/types/bytes.

### Native forms and binding — 15 checks

1. Minimal/full Claude definitions and both tools forms are covered.
2. Claude name 256/257, colon, leading hyphen, required fields, optional enums/types/ranges are covered.
3. Claude malformed delimiters/YAML/duplicates/aliases/tags/merge keys and unknown fields are distinguished.
4. Minimal/full Codex standalone definitions and trimmed identity are covered.
5. Codex missing/blank required fields, malformed TOML/types, model knobs, and nickname metadata are covered.
6. Codex supported false-only feature/Skill reductions are reported as explicit restrictions, not runtime proof.
7. True reductions and parent-authority fields are blocking known ineffective declarations.
8. Source-only Codex fields and unknown fields remain qualified advisories.
9. Common Pi four required fields, qualified model, exact CSV tools, and optional thinking pass.
10. Pi missing fields, malformed model, flow-list/empty/duplicate/wildcard/provider tools, colon/whitespace names fail appropriately.
11. Provider-only Pi fields are observed without creating a union schema.
12. Bound role uses role-key name fallback and declaration description fallback with provenance.
13. Bound role may omit developer_instructions; equivalent standalone file fails.
14. Metadata-only binding, name disagreement, missing role/config, and malformed config are distinguished without cross-layer invention.
15. Native capabilities/references/parent requirements remain explicit/inherited/unresolved/runtime-dependent rather than effective guarantees.

### Bounds and inertness — 15 checks

1. Exactly 1 MiB definition and cap+1 are distinguished in bytes, including multibyte input.
2. Exactly 64 KiB frontmatter and cap+1 are distinguished.
3. Request 8 MiB/depth/node limits and duplicate/unknown envelope fields are bounded and rejected appropriately.
4. Declaring config 8 MiB/depth/node limits are enforced independently of definition limits.
5. Strict UTF-8 malformed bytes fail without replacement or partial instruction leakage.
6. Linked selected/definition files are rejected without reading targets; tests explicitly skip only when link creation is unavailable.
7. Missing/nondirectory paths and permission-denied lookups are not conflated.
8. Hook/MCP/command declarations never execute or create marker side effects.
9. No model/provider/account/MCP/network/extension probes occur.
10. No ambient home/config tree is scanned for a direct native-file inspection.
11. Bound inspection reads only request, selected declaring config, and selected definition.
12. Files are closed after success, malformed content, and over-cap reads; rename checks run where supported.
13. No files, ledgers, caches, logs, staging, or backups are created on any outcome.
14. Instruction hashes/lengths are deterministic; original line endings and trailing whitespace are preserved when explicitly shown.
15. Full suite, analysis, formatting, standards review, and spec review pass; unsupported platform fixtures remain explicit skips.

## Out of scope

Agent discovery/listing, uniqueness inventories, ownership/adoption, installation/links, create/clone/edit, dependency graph completion, composition, conversion, parent changes, backups/recovery, runtime activation, and native certification. No new shared `.agents/agents` convention is applied to Claude or Codex.

## Implementation notes

Use `mamba command agent --group`, append the child commands to the same library, and generate the mirrored test suite. Keep native parsing/report construction in one focused engine and share filesystem primitives from `skill_files.dart` where their generic behavior fits; do not create parallel speculative service abstractions. Add only inert parsing/hash dependencies required for TOML and SHA-256. Use `kimi-coding/k3` for subagents. Commit intended files only, preserve `.research-sources/`, and do not push.
