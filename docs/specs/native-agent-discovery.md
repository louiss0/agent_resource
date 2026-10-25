# Bounded native Agent discovery and identity

## Scope

Implement the next approved roadmap checkpoint after native Agent inspection: bounded discovery/inventory and location-based occurrence identity. Add `agent_resource agent list`; the command remains a child of `AgentCommand` in `lib/agent.dart`, with no root alias. This is read-only inventory, not native activation, lifecycle ownership, uniqueness enforcement for a mutation, dependency-graph completion, or runtime winner resolution.

No installation, adoption, replacement, removal, ledger creation, composition, conversion, parent change, network request, harness/agent/MCP/hook/extension execution, or registry/account/model probe is authorized.

## Command and explicit context

```text
agent_resource agent list [--scope project|user|all]
                          [--harness claude|codex|pi]
                          [--cwd <directory/>]
                          [--project-root <directory/>]
                          [--home <directory/>]
                          [--claude-config-dir <directory/>]
                          [--codex-home <directory/>]
                          [--pi-agent-dir <directory/>]
                          [--read-root <directory/> ...]
                          [--verify]
                          [--format text|json]
```

Use retained Mamba typed choices, folder options, repeatable folder options, flags, and valueOf. Scope defaults `project`; harness is an optional presentation filter. Format defaults text. Bare groups still render help. `--verify` requests baseline comparison where managed baselines exist; this slice has no managed installations, so occurrences remain modification-not-verified and the report states that no managed baseline was available. Never invent an unchanged result.

`--cwd` overrides captured process cwd. `--project-root` is explicit; otherwise use the nearest `.git` file/directory from cwd, else cwd. Limit ancestor discovery to 64 steps. An explicit project root must contain cwd lexically after absolute normalization. Do not run git or scan to filesystem root without a boundary. All relative context paths resolve against captured/selected cwd as applicable; typed declarations do not expand home/environment variables.

Explicit context precedence:

- Home: `--home`, else captured HOME/USERPROFILE as appropriate for the host; required for user/all scopes.
- Claude config: `--claude-config-dir`, else captured CLAUDE_CONFIG_DIR, else `<home>/.claude`.
- Codex home: `--codex-home`, else captured CODEX_HOME, else `<home>/.codex`.
- Pi Agent directory: `--pi-agent-dir`, else captured PI_CODING_AGENT_DIR, else `<home>/.pi/agent`.

These application context overrides do not configure native clients. Environment is captured at the command boundary and represented by an injected context value; tests never read or mutate the developer's real harness directories.

## Roots and native forms

Project inventory uses the bounded cwd-to-project-root ancestor chain for Claude and Codex, nearest first:

- Claude: `<ancestor>/.claude/agents`, recursively.
- Codex standalone: `<ancestor>/.codex/agents`, recursively for exact lowercase `.toml` files.
- Codex bound declarations: `<ancestor>/.codex/config.toml`, only `[agents.<role>]` entries and their explicitly referenced definition/metadata.

Project Pi uses only the selected project boundary, not an invented ancestor chain:

- `<project>/.pi/agents`: immediate `.md` entries are common-profile candidates; deeper `.md` entries are provider-specific candidates.
- `<project>/.agents/agents`: the same immediate-versus-deeper distinction. This is the evidenced project Shared Pi destination, not a Claude/Codex root or universal user root.

User inventory:

- Claude: `<claude-config-dir>/agents`, recursively.
- Codex standalone: `<codex-home>/agents`, recursively; declarations from `<codex-home>/config.toml`.
- Pi: `<pi-agent-dir>/agents` with the same immediate/deeper distinction. No universal `~/.agents/agents` inventory is invented.

Each additional `--read-root` contributes only its evidenced `<read-root>/.claude/agents` project-scope tree. It grants read access, not ownership or write eligibility, and does not create Codex/Pi roots. A harness filter narrows presentation only after the selected context is validated; it does not silently retarget roots.

Native trust, enablement, managed/plugin/session sources, selected Codex profile files, cross-layer fallback, runtime precedence, and effective dispatch are not reconstructed. Coverage/report provenance states this limitation. A declaration occurrence and a standalone-file occurrence remain separate unless native association is explicitly established; never deduplicate by name or content. No management authority follows from physical/path identity.

## Bounded traversal and failure isolation

Approved Agent inventory maxima are independently binding:

- 64 ancestor steps;
- depth 16 within each root;
- 20,000 entries total;
- 2,000 directories total;
- 64 MiB aggregate definition/config metadata bytes read.

Use iterative or bounded traversal with `followLinks: false`; do not follow linked directories/files. Linked candidate files are reported as unsupported linked occurrences without target reads. Linked roots are safety refusals. Nested directories and finite cycles through links must not cause recursion. Missing expected roots are confirmed absent using the existing fail-closed parent-listing helper. Lookup/list/read failures, exhausted budgets, or required malformed declaring config make the required inventory incomplete with status 3 and no success JSON. An explicitly selected invalid context is status 1; linked-file/root safety refusal is status 4.

Malformed native candidates remain visible with failed validation and do not fail an otherwise complete list. Candidate parsing uses the existing native engine and its per-file limits. A candidate over budget or an inaccessible required candidate makes coverage incomplete rather than silently omitting it. Unknown fields remain bounded key/type observations. No instruction bodies or sensitive inline configuration values appear in inventory.

## Occurrence identity and management evidence

Each occurrence reports:

- `occurrenceId`: SHA-256 over a versioned occurrence kind, explicit scope, harness/native form, normalized lexical location, and binding config/role key where applicable. This is a stable inventory occurrence identifier only, **not** a managed installation ID, ownership proof, physical deduplication claim, or mutation selector.
- normalized absolute lexical `path` (definition path, or declaring config for metadata-only roles), `root`, `scope`, `harness`, `destination` (`native` or `shared`), and native `form`.
- `binding`: null or declaring config/role key/definition path provenance.
- `eligibility`: `native`, `provider-specific`, or `unsupported-link`; no installation/adoption eligibility is implied.
- declared/resolved identity and fallback provenance when parseable; malformed candidates retain unresolved fields rather than filename-derived identity.
- sealed validation status/coverage and structured diagnostics; warnings do not become errors.
- `management: unmanaged` and `modification: notVerified` for this pre-lifecycle slice. No occurrence is called managed, unchanged, owned, active, or unique.

Strict per-target name uniqueness remains a required gate for later mutations. List reports name collisions/conflicting occurrences as observations and does not apply a shadowing winner, rename, force, whole-machine uniqueness, or mutation refusal. Known builtin collision policy is not silently converted into a runtime activation claim. Common Pi comparisons include its conservative case-insensitive collision observation while preserving original spelling.

## Output and statuses

Successful JSON uses the existing success-only envelope: `schemaVersion: 1`, `command: agent list`, `outcome: inventoried`, `data`, and `diagnostics`. Text renders the same occurrence/coverage facts without decorative snapshots.

`data` contains `scope`, `verification`, `occurrences`, `collisions`, and `coverage`. Coverage includes completed/incomplete semantics, roots considered/scanned/absent, ancestor/depth/entry/directory/metadata-byte counts and limits, and explicit native/runtime exclusions. `ancestors` counts the selected project chain including cwd and boundary (zero for user-only inventory); `boundarySearchSteps` separately counts automatic `.git` probes (zero for an explicit boundary). `depth` is the maximum scanned directory depth, with native roots at zero. Entry/directory counts cover native-tree enumeration, not the streaming, non-retaining parent listings used solely to confirm absence. Overlapping roots in the same scope/harness do not repeat candidate enumeration or reads. Returned success coverage is complete for the selected bounded static inventory, not exhaustive live runtime discovery. Envelope diagnostics contain scan-level advisories; candidate diagnostics remain with their occurrence.

Statuses:

- 0: complete static inventory, including malformed or colliding candidates;
- 1: invalid invocation/context/request relationship;
- 3: required inventory/read/coverage incomplete or budget exhausted;
- 4: linked-root or other safety refusal.

No status-2 list result: list is not the explicit correctness gate. Use `agent validate` for that gate. Handled failures use stderr with no partial stdout. No files, caches, logs, ledgers, staging, backups, or recovery records are created.

## Acceptance coverage

Use TDD through `createExecutor().fake()` at `agent_resource → agent → list`, plus bounded production smoke. Reuse temporary filesystem/process helpers and existing native engine; do not duplicate full native-validator tests.

### Command/context/output — 15 checks

1. Agent/root help lists list without root aliases; help documents context, bounds, and non-claims.
2. Scope defaults project; user/all and harness filters are explicit choices.
3. Invalid choices, missing folder values/separators, unknown options, and unexpected positionals reject.
4. Explicit project root must contain cwd; nearest .git file/directory and no-git fallback are distinguished.
5. Ancestor traversal stops at 64 steps and never scans above the selected boundary.
6. Explicit home/config/Pi overrides beat isolated environment values; no ambient real-home reads occur.
7. Relative paths resolve only against documented context bases.
8. Read roots add only Claude project trees and never ownership/write eligibility.
9. Text default and exact JSON envelope/data shapes agree.
10. Occurrence IDs are deterministic, scope/form/binding-sensitive, and not represented as installation IDs.
11. Reused adapters do not retain occurrences, coverage, collisions, or environment context.
12. Production project JSON and user/all text behavior match fake results and use correct streams/statuses.
13. Malformed candidates remain successful occurrences; required unreadable/incomplete coverage fails status 3.
14. Linked candidate entries are visible without target reads; linked roots refuse status 4 with explicit platform skips.
15. Success/failure/help preserve the complete sandbox and create no management artifacts.

### Roots/forms/identity — 15 checks

1. Claude project ancestor and user roots are recursively inventoried.
2. Codex project ancestor and user standalone TOML roots are recursively inventoried.
3. Codex config declarations include referenced and metadata-only roles with binding provenance.
4. Declaration and standalone occurrences are not deduplicated merely by name/content/association assumption.
5. Pi project `.pi/agents` and Shared `.agents/agents` immediate candidates are native/common occurrences.
6. Deeper Pi files are provider-specific and not called common-profile installations.
7. Pi user root uses configured Pi Agent dir; no universal user Shared root is invented.
8. Filename need not equal native name; malformed files do not acquire filename identity.
9. Bound fallback identity is preserved; unrelated parent config is not flattened into the role.
10. Destination, scope, and consuming harness remain independent fields.
11. Same-name Claude/Codex/Pi occurrences remain distinct; per-target collisions are reported without winner selection.
12. Common Pi collision observations include case-insensitive matches without normalizing output names.
13. Linked files, wrong extensions, ordinary directories, and nested non-Agent files follow exact candidate rules.
14. Management remains unmanaged and modification notVerified, including --verify; no runtime-active/owned/unchanged claim appears.
15. Capability/reference/instruction bodies and inline secrets are not dumped into inventory.

### Bounds/failure/inertness — 15 checks

1. Depth 16 is accepted where native form permits and deeper required content makes coverage incomplete.
2. Entry budget 20,000 and directory budget 2,000 are enforced before unbounded traversal.
3. Aggregate 64 MiB metadata reads and per-file native caps are independently enforced.
4. Missing roots are positively confirmed absent without creating them.
5. Lookup/list failures are not misreported as empty inventory.
6. Inaccessible required candidate/config reads fail status 3 without partial JSON.
7. Malformed candidate YAML/TOML remains a failed occurrence, not failed inventory.
8. Malformed required declaring config makes inventory incomplete.
9. Missing referenced bound definition follows native inspection incompleteness without losing other output on failure.
10. Linked directories/cycles are not followed and do not cause unbounded recursion.
11. No hooks/MCP/process/extension/network/model/account probes occur.
12. Only selected native roots/config/definitions and explicit read roots are read.
13. No raw instructions, unknown values, MCP/hook inline values, or credentials appear in text/JSON/errors.
14. File handles close after successful, malformed, and over-cap candidate reads.
15. Full suite, analysis, formatting, code-review standards/spec axes, and explicit platform skips are reported honestly.

## Implementation notes

Use `mamba command agent_list --append lib/agent.dart`, rename the generated child to `AgentListCommand`/`list`, and keep it registered in `AgentCommand`. Add one focused inventory engine only if it reduces traversal/context complexity; reuse `agent_inspection.dart` for candidate validation rather than copying schemas. Expose a focused bound-role inspection entry point instead of writing request fixtures or duplicating binding logic. Add a focused `test/agent_list_test.dart` because the existing generated Agent suite is already large. No general-purpose implementation subagents; use subagents only for skill-mandated review. Commit intended files only, preserve `.research-sources/`, and do not push.
