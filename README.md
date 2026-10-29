# Agent Resource

Agent Resource is a Mamba command-line application for managing resources
consumed by AI coding harnesses. The current scope provides application help
and version reporting, management-aware Skill and Agent inventories, native
inspection/validation, bounded dependency/capability graphs, native Agent
create/clone/edit/compose workflows, all-six conversion, canonical, copied,
and source-linked Skill installation, native Agent copies and adoption,
unchanged-only replacement/removal, retained backups, explicit
restore/cleanup, and evidence-backed transaction recovery. Claude, Codex, and the common Pi
profile remain distinct native contracts.

## Requirements

- Dart SDK 3.13.2 or newer

## Get dependencies

From the package root, resolve the Dart dependencies:

```text
dart pub get
```

## Run

Run the executable directly:

```text
dart run bin/agent_resource.dart
dart run bin/agent_resource.dart --help
dart run bin/agent_resource.dart --version
```

The no-argument and `--help` invocations show root help. Root help lists the
`skill` and `agent` groups. Each group provides `list`, `inspect`, `validate`,
`install`, `adopt`, `replace`, `remove`, `backup`, and `recover` paths. There
are no root-level aliases, and `skill discover` is not retained as a second
inventory verb. Unsupported commands and options fail with a nonzero exit
status.

```text
dart run bin/agent_resource.dart skill --help
dart run bin/agent_resource.dart agent --help
```

## Commands

### Inventory Skills and Agents

```text
dart run bin/agent_resource.dart skill list [--scope user|project|all]
dart run bin/agent_resource.dart agent list [--scope project|user|all]
```

Skill scope defaults to user; Agent scope defaults to project. Use `--cwd`,
`--project-root`, `--home`, native-home overrides, and `--state-dir` to select
isolated context. Relative operation paths resolve against `--cwd`. Both
inventories distinguish unmanaged candidates, managed installations,
tracked-missing records, and ownership-unverified evidence. `--verify` performs
a fresh baseline comparison; without it, modification is `notVerified`.

Skill destinations are `.claude/skills`, `.codex/skills`, and
`.agents/skills`. Direct ordinary children are eligible for copy adoption;
nested Skill discoveries remain visible but ineligible. Linked candidates are
reported without reading their targets. Agent inventory retains its native
recursive Claude/Codex, immediate common-Pi, and config-binding observations.
Occurrence IDs are not lifecycle mutation selectors.

Inventory is bounded and read-only. Incomplete required traversal fails rather
than returning partial JSON. Shared storage and native discovery conventions
do not prove runtime activation, precedence, or harness compatibility.

### Install Skills and native Agents

Text installation is interactive by default on a usable terminal. It prompts
for a missing source and required selections, displays the complete plan, and
asks for approval before writes. Skill scope and method default to `user` and
`canonical`; Agent scope defaults to `project`. These defaults are not assumed
for unattended or JSON installation.

Interactive components use `interact2`; Mamba remains the command framework.
Confirmations default to No and require Enter. Raw-key confirmations are never
run with redirected input: without a usable terminal they decline without
reading stdin. Use explicit unattended options and `--yes` for automation.

```text
agent_resource skill install [source]
  [--resource <catalog-id> ... | --all-resources]
  [--target claude|codex ...] [--scope project|user]
  [--method canonical|copy|source-link] [--ref <revision>]
  [--subpath <source-relative-path>] [--source-kind collection|resource]
  [--dry-run] [--yes] [--format text|json]

agent_resource agent install [source]
  [--resource <catalog-id> ... | --all-resources]
  [--target claude|codex|pi ...] [--profile claude|codex|pi-common]
  [--scope project|user] [--ref <revision>]
  [--subpath <source-relative-path>] [--source-kind collection|resource]
  [--dry-run] [--yes] [--format text|json]
```

A source can be an explicit local path, Git locator, GitHub `owner/repo`
shorthand or root repository URL (with or without `.git`), direct download,
or archive. `--ref` is Git-only; `--subpath` bounds discovery to one selected
source-relative root. Existing local paths take precedence over shorthand;
use `./` to explicitly request a local path.

For Skills, repositories are acquired into a temporary inert workspace, then
searched for exact `SKILL.md` markers. Without a catalog or exact root Skill,
discovery recursively searches `skills/`, `.agents/skills/`, `.claude/skills/`,
and `.codex/skills/`. If none exists, it searches the selected tree instead.
Hidden descendants, `node_modules`, and `vendor` are skipped; links are not
followed, and traversal stops at each Skill package. Unrelated Git symlinks
are left unmaterialized; selected packages containing links are refused rather
than installed incomplete. Limits are depth 16,
2,000 directories, 20,000 entries and 1,000 Skills. Discovered selection IDs
are source-relative directory paths, such as `skills/category/review`.
Interactive collections show a picker; automation requires exact IDs through
`--resource` or explicit `--all-resources`. `--yes` never selects resources.
A present `agent-resources.toml` stays authoritative. Agents remain
catalog/exact-file only. No automatic dependency installation occurs.

```text
dart run bin/agent_resource.dart skill install mattpocock/skills
dart run bin/agent_resource.dart skill install https://github.com/mattpocock/skills/
dart run bin/agent_resource.dart skill install mattpocock/skills --scope user --target codex --method canonical --all-resources --dry-run
```

Unattended and JSON invocations require an explicit source and scope, consuming
targets, catalog selection where applicable, and `--yes` for the current final
plan. They also require exact resources to use `--source-kind resource`; Skills
must specify `--method`, and direct Agent files must specify a consistent
`--profile` and single `--target`. `--dry-run` previews without approval or
management writes. `--yes` grants no force, takeover, repair, adoption, or
selection authority.

For example, these unattended commands install one exact Skill canonically for
both consumers and one Claude Agent as a native copy:

```text
agent_resource skill install ./reviewer --source-kind resource --target claude --target codex --scope user --method canonical --yes
agent_resource agent install ./reviewer.md --source-kind resource --profile claude --target claude --scope project --yes
```

Skill `canonical` owns content in scope-specific `.agents/skills`. Codex reads
that content directly; Claude receives a managed native exposure link.
`copy` creates independent native copies, while `source-link` manages links to
an explicitly selected durable local Skill directory. Remote, temporary, and
single-file sources are ineligible for `source-link`. The Skill's declared name
determines its destination name. Agents are copy-only: `--profile` declares a
direct file's native schema, never converts it, and the validated source
basename is preserved at the application-owned native destination. Agent
installation does not create links, register Codex roles, or edit parent
configuration.

A curated collection has an `agent-resources.toml` at its selected root.
Skill collections can alternatively use the discovery conventions above. Its version-1
TOML schema uses exact IDs and safe source-relative paths; Agent entries must
declare their profile:

```toml
schema_version = 1

[[skills]]
id = "code-reviewer"
path = "skills/code-reviewer"
label = "Code reviewer"

[[agents]]
id = "claude-reviewer"
path = "agents/reviewer.md"
profile = "claude"
label = "Claude reviewer"

[[agents]]
id = "pi-reviewer"
path = "agents/pi-reviewer.md"
profile = "pi-common"
```

Catalog entries support only `id`, `path`, and optional `label` for Skills,
plus required `profile` for Agents. Profiles are `claude`, `codex`, or
`pi-common`. IDs are lowercase ASCII kebab-case. A direct downloaded TOML file
does not authorize crawling its host; select the containing local repository,
Git repository, or archive instead.

The retired install options `--destination`, `--harness`, `--mode`, and
`--interactive`, and Agent `--output`, are rejected with migration guidance.
Use `--target`, `--method`, and direct-Agent `--profile` as applicable. See
[the installation migration guide](docs/migrate-interactive-installation.md)
for safely replacing old managed installations.

Install JSON success uses a schema-version-2 envelope with `command`,
`outcome`, `data`, and `diagnostics`; `data` contains `planId`, sanitized
`source`, `scope`, `units`, and `summary`. Outcomes are `planned`, `installed`,
or `unchanged`. Failures emit no success JSON and leave stdout empty; Mamba
reports human-readable aggregate diagnostics and recovery guidance on stderr
with a nonzero status. Human text and Mamba errors may use normal terminal
color; JSON success data is plain and contains no prompts or progress output.

### Adopt, replace, remove, back up, and recover

```text
agent_resource skill adopt <existing-directory/> --destination claude|codex|shared
agent_resource skill replace <installation-id> <source-directory/>
agent_resource skill remove <installation-id> [--target claude]
agent_resource skill backup list
agent_resource skill backup restore <backup-id>
agent_resource skill backup cleanup <backup-id>
agent_resource skill recover [<transaction-id>] [--action rollback|complete]

agent_resource agent adopt <native-file> --harness claude|codex|pi
agent_resource agent replace <installation-id> <native-file>
agent_resource agent remove <installation-id>
agent_resource agent backup list
agent_resource agent backup restore <backup-id>
agent_resource agent backup cleanup <backup-id>
agent_resource agent recover [<transaction-id>] [--action rollback|complete]
```

Adoption records an eligible existing resource without rewriting its bytes.
Replacement and restoration preserve installation identity and recorded
location. Removal and replacement require a currently unchanged complete
baseline and create independent retained backups before live mutation.
Canonical replacement preserves its method and accounts for all associated
exposures and direct consumers. Canonical `skill remove --target claude`
detaches only the managed Claude exposure; Codex's direct consumer relationship
cannot be revoked by metadata removal while shared content remains.

Linked Skills keep target validation separate from entry ownership. Target
edits do not invalidate an unchanged link entry; removal unlinks an unchanged
entry even when its target is broken or inaccessible and never deletes the
external target. Link backups retain the entry kind and target representation,
not target-content history, and restore revalidates the target at its original
parent before publication. Legacy replacement without `--mode` retains the
recorded copy/link mode; an explicit legacy mode change is a reviewed
conversion at the same installation ID and location.

`--dry-run` performs read-only planning and creates no locks, journals,
ledgers, staging, or backups. Replacement, removal, restore, cleanup, and
recovery actions require `--yes`, or an explicit `--interactive` reviewed
confirmation. Lifecycle state is stored per project at `.agent-resource` or in
the selected user state directory. Native files never receive management
receipts. Recovery acts only on validated persisted evidence and exact
current-path guards. It cannot overwrite new occupants, erase newer edits, or
guess an interrupted outcome. Backup cleanup is never automatic and does not
promise secure erasure.

The implementation uses bounded acquisition and local-disk IO,
same-filesystem staging, protected intent, independent backups, quarantine,
and per-scope coordination. It does not claim hostile-writer resistance, joint
resource-plus-ledger atomicity, universal metadata fidelity, or guaranteed
power-loss durability. Windows linked installations require a true directory
symlink and actionable privilege diagnostics; junctions, unknown reparse
forms, and copy fallback are refused. Runtime resource execution and live
harness/account probes remain outside the application contract.

### Inspect one skill directory

```text
dart run bin/agent_resource.dart skill inspect --skill <directory>
```

`skill inspect` requires the explicit named `--skill` directory selection. Relative
paths are resolved against the current working directory and returned as
normalized absolute lexical paths; a selected directory link is allowed without
canonicalizing its returned path. The command checks only the immediate exact
`SKILL.md` entry. An absent marker, directory, or link reports
`"hasSkillFile": false` and `"content": null`; a regular file reports
`"hasSkillFile": true` and its exact decoded text, including line endings,
trailing whitespace, and empty content.

Successful output is exactly one JSON object with these fields:

```json
{"path":"/absolute/selected/directory","hasSkillFile":true,"content":"..."}
```

Marker reads are strict UTF-8 (with the standard leading UTF-8 BOM behavior)
and are limited to 1,048,576 bytes; a file requiring more bytes is rejected.
The implementation reads at most one byte beyond that limit to detect an
oversized marker. Failures are reported on stderr with a nonzero status and do
not produce partial JSON on stdout.

Inspection is read-only and non-recursive. It does not follow a linked
`SKILL.md`, read nested markers, parse frontmatter, validate skill content,
infer destination or installation scope, record management ownership, or claim
compatibility with any consuming harness.

### Validate one skill directory

```text
dart run bin/agent_resource.dart skill validate --skill <directory>
```

`skill validate` requires the explicit named `--skill` directory. It applies the
named bounded product profile `agentskills-core-ascii-v1` against the pinned
Agent Skills baseline at commit
`69ef37e9424c0a7ea9dd2293b559e43ec8176379`. A selected skill directory may be
a directory link, but its immediate `SKILL.md` marker must be a regular,
non-link file; linked markers are a product restriction. The command is
read-only: it does not execute scripts, inspect
or follow references, make network requests, fetch dependencies, or mutate the
skill directory. It makes no claim of full Agent Skills compliance, runtime
safety, harness acceptance, or filesystem sandboxing.

The profile uses literal `name`/directory-basename matching and counts their
Unicode scalar values. It requires the required metadata fields and their
bounds: `name` is a non-empty string of 1–64 characters with the required
lowercase/hyphen shape and matching basename; `description` is a non-empty
string of 1–1024 characters; `compatibility`, when present, is a string of
1–500 characters; `license` and `allowed-tools`, when present, are strings;
and `metadata`, when present, is a map with string keys and string values. The
profile's bounded-ASCII name restriction is product policy, not a claim that
the upstream specification universally rejects non-ASCII names. Unknown
frontmatter fields are advisory diagnostics, not an automatic invalidation;
`metadata` is the documented extension map.

Input is strict UTF-8, with standard leading-BOM behavior, and is capped at
1 MiB (1,048,576 bytes). The YAML frontmatter is capped at 64 KiB (65,536
bytes) and must use exact standalone delimiter lines (`---` at the beginning
and closing the frontmatter); LF and CRLF line endings are accepted. The
remaining content is Markdown. No additional body, script, reference, or
asset compliance is inferred from this check.

A completed validation returns exactly one JSON report with these top-level keys:

```json
{
  "path": "/absolute/selected/directory",
  "profile": "agentskills-core-ascii-v1",
  "baseline": "69ef37e9424c0a7ea9dd2293b559e43ec8176379",
  "valid": true,
  "diagnostics": []
}
```

`path` is the normalized absolute lexical selected directory. `diagnostics` is
an array. Each diagnostic has exactly `code`, `category`, `severity`, `field`,
and `message`; `category` is `specification`, `product`, or `advisory`,
`severity` is `error` or `warning`, and `field` is either the affected field
name or `null`. `valid` is true exactly when there are no error diagnostics;
advisory warnings alone remain valid. Valid reports are written to stdout with
status 0. An invalid report is still the same JSON shape, but is written to
stderr by a status-2 failure. Malformed UTF-8 is a product diagnostic in that
invalid report and therefore also uses status 2, not operational status 1.
Filesystem/I/O and other operational command errors are plain human-readable
stderr failures with status 1, rather than fabricated reports. Report JSON is raw and directly parseable on either stream; normal human
output and Mamba stderr may be colored.

### Discover native Agent occurrences

```text
dart run bin/agent_resource.dart agent list
dart run bin/agent_resource.dart agent list --scope user --home <directory/>
dart run bin/agent_resource.dart agent list --scope all --format json
```

`agent list` defaults to project scope and supports explicit `user` and `all`
scopes plus an optional harness filter. Claude and Codex project inventory uses
the bounded working-directory-to-project-root ancestor chain; Pi uses the
selected project boundary. Explicit context options cover cwd, project root,
home, Claude config, Codex home, Pi Agent home, and additional Claude read
roots. Environment-provided native homes are used only when corresponding
options are absent.

Inventory includes recursive Claude/Codex candidates, Codex config-declared
roles, and Pi native/Shared candidates. Immediate Pi files are distinguished
from deeper provider-specific candidates. Reports contain stable occurrence
IDs, source/binding provenance, native identity and validation observations,
collisions, and explicit coverage. Occurrence IDs are not managed installation
IDs or mutation selectors. Unmanaged, managed, tracked-missing, and
ownership-unverified occurrences remain distinct; without `--verify`,
modification is `notVerified`, and verification never invents a baseline.

Traversal is limited to 64 ancestors, depth 16, 20,000 entries, 2,000
directories, and 64 MiB of aggregate metadata. Linked candidates are reported
without reading their targets; linked roots are refused. Missing roots are
confirmed absent. Malformed candidates remain visible in a successful static
inventory, while inaccessible required coverage or budget exhaustion fails
with status 3 and no partial JSON. Inventory does not claim runtime activation,
native precedence, uniqueness winners, ownership, or modification status.

### Inspect or validate a native Agent definition

```text
dart run bin/agent_resource.dart agent inspect ./reviewer.md --harness claude
dart run bin/agent_resource.dart agent validate ./reviewer.toml --harness codex --format json
dart run bin/agent_resource.dart agent inspect ./reviewer.md --harness pi --show-instructions
dart run bin/agent_resource.dart agent inspect --request ./bound-role.json
```

Native Agent files require an explicit harness: `claude`, `codex`, or `pi`.
Markdown is not auto-detected. The common Pi profile requires name,
description, a qualified `provider/model-id`, and a nonempty CSV using the
currently evidenced shared tools `read`, `grep`, `find`, and `ls`. Claude,
Codex standalone, and Codex config-bound roles retain their distinct native
schemas; Skill naming and directory rules are not applied to Agents.

A bound Codex role is selected with a versioned JSON request containing its
declaring config, role key, operation, and explicit working-directory context.
Its native `config_file` remains relative to the declaring config. Bound roles
may use native name/description/instruction fallback; standalone files may not.
The request schema and exact examples are documented in
`docs/specs/native-agent-inspection.md`.

Agent output defaults to text. `--format json` produces a versioned success
envelope with native form/evidence, source and binding provenance, validation
coverage, references, capabilities, and parent requirements. These are static
observations, not proof of runtime activation, model/tool availability,
permissions, sandboxing, or harness compatibility. No Agent, hook, MCP server,
extension, credential helper, model registry, or network service is executed
or probed.

Reports omit instruction bodies by default and instead include byte/scalar
lengths and SHA-256. `agent inspect --show-instructions` explicitly includes
the exact free-form instructions, which may be private. Unknown or sensitive
declarations are not dumped.

A complete `agent inspect` may succeed with `ready: false` and failed candidate
diagnostics. `agent validate` is the correctness gate and returns status 2 for
blocking violations without a success JSON report. Usage/general failures use
status 1, incomplete required analysis or exhausted budgets status 3, and
linked-file/safety refusals status 4. Inspection, validation, and inventory
are read-only. `agent inspect` includes bounded typed dependency edges,
source-qualified capabilities, exposure notes, and missing-reference blockers
without executing or inferring runtime dependencies. Regular-file lifecycle
operations are documented above.

### Create, clone, edit, compose, and convert native Agents

```text
agent_resource agent create <request.json>
agent_resource agent clone <request.json>
agent_resource agent edit <request.json>
agent_resource agent compose <request.json>
agent_resource agent convert <request.json>
```

Authoring and conversion requests are bounded, versioned JSON with explicit
native source/target/context data. Planning is read-only by default and
creates no management artifacts. Apply requires `--apply`, the current
`--plan-id`, and `--yes`, or explicit interactive review. Ordered instruction
parts, base conflicts, unknown fields, model/tool/effort mappings, reference
changes, and deliberate omissions are reported before publication. Default
reports omit instruction bodies; `--show-instructions` is an explicit privacy
choice.

All six Claude/Codex/common-Pi conversion directions produce native target
candidates with per-field represented/altered/inherited/unresolved/
unrepresentable/omitted outcomes. Changed controls need field-specific
decisions; generic approval cannot approve unknown losses. Sources and
bindings remain unchanged. Parent prerequisites and Codex target registration
remain separate explicit plans. Publication reuses native validation, graph
readiness, lifecycle ownership, retained backups, and recovery. Request
schemas and examples are in `docs/specs/agent-authoring-conversion.md`.

Static readiness and textual preservation do not claim runtime activation,
behavior-lossless conversion, model/tool availability, or permission
enforcement.

### Manage native parent settings and Codex bound roles

```text
agent_resource agent config inspect --request <request.json> --scope project|user
agent_resource agent config plan --request <request.json> --scope project|user
agent_resource agent config apply --request <request.json> --scope project|user --yes --ack-clients-stopped
agent_resource agent create --request <request.json> --scope project|user
agent_resource agent adopt <native-file>|--request <request.json> --harness codex
agent_resource agent replace <installation-id> <native-file>|--request <request.json>
agent_resource agent remove <installation-id>|--request <request.json>
```

Parent requests select the native harness, scope, layer, and source file
explicitly; Agent project defaults never choose a parent file. Supported typed
units include Claude permissions/sandbox/model/environment/MCP selections and
Codex approval/sandbox/model/MCP/registration selections. Managed, system,
authentication, and session-enforced sources remain refusal or inspect-only.

Inspection and planning are read-only. Plans return a stable ID bound to the
request, context, source fingerprint, selected values, ownership decisions, and
known impacts. Apply requires that exact ID, approval, and a separate
`--ack-clients-stopped` acknowledgement (`--clients-stopped` remains a
compatibility alias). JSON edits preserve unrelated bytes and
ordering; TOML edits preserve comments, trivia, and unknown members. Credential
literals are rejected, existing secrets are not reported, and runtime
enforcement/activation remains unverified.

Codex bound-role requests identify the declaring config and role key. They may
select registration ownership, definition ownership, or both explicitly.
Definition paths resolve from the declaring config, standalone install never
implicitly registers, and removing a registration never deletes its definition
or unrelated roles. Bound-role creation plans by default and publishes only the
reviewed definition/registration pair.

Parent backups retain private prior document/selected-unit evidence for
selective restore. `agent backup restore` for a parent backup requires a fresh
plan ID and stopped-client acknowledgement; restore patches only approved units
into the current document and preserves unrelated later edits. Cleanup requires
approval and refuses changed evidence.

`--dry-run` performs bounded read-only planning and creates no locks, plans,
ledgers, staging, or backups. Parent source limits are 8 MiB per document,
parse depth 64, 100,000 nodes, 16 files and 32 MiB aggregate per plan; request
and management limits remain independently binding.

## Analyze

```text
dart analyze
```

## Check formatting

```text
dart format --output=none --set-exit-if-changed lib bin test
```

## Test

```text
dart test
```

Build and execute the sanitized production-artifact release gate with:

```text
dart compile exe bin/agent_resource.dart -o build/agent_resource.exe
dart run test/support/release_gate.dart build/agent_resource.exe build/release-evidence.json
```

Use `build/agent_resource` without `.exe` on macOS/Linux. CI runs this gate on
all three native operating systems and uploads only the sanitized evidence
JSON. `docs/release-qualification.md` contains the behavior/evidence index,
current blockers, and explicit readiness decision; green tests alone do not
qualify a release.

The process-boundary tests run the executable with isolated temporary working,
home, and configuration directories, initializing all of those environment
directories before taking full snapshots. They compare entries, types, and
bytes rather than access timestamps; read-only behavior does not claim that
SDK/file-system reads cause no physical access-time updates. They do not
require network access after dependencies have been resolved.
