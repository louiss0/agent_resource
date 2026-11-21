# Agent Resource

Agent Resource is a Mamba command-line application for managing resources
consumed by AI coding harnesses. The current scope provides application help
and version reporting, management-aware Skill and Agent inventories, native
inspection/validation, bounded dependency/capability graphs, native Agent
create/clone/edit/compose workflows, all-six conversion, canonical, copied,
and source-linked Skill installation, native Agent copies and adoption,
source-aware mixed Skill/Agent pack installation, reviewable updates,
snapshots and rollback, retained backups, explicit restore/cleanup, and
evidence-backed transaction recovery. Claude, Codex, and the common Pi
profile remain distinct native contracts.

## Requirements

- Dart SDK 3.13.2 or newer

## Install a published release

On macOS with Homebrew:

```text
brew tap louiss0/the-code-fixer-23
brew install --cask agent-resource
```

On Windows, after the release's WinGet pull request has been merged:

```text
winget install --id louiss0.AgentResource --exact
```

Release archives and checksums are also attached to GitHub releases. See
`docs/releasing.md` for supported targets and the release process.

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
singular `skill` and `agent` groups for native resource operations, `pack` for
source-aware lifecycle operations, `prompt` and `authoring` for Prompt and
draft surfaces, and `config` for validation, effective settings, and
preferences. Each singular group
provides `list`, `inspect`, `validate`, `install`, `adopt`, `replace`, `remove`,
`backup`, and `recover` paths. There are no root-level aliases, and
`skill discover` is not retained as a second inventory verb. Unsupported commands
and options fail with a nonzero exit status.

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

Skill and Agent inventory scope defaults to project. Use `--cwd`,
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
asks for approval before writes. Skill and Agent scope default to `project`; the Skill method defaults to
`canonical`. These defaults are not assumed
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
A present `agent-resources.toml` stays authoritative. Skill installation preflight
requires each selected package root to contain only a regular `SKILL.md` and
optional `references/`, `scripts/`, and `assets/` directories; other entries
are rejected, not omitted. For example, Codex's `agents/openai.yaml` sidecar is
not accepted for new installations. Recursive safety checks still apply inside permitted
directories. A directly selected `SKILL.md` is a single-file source: its siblings
are not acquired or inspected. Public GitHub availability does not override
this layout: Vercel's `skills/composition-patterns`, for example, is rejected
because it also contains `AGENTS.md`, `README.md`, `metadata.json`, and
`rules/`. Repackage or explicitly convert it before installing; there is no
automatic conversion or `skills-lock.json` import. Agents remain
catalog/exact-file only. No automatic dependency installation occurs.

```text
dart run bin/agent_resource.dart skill install mattpocock/skills
dart run bin/agent_resource.dart skill install https://github.com/mattpocock/skills/
dart run bin/agent_resource.dart skill install mattpocock/skills --scope user --target codex --method canonical --all-resources --dry-run
```

Git acquisition uses the requested final URL and refuses HTTP redirects.
Supply the final HTTPS repository URL instead of relying on a redirect; no
HTTPS-to-HTTP downgrade is followed.

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

### Inspect and save preferences

`config effective` is read-only. It reports the resolved safe preferences, the
user and project configuration paths, and each value's origin: explicit
argument, project config, user config, pack config, detection, or built-in
default. Use `--format text|json` for human-readable or scripted inspection.
Explicit `--target`, `--method`, and `--snapshot-days` values are shown as
explicit argument origins without changing configuration. `--pack <key>`
reports pack-level install overrides as `pack-config` origins. A user path
discovered from `XDG_CONFIG_HOME` reports that variable as its source.

`config prefer` previews eligible changes by default. Add `--apply` to write
only the reviewed safe preferences to the selected `--scope project|user`
configuration. The eligible keys are `cli.install.targets`,
`cli.install.skill_method`, and `cli.retention.snapshot_days`. Remembered
targets may be `claude`, `codex`, `shared`, or `pi`: Skill-backed pack
installations support the first three, while MCP also supports `pi`. Agent
installations derive their target from the Agent's native profile. A target
accepted here is not necessarily supported by every resource type. Applies use
focused table edits that preserve comments, indentation, and unrelated TOML
sections; ambiguous inline or dotted layouts are refused. Publication uses
lifecycle coordination, a private same-filesystem staging directory, backup
and quarantine evidence, and rename. Stale sources, symlink parents or
targets, creation races, and unsupported publication conditions refuse; an
interruption may require evidence-backed recovery inspection. No crash,
power-loss, hostile-writer, or universal metadata guarantee is claimed.
Approvals, adoption authority, destructive consent,
risk acknowledgements, credentials, and credential-like values are refused
without being echoed or remembered.

If publication is interrupted, inspect its evidence by selecting the exact
configuration target with either lifecycle command. Supply the same `--cwd`
and `--project-root` that were used for the original publication when
inspecting older project-scoped evidence:

```text
agent_resource skill recover --configuration-target <path> --scope all
agent_resource agent recover <transaction-id> --configuration-target <path> --action rollback --dry-run
agent_resource agent recover <transaction-id> --configuration-target <path> --action rollback --yes
agent_resource agent recover <transaction-id> --configuration-target <path> --action complete --yes
```

Recovery validates the target and retained evidence before making a change.
It refuses changed targets, unverified quarantine or staging bytes, and other
ambiguous states rather than overwriting or removing them. New evidence and
coordination are anchored to the target so cooperating configuration writers
using different projects or user state roots share a reservation and lock.
Windows target case aliases share the same reservation; arbitrary filesystem
aliases and hostile concurrent writers are not supported.

Older project-scoped evidence cannot be discovered from a different project:
there is no global inventory of old projects. Before retrying a shared user
configuration that might have an older interrupted publication, run recovery
from the original project. Older transactions also did not record their staging
directory, so recovery cannot identify or remove those old staging artifacts.
Incomplete or altered new staging evidence is retained for manual inspection.
Lifecycle mutations with unrelated coordination roots are not guaranteed to
acquire the configuration target lock; stop other writers while recovering.
There is no machine-wide or cross-account lifecycle lock. Coordinate writers
externally when they can affect the same resources across unrelated roots.

```text
agent_resource config effective [--scope project|user] [--pack <key>] [--format text|json]
agent_resource config prefer --scope project --set cli.install.targets=claude,codex
agent_resource config prefer --scope user --set cli.retention.snapshot_days=30 --apply
```

### Manage source-aware packs

Declare consumer packs in a project-level or user-level
`agent-resources.toml`. A pack records its Resource origin and accepted update
track separately from machine-local installation evidence:

```toml
schema_version = 1

[cli.install]
targets = ["codex"]
skill_method = "copy"

[packs."owner/repository".source]
kind = "github"
repository = "owner/repository"

[packs."owner/repository".update]
track = { kind = "branch", name = "main" }
```

Local sources use `kind = "local"` and `path = "../pack"` with a
`track = { kind = "local" }`. Git sources can follow a branch or pin an exact
tag or commit. GitHub release tracks support exact releases and explicit
SemVer bump policies; ordinary install never advances an existing exact lock.

```text
agent_resource config validate [--resolve]
agent_resource config effective [--scope project|user] [--pack <key>] [--format text|json]
agent_resource config prefer --scope project|user --set <key>=<value> [--apply]
agent_resource prompt inspect --path <path> [--target claude|codex|pi]
agent_resource prompt validate --path <path> [--target claude|codex|pi]
agent_resource prompt list [--scope project|user|all] [--target claude|codex|pi]
agent_resource pack validate <pack> [--type skill|agent|prompt] [--only <name> ...]
agent_resource pack discover <pack> [--type skill|agent|prompt] [--target claude|codex|pi]
agent_resource pack install <pack> [--type skill|agent|prompt] [--only <name> ...]
agent_resource pack update <pack> [--type skill|agent] [--only <name> ...]
agent_resource pack remove <pack> --only <name> [--only <name> ...]
agent_resource pack source associate <pack> --only <name> [--only <name> ...]
agent_resource pack source change <pack> --to <configured-pack>
agent_resource pack rollback <pack> --only <name> --snapshot <recorded-ref>
agent_resource pack cleanup <pack> [--only <name> ...]
```

Canonical pack operations default to both resource types. Repeat `--type` to
select more than one explicitly, or select one type to disambiguate a native
name shared by a Skill and an Agent. `--only` uses native names, not catalog
IDs, source paths, or installation IDs. Unknown names and cross-type ambiguous
selections are rejected before publication. Newly discovered update resources
remain unselected unless explicitly included or selected by name.

`--type prompt` applies to `pack install` and to `pack validate`. It installs
valid, supported skill-backed Prompts through the native Skill installation,
and it keeps the Skill ownership record, the update, removal and rollback
selectors of the installed resource. Every selected resource must be a valid
Prompt for every requested target; a mixed selection, a Pi target or a
standalone template refuses the whole selection before any installation
effect. The other pack operations keep the Skill and Agent selectors.

`pack discover` reports the candidates of a configured pack and their
per-consumer Prompt views. It is a read-only view: it writes no management
state, enrolls no membership and advances no inventory. A declared catalog is
authoritative, and the discovery of the `skills`, `agents` and `prompts` roots
is bounded to the direct entries plus one group level.

`prompt inspect`, `prompt validate` and `prompt list` are the public read-only
Prompt paths. They report the harness-relative views of an explicit native
source or of the native Prompt surfaces: a manual-only Skill is a Prompt for
one consumer and an ordinary Skill for another one. With `--target` the report
states the kind and the validity of that consumer; without it the report shows
the differing views and never one universal classification. The paths never
disclose an instruction body, never write a management artifact and never
install a resource.

Mutations require an interactive review or explicit unattended context:
`--scope project|user`, all required choices, and `--yes`. `--dry-run` performs
inert acquisition and review without publishing managed state. `--yes` does
not infer resource selection, local-edit decisions, extra-folder admission, or
changed same-release attachment consent. Use `--keep-local` or
`--replace-local` for whole-resource edit decisions and
`--approve-removal <name>` for reviewed upstream removals.

Skill roots admit `SKILL.md`, `references/`, `scripts/`, `assets/`, and
`agents/`. Additional root folders require bounded approval through review or
`--allow-folder <skill-name>:<root-folder>`; unexpected loose root files reject
the complete Skill rather than installing a filtered subset. Agents retain
their native-copy behavior and profiles.

Machine-local state is recorded in `.agent-resource/installations.json` or the
selected user state directory. It contains source evidence, complete
installation baselines, selections, approvals, operation evidence, and stable
Recorded snapshot refs. Rollback restores one resource from a recorded
snapshot. Source-link management owns only the link, never the user-owned
target. Ordinary noncurrent snapshots are eligible for retention cleanup after
90 days; locally edited backups require explicit reviewed cleanup.

Text output is deterministic by default. `--format json` emits one versioned
success envelope; failures and partial failures emit no success JSON and use
stderr with a nonzero status. Resource kinds are selected on `pack` with
`--type skill|agent|prompt`; there are no plural compatibility groups.

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

### Inspect and recover coordinated native transactions

```text
agent_resource prompt conversion list [--scope project|user|all]
agent_resource prompt conversion inspect <transaction-id> --scope project
agent_resource prompt conversion recover <transaction-id> --scope project
agent_resource prompt conversion recover <transaction-id> --scope project --apply --yes --plan-id <reviewed-plan-id>
agent_resource prompt conversion cleanup <transaction-id> --scope project
agent_resource prompt conversion cleanup <transaction-id> --scope project --apply --yes --plan-id <cleanup-plan-id>
```

These commands use retained coordinator evidence, not editor drafts or ordinary
managed-only backups. Supply the original `--project-root`, `--home`, and
`--state-dir` when recovering an operation created with explicit context paths.
Inspection and default recover/cleanup invocations are read-only. Apply requires
a current plan ID and explicit approval; changing evidence, participants, native
contents or ledger observations invalidates that review. The protected commit
decision fixes the recovery direction: rollback before commit, completion after
commit. No caller-selected override, force, rebaseline, or completed-conversion
inverse restore is provided. New public authoring/conversion apply paths remain
gated separately.

Same-location, same-native-form Agent and copied Skill edits can also be reviewed
through `agent recover <cvx-id>` or `skill recover <cvx-id>`. Apply adds the
reviewed `--action rollback|complete --yes --plan-id <reviewed-plan-id>`; the
action must agree with the coordinator decision. Receipt-only edits do not adopt
the original or create an installation record. Existing ordinary `trx_` recovery
continues to use its existing contract.

### Inspect and recover ordinary authoring publications

```text
agent_resource authoring list [--scope project|user|all]
agent_resource authoring inspect <transaction-id> --scope project
agent_resource authoring recover <transaction-id> --scope project
agent_resource authoring recover <transaction-id> --scope project --apply --yes --plan-id <reviewed-plan-id>
agent_resource authoring cleanup <transaction-id> --scope project
agent_resource authoring cleanup <transaction-id> --scope project --apply --yes --plan-id <cleanup-plan-id>
```

These commands use the retained authoring transaction of an ordinary, unmanaged
publication. The transaction binds the reviewed plan, the published target, the
reviewed source and the retained recovery payload. Inspection and the default
recover/cleanup invocations are read-only; apply requires the current review
identity and explicit approval. A publication before its commit may be rolled
back, which removes the published target and restores the reviewed source from
the retained payload; a committed publication may only be completed. Cleanup
deletes only the verified terminal private payload, keeps the evidence document
as the audit record, and forfeits the payload based restore. An unfinished
transaction is never cleaned up, and no recovery path deletes an editing draft
or a user input file. The public authoring create, edit and conversion routes
remain gated separately.

Cleanup accepts only intact terminal evidence, refuses pending conflicts, and
deletes only verified private recovery payloads. It retains the coordinator
receipt, decision and participant references for audit and replay refusal. The
review explicitly discloses loss of payload-based restore; user instruction
files and editor drafts are never cleanup candidates. Interrupted cleanup is
reported as pending until another fresh review concludes it. Missing, corrupt
or context-mismatched authority remains unresolved, never implicitly abandoned
or expired. This is local filesystem recovery, not native harness verification
or a guarantee of power-loss durability or secure erasure.

### Mutating while a coordinated transaction is pending

A pending conversion reserves its participants. The reservation is persisted
evidence, not the file that currently occupies a path: replacing, deleting, or
recreating that file does not release it, and an empty path does not prove it
is free.

While such a transaction is pending, the ordinary Skill, Agent, pack, and
parent-unit mutations refuse the paths, identities, names, and pack membership
that the transaction reserved, in both the project and the user scope. The
refusal names the blocking transaction and exits with status 6. Unknown,
corrupt, or unavailable conversion authority is refused as unavailable
authority rather than treated as an unmanaged or free path; the same holds for
a reservation whose coordinator evidence is missing.

An unrelated name, an unrelated root, and an unrelated project are not
blocked. A transaction that reached a terminal phase releases its reservation
through the reviewed recovery interface.

### Find and resume retained instruction drafts

```text
agent_resource authoring draft list [--scope project|user] [--format json]
agent_resource authoring draft inspect <draft-id>
agent_resource authoring draft resume <draft-id>
agent_resource authoring draft discard <draft-id> --dry-run
agent_resource authoring draft discard <draft-id> --apply --yes
```

Drafts are protected editing storage, not published resources or native
transaction recovery payloads. These commands default to project scope and
accept `--cwd`, `--project-root`, `--home`, and `--state-dir`. List/inspect and
resume are read-only and never print instructions. Resume builds a fresh plan
against current source, destination, and ownership observations; it does not
publish or reuse an old approval. A ready plan still needs separate publication
consent in a supported authoring frontend.

Discard previews by default. Explicit `--apply --yes` deletes only verified,
application-owned draft entries; it never removes the original body file.
Drafts have no automatic expiry. Unresolved or unsafe evidence is retained,
not guessed away. Privacy is verified before sensitive writes, and read-only
operations do not repair permissions. Arbitrary editor backups, history, and
cloud copies remain outside the storage confidentiality guarantee.

The shared module preserves file/explicit-stdin/literal multiline body inputs;
interactive draft preparation and editor launching are distinct from dry-run.
No new public create/edit/apply workflow is enabled by this slice. Details and
verification limits: [protected instruction drafts](docs/specs/protected-instruction-drafts.md).

### Inspect and validate one Skill directory

```text
dart run bin/agent_resource.dart skill inspect --skill <directory> [--target claude|codex|pi]
dart run bin/agent_resource.dart skill inspect --skill <directory> --content
dart run bin/agent_resource.dart skill validate --skill <directory> [--target claude|codex|pi]
```

Skill inspection is **body-free by default**. It reports the native form,
global compatibility, unknown placement, and the separate consuming-Harness
views. A selected target narrows the reported views. Without a target there is
no universal classification or validity: the same source can be a Claude
Prompt and an ordinary Codex Skill.

Skill validation applies the native view's validity rules. Prompt-only
resource-free/path restrictions do not invalidate an ordinary Skill view for
another Harness. Unknown or invalid selected views fail with status 2;
without a target, all reported views must pass. Completed native reports are
JSON, on stdout for success or stderr for invalid validation. Operational
inspection failures stop before returning partial JSON. No body, management
record, adoption, or activation claim is included.

**Compatibility change:** scripts that previously consumed `skill inspect`'s
`content` field must now pass `--content`. This explicitly selects the legacy
immediate-marker contract, not native validation. It cannot be combined with
`--target`. Relative paths are normalized absolute lexical paths; legacy
content inspection may use a selected directory link, but never reads a linked
`SKILL.md`. Missing/nonregular markers return `hasSkillFile: false` and
`content: null`; regular markers return exact strict-UTF-8 text, including line
endings and whitespace, up to 1,048,576 bytes. The body-free native path refuses
linked source ancestors rather than inspecting their targets.

The bounded core Skill validation profile remains available to the library and
existing installation machinery; it is not the new per-Harness CLI report.
See [the inspection surface specification](docs/specs/prompt-inspection-surface.md)
for scope, failure, Pi recognition, and verification limits.

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

### Create native Skills, Agents, and Prompts from plain text

```text
dart run bin/agent_resource.dart skill create --profile claude|codex|pi --name <name> --description <text> --body-file <file>|--body-stdin|--body-text <text>
dart run bin/agent_resource.dart prompt create --profile claude|codex|pi|global --name <name> --description <text> --body-file <file>|--body-stdin|--body-text <text>
dart run bin/agent_resource.dart agent create --profile claude|codex|pi --name <name> --description <text> --body-file <file>|--body-stdin|--body-text <text>
```

Creation takes named native selections and plain text; there is no JSON
operation request. The native profile is always explicit. The instruction
body comes from exactly one of `--body-file`, `--body-stdin` and `--body-text`.

On a usable terminal the guided flow is the default: it collects the missing
required native fields and opens the configured editor for the body when no
body was supplied. A usable terminal means that the input and the output
streams are both a terminal; a redirected output is not one, and the guided
flow then never prompts. `--unattended` and `--format json` never prompt and
never wait, so an unattended call must supply every value explicitly.
`--editor` selects an editor executable with its arguments; it is never a
shell expression.

`--body-stdin` reads the piped standard input of the invocation. An
interactive terminal is never read and an invocation without a piped
standard input is refused instead of waiting.

The reviewed proposal names its target, its ownership and its declared native
values before the publication is confirmed in the same flow. `--apply --yes`
publishes without a question, `--dry-run` plans without an editor, without a
draft and without a write, and `--plan-id` binds the publication to one
reviewed plan identity. A new output is author-only: no installation record
is created unless `--manage` selects a supported managed form, and a Prompt
has no managed lifecycle at all.

A successful publication removes the retained application-owned draft and
never removes the original body file. Every outcome that retains a draft
names it, so a cancelled or refused run can be resumed. A cleanup failure is
reported next to the published output instead of hiding it. The contract is
in `docs/specs/guided-text-creation.md`.

### Create, clone, edit, compose, and convert native Agents

```text
agent_resource agent create --profile claude|codex|pi --name <name> --description <text> --body-file <file>|--body-stdin|--body-text <text>
agent_resource agent create --role-key <key> --config-file <config.toml> --ownership definition|both --definition-source <definition.toml> [--definition-output <path>] --ack-clients-stopped
agent_resource agent clone <request.json>
agent_resource agent edit <request.json>
agent_resource agent compose <request.json>
agent_resource agent convert <request.json>
```

`agent create` takes named native selections and plain text. The native
profile is always explicit; it is never inferred from a file name. The
instruction body comes from exactly one of `--body-file`, `--body-stdin` and
`--body-text`. On a usable terminal the guided flow collects the missing
native fields and opens the configured editor for the body when no body was
supplied; `--unattended` and `--format json` never prompt. The reviewed
proposal names its target, its ownership and its changes before the
publication is confirmed; `--apply --yes` publishes without a question, and
`--dry-run` plans without an editor, without a draft and without a write. A
new output is author-only unless `--manage` selects a supported managed form.

The retired JSON operation request is refused with migration guidance: the
positional request file and `--request` never reach a body or a proposal.
The Codex bound-role route publishes the reviewed native Codex definition of
`--definition-source` and registers the role in the declaring config only
when `--ownership both` selects it; a registration requires
`--ack-clients-stopped` and its own approval. A standalone creation never
changes a declaring config.

The remaining authoring and conversion routes still use bounded, versioned
JSON with explicit native source/target/context data. Planning is read-only
by default and creates no management artifacts. Apply requires `--apply`, the
current `--plan-id`, and `--yes`, or explicit interactive review. Ordered
instruction parts, base conflicts, unknown fields, model/tool/effort
mappings, reference changes, and deliberate omissions are reported before
publication. Default reports omit instruction bodies; `--show-instructions` is
an explicit privacy choice.

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
agent_resource agent create --profile claude|codex|pi --name <name> --description <text> --body-file <file>|--body-stdin|--body-text <text>
agent_resource agent create --role-key <key> --config-file <config.toml> --ownership definition|both --definition-source <definition.toml> --ack-clients-stopped
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
