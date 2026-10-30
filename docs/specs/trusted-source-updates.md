# Trusted source updates: design and decision record

**Status:** consolidated handoff DRAFT awaiting final review. Explicitly user-selected policy is labeled AGREED; concrete technical conventions below are proposed for final review, not additional user policy decisions. Nothing here claims that the current CLI implements this design or that tests were executed. "Trusted" describes reviewed, evidence-based management, not publisher authentication, execution trust, or a sandbox.

## Destination, boundaries and provenance

Enable reproducible, reviewed lifecycle management of native Skills and Agents from typed sources, with safe local ownership, explicit admission and recoverable per-resource changes. Share desired configuration, not a promise of identical installations. Non-goals: runtime harness activation/enforcement, executing acquired code, cross-harness Agent conversion, a portable lockfile, implicit reconciliation, automatic merge, legacy migration, and a new pack command group.

**Decision provenance:** canonical [tracker #44](https://github.com/louiss0/agent_resource/issues/44); [identity and snapshots #45](https://github.com/louiss0/agent_resource/issues/45); [local evidence and consent lifetime #46](https://github.com/louiss0/agent_resource/issues/46); [Skill admission #47](https://github.com/louiss0/agent_resource/issues/47); [GitHub evidence research #48](https://github.com/louiss0/agent_resource/issues/48) and its [report](https://github.com/louiss0/agent_resource/blob/37937a42c081652284de45d678af8abdbbaee7e1/docs/research/github-source-update-evidence.md); [source eligibility #49](https://github.com/louiss0/agent_resource/issues/49); [membership #50](https://github.com/louiss0/agent_resource/issues/50); [safe application, local edits and links #51](https://github.com/louiss0/agent_resource/issues/51); [CLI #52](https://github.com/louiss0/agent_resource/issues/52); [configuration #54](https://github.com/louiss0/agent_resource/issues/54); [retention #55](https://github.com/louiss0/agent_resource/issues/55). Later comments supersede earlier sketches, particularly path selectors, automatic new-Skill inclusion, separate portable lock, method defaults and attachment bypass flags. Terminology follows the repository glossary: origin, managed installation, baseline, exposure, recovery backup and mutation plan are distinct.

## Configuration and authority [C]

**AGREED:** `agent-resources.toml` is the single user-edited artifact for consumer packs, CLI preferences and publisher catalog; `installations.json` is a generated **machine-local** lock, including in project scope. Operational journals and retained bytes are separate. No `manifest` wrapper, separate catalog or second lock; no `cli.output` and no persistent auto-confirm. Reading or editing config does not mutate installations; removing a declaration does not authorize uninstall, nor does changing a default relocate an installation.

The selected project root has one `<project>/agent-resources.toml`, without ancestor layering. User config lives in the platform application-config directory, e.g. `%APPDATA%/AgentResource/agent-resources.toml`; explicit config-path selection is supported. Consumer local paths are relative to the config's directory; catalog paths remain inside the source package. Project CLI preferences inherit user defaults, then project overrides; pack settings override general defaults, invocation options override these transiently. User-scope commands do not inherit project settings; scope-specific desired packs do not implicitly install across scopes. Downloaded configuration supplies **catalog only**; its consumer packs/preferences do not grant consent or configure the consumer. Successful managed additions normally save selection and persistent choices in the selected scope, with explicit no-save; failures/cancellation never become successful records.

**Accepted structural baseline**, with illustrative names; the obsolete selector `path` in the original example is deliberately removed by the later names-only decision:

```toml
schema_version = 1
[cli.install]
targets = ["codex"]
[cli.retention]
snapshot_days = 90
[packs."mattpocock/skills".source]
kind = "github"
repository = "mattpocock/skills"
[packs."mattpocock/skills".install]
targets = ["codex", "claude"]
[packs."mattpocock/skills".update]
track = { kind = "branch", name = "main" }
[packs."mattpocock/skills".resources.skills]
exclude = [{ name = "unwanted-skill" }]
[[packs."mattpocock/skills".resources.skills.overrides]]
name = "example-skill"
extra_folders = ["rules"]
[[catalog.skills]]
path = "skills/my-skill"
[[catalog.agents]]
path = "agents/reviewer.md"
profile = "claude"
```

The same resource branches exist for `skills` and `agents`; overrides configure named resources, not a frozen allowlist. Catalog entries are source-relative acquisition paths, not selector IDs; obtain native names through validation. A folder request is not authorization. Quoted owner/repository is readable addressing, not authoritative source identity; source fields govern acquisition. Do not derive a repository by splitting a config key or attach an existing key silently to a different source. There is no implicit Skill installation method: use an explicit configured/pack/invocation choice, otherwise prompt, and fail unattended. Native Agents use their supported native-copy behavior, independently of Skill method.

**Engineering proposal, not additional accepted field spelling:** normalize config into source, track, target/scope, Skill method, typed native resource selections/exclusions and folder requests. Validate schema version, unknown fields, types, bounds, duplicate declarations, conflicts and ambiguity offline. After TOML syntax succeeds collect independent semantic errors with actionable key paths, avoiding cascades from invalid parents. No secrets in config, records, diagnostics or dumps. The concrete conventions below are proposed for final review.

| Normalized source | Proposed fields / track | Required behavior |
|---|---|---|
| GitHub repository | explicit host/provider, owner/repository and optional package boundary; branch `name`, tag `name`, commit full identity, or release selector/policy | Resolve and retain actual identities; never infer track from a generic ref. |
| Durable local | path relative to consumer config; explicit local observation mode | Reread same path; missing path fails, never guess substitute. Eligible for explicitly selected source-link. |
| Plain download | URL and optional package boundary; explicit download observation mode | Reacquire recorded URL and compare consumed content, not semantic version. No credentials retained. |
| GitHub Release | repository, exact release or SemVer policy, archive versus attachment selector | Record release/tag/commit and attachment separately; mode-specific fields must not conflict. |

Exact field names and identity normalization are proposed technical conventions, not a claim that these variants were accepted verbatim. A release attachment is not a Skill's `assets/` folder. GitHub branch/tag names are mutable; release entity, tag object, commit, attachment ID and consumed bytes establish different facts. The research does not establish universal asset digest availability or a complete GitHub latest algorithm. Compute consumed-byte evidence; archive compressed bytes and extracted content are distinct.

## Identity, lock and evidence [I]

**AGREED:** select an installation by source-qualified pack + native resource name and type + scope/destination, including selected project and target context. Disambiguate host; never choose silently. Different names are unrelated, without rename continuity or transfer of history, exclusions or approvals. Duplicate native names among eligible candidates in the same pack/type/target context reject that context, reporting conflicting source paths; paths are diagnostic, not selectors. Kebab-case resource names/entry basenames must also meet their native profiles; no underscore aliasing. Preserve native fixed names such as `SKILL.md`, extensions and safe support filenames, without recursively imposing kebab-case on support files.

**Proposed conceptual lock schema**, not final JSON spelling:

| Record | Minimum responsibility |
|---|---|
| Document/context | schema version, selected project/user context and accepted pack contexts; reject unsupported old schema without modifying its records/backups, directing users to a compatible prior CLI. No migration/reset program. |
| Pack | readable key plus verified source/provider identity and continuity evidence, scope/destination, accepted typed shared track/policy; distinguish it from edited desired config. |
| Installation | native type/name/profile, source acquisition path as evidence, method, owned boundaries, actual destination and exposures, live/removed status, current snapshot and recovery references. Readable selectors do not prove ownership. |
| Snapshot | stable ref and original successful-install time, source resolution and complete source-to-published inventory/baseline, activation history, noncurrent time, retention class and verified retained-content availability/reference. |
| Approval | verified source + pack/resource/type/scope/destination + particular root folder, evidence of local consent, retained independently of live state and snapshot bytes. |
| Operation/recovery | per-resource actual outcome, journal and verified backup references, recovery state and edited-content classification; operational bytes and journal are not reconstructed from hashes. |
| Selection | known, explicitly selection-declined, removed and installed membership in each pack/context; cancellation and `--skip-new` are not durable declines. |

Inventory records each relative entry, type, size and digest where applicable, relevant attributes and link evidence, mapping acquisition to publication. Record requested/resolved locators and package boundary; branch/tag object and commit; release ID/flags/tag/commit; attachment ID/name and consumed bytes digest as applicable. Distinguish original source, installed baseline and locally edited backup. Preserve actual outcomes, not attempted versions. Store no secrets. A digest/ref proves neither ownership nor byte availability; acquisition path alone proves neither continuity nor authority. Shared canonical Skill content and each managed exposure have explicit ownership; independent copies are separate installations. Link baseline and last-observed target evidence are separate.

Reinstallation may reuse folder approval only for the **same verified source**, pack, resource/type, scope/project, destination and folder. Names, reused locators or redirects do not establish continuity. New folders need approval; destination ownership, native validation and recursive safety are still checked. A source-address rename/transfer requires reviewed change; history may continue only with evidence, never because of a redirect. For supported adopted records with unknown source, require reviewed source association before source-aware updates.

## Acquisition, admission and eligibility [A]

Acquire as inert data in isolated temporary storage; do not execute source scripts or install dependencies. Bound all paths to the package, validate archive extraction and recursive entries, reject traversal, unsafe links and destination escapes; do not follow untrusted links into user data. Distinguish source/resource validity, local folder consent and readiness. `config validate` is offline/nonmutating; `config validate --resolve` may inspect inert temporary acquisition and clean it safely, but cannot publish, grant consent or save records.

A selected Skill requires a regular `SKILL.md`; `references/`, `scripts/`, `assets/`, `agents/` are admitted by default, subject to recursive checks. Other root directories require explicit local approval per installed Skill and folder, via interactive approval or repeatable `--allow-folder <skill-name>:<root-folder>`. Other loose root files, including README and license files, reject the whole Skill; folder approval cannot authorize them. Neither unapproved folders nor rejected root files may be silently filtered into a partial Skill. Approval is not execution permission or publisher trust. New files inside admitted folders remain subject to safety checks; a new extra root directory requires new approval. First-install rejection creates no installation; failed preflight update preserves live content.

Ordinary install uses an existing exact lock: verified retained content, otherwise exact reacquisition, otherwise failure without advancing. First install resolves the configured source. A changed source or track in TOML versus accepted lock rejects ordinary install for the affected pack until explicit reviewed change; branch movement under the same track is not a config mismatch. Update uses the accepted track:

* Branch: current resolved tip of the same branch; divergence, rewind or force-push alone is not an extra gate. A commit/tag pin stays at recorded evidence; a moved/deleted tag is not silently accepted.
* SemVer release: select highest eligible higher version, patch within major/minor, minor within major, major any higher; no automatic downgrade. Prereleases need separate `--include-prerelease` and still obey range. With no saved policy, require an interactive or explicit selection; a non-SemVer release requires exact selection. Apply the proposed deterministic SemVer conventions below.
* Same release/attachment with changed consumed bytes, including delete/reupload under the same name: warn and reject unless the exact reviewed candidate is accepted **interactively only**. No bypass flag or blanket preference; `--yes` disables prompts and cannot accept. Missing evidence is not proof of equality.
* Local and download behavior follows the source table; changed download bytes are a candidate, not proof of a newer version. Eligibility never bypasses ownership, admission, edit preservation or review.

## Lifecycle and selection [L]

**Agreed grammar and semantics**, where `<cli>` is the executable and scope/destination/config selectors must identify the context:

```text
<cli> config validate [--resolve]
<cli> skills install <pack> [--only <name> ...]
<cli> skills update <pack> [--only <name> ...] [--skip-new]
    [--bump patch|minor|major] [--include-prerelease] [--save-policy]
    [--keep-local <name> ...] [--replace-local <name> ...]
    [--allow-folder <skill-name>:<root-folder> ...] [--yes] [--dry-run] [--format json]
<cli> agents install <pack> [--only <name> ...]
<cli> agents update <pack> [corresponding selection, policy and local-edit options]
```

The plural groups, `update <pack>`, repeatable names-only `--only`, and named flags shown for updates are agreed; the install positional and option composition are a **proposed integration shape**, not settled exact command spelling. The explicit lifecycle grammar below is proposed for final review. No pack group, `--include-new`, path/alias selection or attachment acceptance flag. Recognized source-mode-inapplicable options warn and are ignored, not saved or interpreted as track changes; unknown options and malformed values remain errors. Policy changes are one-time unless applicable `--save-policy` succeeds. Do not assume an unattended routine `--yes` supplies a special choice.

`--only` selects the complete affected set; it never expands to unrelated resources. Reject all unknown names in preflight, reporting independent errors; a managed name absent upstream remains known and may have an explicit removal proposal. No empty/invalid selection widens to all. Explicit `--only` of an excluded name requests reviewed re-inclusion; save exclusion removal only after normal successful save, respecting no-save. Targeted update changes only named resources and cannot change shared track implicitly.

Type-wide update offers genuinely new Skills/Agents initially unselected; explicit select-all may be offered. Confirmed selection declines become context-scoped exclusions; cancellation/unanswered prompts do not. `--skip-new` skips for this invocation only, without making declines or recording them as offered. Unattended discovery without an explicit applicable choice fails preflight; `--yes` neither chooses nor skips. Known removed-but-available resources can reappear unless selection-excluded; removal does not create an exclusion. An installed resource absent upstream is proposed for explicit removal, never silently deleted. Pack context has one shared track; targeted updates or declines may leave different actual snapshots. Review any shared saved policy's future effect on both resource types.

## Review, edits, publication and recovery [P]

A mutation plan binds the request, exact candidate and source evidence, selection, context, target/ownership state, complete live baseline observations, consent and relevant config/shared-state observations. Review lists every changed path per resource with add/modify/remove counts, names and targets, source/version transitions, additions/replacements/removals, consent, config/policy, snapshot and cleanup effects, and blockers. Redact sensitive values; do not dump contents or unchanged inventory by default. `--dry-run` can acquire inert temporary data, but prompts for no consent and publishes no installation, config, lock, approval, history or cleanup state. Blocked plans are failures, not successful installations.

Automatically compare all owned entries against baseline before replacement, including added, removed and changed files. For edits, choose whole-resource keep or replace, never merge. Repeatable names-only `--keep-local`/`--replace-local` apply only within selected context, cannot overlap, and cannot expand selection. Missing unattended decisions fail preflight; `--yes` alone cannot overwrite edits. Keep leaves content and baseline/source evidence unchanged for this invocation, is reported as kept, and does not pin or exclude it. Replace requires a verified recovery backup of current edited bytes before publication; failure to preserve prevents overwrite. Record edited provenance separately from upstream. If observations change after review, fail the affected resource untouched; do not silently regenerate a plan, reprompt during application or reuse stale consent.

Preflight invalid invocation/config, unknown selectors and missing required consent stop before publication. Preapproval cancellation/EOF is non-success and publishes no installation/config/lock/cleanup changes, although inert temporary acquisition may have occurred. After application begins, operate independently per selected Skill/Agent installation: never expose a partially mixed tree; retain successful resources and accurate evidence when another fails. Continue remaining resources after recoverable isolated runtime failure, but stop when shared authoritative state, ownership or isolation cannot be established. Report attempted and not-attempted outcomes; overall failure if any requested resource failed. Verify restoration before claiming recovery; unresolved recovery takes precedence. A deliberately kept resource is not itself a failure. Save requested shared `--save-policy` only if the operation finishes without failures, and only applicable explicitly requested policy; partial success keeps prior policy and reports it unsaved. Config publication failure is itself reported without undoing unrelated successful resources; ordinary successful per-resource manifest saves remain distinct.

**Engineering protocol requirement:** the publication unit is a complete Skill or Agent resource root, not an individual baseline inventory entry. Stage and validate the complete resource on the destination filesystem where possible; reserve/serialize conflicting operations, recheck plan-bound candidate, live entry, ownership and shared state immediately before mutation; durably journal intent and verified backup before destructive steps; switch the complete resource root into place as one publication step where the platform supports it, then persist matching actual lock/snapshot state with crash-safe replace and ordering. A baseline may inventory many entries, but file-by-file replacement that exposes a mixed old/new resource tree is not an acceptable publication strategy. Where whole-resource switching is unavailable, fail before destructive publication rather than expose a mixed tree and rely on later recovery. Use explicit recovery states and idempotent replay/restore, verify published/restored bytes and links, preserve journals/backups until recovery completes. Cross-entry or exposure repair may require recovery; this is not described as impossible global filesystem atomicity. Do not claim filesystem-wide atomicity where unavailable. Crash at any boundary must leave either a verified state or an explicit recovery-required state, not an invented success. Concurrent/config edits and unsafe shared-state failures must not be overwritten; stop safely. Deterministic serialization and redaction are engineering requirements, not authority to overwrite user data.

## Snapshots and source links [S]

A recorded snapshot ref selects a version **within** an installation, not a live upstream ref. Store successful installation time as UTC RFC 3339 milliseconds (`2026-10-30T04:15:00.123Z`); ref example `20261030T041500.123Z~a1b2c3d4`, extending content-derived suffix to disambiguate. Milliseconds/clock order alone do not ensure uniqueness. Identical content does not create a duplicate rollback snapshot; reuse preserves original ref/time, with activation separately recorded. Show upstream ref/release and resolved commit separately.

Ordinary historical source snapshots default to configurable 90 days from becoming noncurrent, including removal; renewed current status is protected and next noncurrent transition starts a fresh clock. Only approved lifecycle/cleanup operations may show and perform eligible cleanup, never help/list/background work. Protect current and unfinished recovery evidence and shared bytes needed by protected or unexpired snapshots. Keep metadata and mark bytes unavailable after pruning; exact reacquisition may restore only verified exact content, never silently substitute newer content. Locally edited backups have a separate class: retain until **explicit reviewed cleanup**, showing the loss, not ordinary age pruning; they cannot be reconstructed from upstream. Space exhaustion fails safely, not by deleting protected or unexpired evidence.

Source-link is advanced and explicitly selected: only a durable user-owned local target qualifies, never remote/temporary workspaces. The managed installation owns the link entry, **never writes, deletes or prunes the target**. Validate/reobserve target and folder admission during relevant operations, recording last observation separately from owned link baseline; external edits can expose changed/invalid content between invocations, without continuous enforcement. Report that limitation and failed revalidation accurately; no silent overwrite, removal or quarantine. Observation refresh is not a content update; link rollback restores the link/pointer only, not historical target bytes. Exact owned-content replay does not promise immutable external target content. Distinguish this from harness exposure links to CLI-owned canonical content.

## Output and status [O]

Text is default; `--format json` is invocation-only and independent of prompting. Successful results only may emit JSON on stdout; with JSON selected, prompts/review/progress and diagnostics stay off stdout. Failure/cancellation emits human-readable stderr, no success JSON. `--yes` approves routine final review **and disables prompts**; it cannot grant new-resource selection, folder/removal consent, source/track changes, local-edit replacement or changed attachment acceptance. Preapproval EOF/cancellation differs from interruption after application begins.

Use one enhanced enum with explicit numeric codes at the process boundary, never `enum.index`: `success=0` (including valid no-op), `failure=1`, `invalidInput=2`, `cancelled=3`, `recoveryRequired=4`, `interrupted=130`. Recovery-required overrides interruption when recovery is unresolved; retain cause as diagnostic. Keep typed outcomes internally, accurately distinguish per-resource updated/kept/failed/not attempted and no-op, and never report incomplete work as success. Diagnostics include safe source/config location, key path, offending value redacted as needed, and corrective action; no routine stack traces or secrets. **Success JSON envelope (proposed convention):** one versioned object on stdout containing `schemaVersion`, `operation`, `outcome`, `context` (selected scope and project/root, target and destination, config path), `source` (pack readability fields plus resolved evidence where applicable), per-resource `resources` entries with native type/name, disposition (`updated`, `installed`, `keptLocal`, `unchanged`, `removed`, `rolledBack`, `observed`, `notAttempted`), previous and resulting snapshot refs, warnings, and a summary of counts. Validation success includes the validation scope and any resolved/source-checked flag plus warnings; a ready dry-run uses an `outcome` that marks it as a preview with no publication, and no-op results use an explicit no-op outcome rather than a fabricated update. Source-link observation/restoration is identified as link-only in its resource entry. Warnings are structured entries with stable identifiers and safe text. Aggregate failure, including partial success, emits no result JSON and returns an enum-backed nonzero status with human-readable stderr diagnostics. Exact field nesting may evolve only within these observable semantics.

## Narrow integration touchpoints

Future work should inspect and adapt the existing `lib/src/installation/resource_catalog.dart` publisher catalog, `lib/src/services/acquisition_service.dart`, `lifecycle_state_service.dart` and Skill/Agent lifecycle and installation services to these contracts; connect current command groups and `installation_command_support.dart` to the agreed interface and Mamba process boundary. Existing native Skill validation, Agent profiles and installation planning are relevant seams, not evidence that this design already exists. Avoid speculative framework layers or changing unrelated Agent authoring behavior.

## Acceptance matrix (requirements, not executed tests)

| Scenario | Expected evidence / result |
|---|---|
| [C,I] Project/user inheritance, catalog in downloaded config | Correct scope and precedence; source preferences/requests confer no consent; no output config. |
| [C,I] Invalid TOML, multiple semantic errors, duplicate names | Syntax failure or collected actionable independent errors; ambiguity paths shown, no publication. |
| [A,L] First install / locked replay | Validated candidate and reviewed publication; retained exact bytes or exact reacquisition; unavailable/mismatched lock fails without newer fallback. |
| [A] Extra root folder / loose root file | Explicit folder consent bound to resource; loose file or unapproved folder rejects entire Skill, preserving live state. Same verified-context reinstall reuses only matching folder approval. |
| [A,L] Branch rewind, moved tag, release and changed attachment | Branch tip eligible without ancestry gate; pins stay pinned; range/prerelease rules apply; changed same-release attachment needs candidate-bound interactive acceptance and fails with `--yes`. |
| [L] New, excluded, removed, unknown names | New unselected; skip transient; explicit declines persistent; explicit re-inclusion reviewed; unknown selector preflight fails; upstream absence proposes removal. |
| [L,O] Mode-inapplicable option, malformed flag, missing unattended choice | Recognized inapplicable warns/ignored; malformed or unknown rejects; missing special choice fails, no mutation or success JSON. |
| [P] Edited tree, keep or replace | All changes detected; keep does not advance baseline; replace only after verified edited backup; contradictory choices rejected. |
| [P] Stale candidate/live/config or preapproval cancellation | No stale consent reuse; affected resource untouched; cancellation before approval publishes nothing, including cleanup. |
| [P] Multiple resources, one runtime failure | Independent successes recorded, safe remaining attempts continue; overall non-success, shared policy not saved; unsafe shared-state failure stops further work. |
| [P,S] Crash/write failure, recovery or disk exhaustion | Verified per-resource restore or recovery-required with preserved journal/evidence; no unverified clean-rollback claim or emergency pruning. |
| [S] Snapshot current/noncurrent, cleanup, pruned replay | Correct clock/protection and stable ref; reviewed eligible cleanup only; local-edit backups require explicit cleanup; unavailable bytes never implied available. |
| [S] Source-link target edited/invalid or rollback | Last observation reported as historical, target never mutated; link-only restore never claims historical target restoration. |
| [O] JSON, dry-run, cancellation and interrupts | Success-only parseable stdout; failures on stderr with enum status; dry-run has no consent/published effects; unresolved recovery overrides interruption. |


## Proposed technical conventions for final review

The following make delegated engineering choices concrete; they do not change the agreed policy above.

### Configuration discovery and normalized schema

On Windows use `%APPDATA%/AgentResource/agent-resources.toml` (RoamingAppData, not LOCALAPPDATA operational state); on macOS use `~/Library/Application Support/AgentResource/agent-resources.toml`; on Linux use `$XDG_CONFIG_HOME/agent-resource/agent-resources.toml` only if XDG_CONFIG_HOME is absolute, otherwise `~/.config/agent-resource/agent-resources.toml`. `--config <path>` selects the config for the explicitly selected scope, resolved against the invocation working directory; local paths inside it resolve against that file's directory. It does not change scope, project root, lock location or user-preference inheritance. Project config owns project pack declarations and project preferences; user config owns user packs and inherited user CLI preferences. The selected scope's file receives successful saves. An absent inherited user file means no defaults. An absent selected file has no declarations/defaults: validation reports the missing file; operations needing declarations fail with an actionable diagnostic, while an explicit successful managed addition may create the selected file only at approved save time. Never create one during inspection, dry-run or cancellation. Invalid existing files are not silently replaced.

`snapshot_days` is an integer in 1..36500 inclusive, default 90; check arithmetic before converting to timestamps. It governs only ordinary historical snapshots; locally edited backups are never age-pruned. Proposed config fields: `cli.install.targets`, `cli.install.skill_method`, `cli.retention.snapshot_days`; per-pack `install.targets`, `install.skill_method`, `source`, `update.track`, optional `update.bump` and `update.include_prerelease`, and `resources.skills` / `resources.agents` with `exclude = [{name = ...}]` and `overrides` entries keyed by `name`; Skill overrides can contain `extra_folders`. Scope is selected by command context, not inferred from a config path. Methods are explicit `canonical`, `copy`, or `source-link`; names represent existing agreed method categories, not defaults. Catalog entries remain `[[catalog.skills]] path` and `[[catalog.agents]] path, profile`. Reject unknown fields, duplicate names within each selector list and incompatible mode fields.

Proposed source/track discriminated shapes (all fields not listed for a mode are rejected):

| `source.kind` | Source fields | Permitted `update.track` |
|---|---|---|
| `github` | `host` (default `github.com`), `repository` as `owner/repo`, optional source-relative `subpath` | `{kind="branch", name=...}`, `{kind="tag", name=...}`, `{kind="commit", commit=...}`, or `{kind="release", artifact="archive"}` / `{kind="release", artifact="attachment", attachment=...}` |
| `git` | `url`, optional source-relative `subpath` | branch, tag or exact commit as above; no GitHub release mode |
| `local` | `path`, optional source-relative `subpath` | `{kind="local"}` |
| `download` | `url`, optional source-relative `subpath` | `{kind="download"}` |

Local and download modes can omit track only if normalized unambiguously to their matching explicit mode; no Git ref inference. Reject credentials embedded in locators rather than store them; credential access is external and must not leak into evidence. Pack keys for default-host GitHub use `owner/repo`; nondefault GitHub hosts use `host/owner/repo`. The source host and repository must match the normalized key. Other kinds use an explicitly declared readable pack key and authoritative source fields, without pretending the key proves identity. Normalize GitHub host and repository comparisons case-insensitively while preserving displayed spelling; reject duplicate normalized keys and duplicate source aliases in one scope/context. Do not merge ambiguous aliases silently. Exact Git URL normalization must not equate different providers or paths merely by spelling; reject identity ambiguity.

Record GitHub host plus repository numeric ID when obtainable and verified from the provider as continuity evidence, alongside locator and resolved content. An explicitly reviewed rename/transfer with matching verified provider identity can preserve continuity, subject to all resource/context checks. Where generic Git, local or download source identity cannot be adequately proved, do not infer continuity from locator, content digest or matching name: require fresh folder approvals. A newly observed GitHub name/redirect without verified identity also requires fresh approval; a source change still requires review. Duplicate validation and identity evidence do not establish destination ownership.

### Release selection convention

Release track describes tracking and artifact selection, not a fixed current release. The installed exact release, literal tag, release ID, resolved commit and consumed bytes belong to each resource's lock snapshot. Saved `bump` and `include_prerelease` are eligibility policy, not a fixed release pin; advancing an installed version under the same track is not a config/lock mismatch. With multiple resource snapshots, evaluate saved eligibility relative to each selected resource's current locked version; group identical candidates where possible without assuming lockstep. First install has no base: require explicit `--release <literal-tag>` or an interactive exact release choice; do not infer a range from nothing or silently choose latest. For an unparseable/non-SemVer current release, require `--release <literal-tag>` or an interactive exact choice on update; never infer bump from dates or names. Exact selection is one invocation, not a track switch, and does not bypass normal review, no-downgrade policy or attachment consent. Reject `--release` combined with `--bump` for the same invocation. `--release` on a non-release source is recognized, warned and ignored like other inapplicable source-mode options.

Use strict SemVer 2.0, allowing exactly one leading lowercase `v` stripped only for parsing/order while preserving the literal tag. Reject malformed versions for range selection. Build metadata does not affect precedence. Patch restricts major and minor to the installed version; minor restricts major; major allows any higher precedence, including 0.x without implying compatibility. Prereleases require `--include-prerelease` or saved opt-in when either the GitHub release prerelease boolean is true **or** the SemVer has a prerelease suffix; drafts are never automatic eligibility candidates. If a draft is explicitly selected by literal tag or release, it follows the same ordinary explicit-selection rules as any other exact choice; do not invent an additional interactive-only draft gate. Apply the same numeric range to prereleases and require strictly higher SemVer precedence. If different candidates tie at highest precedence, do not choose arbitrarily: require exact literal selection. Retain release flags and literal tag independently. Exact locked replay verifies consumed bytes and full extracted inventory against recorded evidence; link targets retain only the separate observation guarantees above.

### Explicit CLI grammar

The following spellings are proposed conventions; agreed flags retain their stated meanings.

**Context selection.** Mutating operations require `--scope project|user`. Interactively, a missing scope is prompted; in a noninteractive invocation (`--yes`, no terminal, or JSON automation) a missing scope is an invalid-input failure. Do not infer scope from the working directory, config-file existence, or managed-state location. `--project-root <path>` selects the project root for project scope; it does not itself select scope. `--config <path>` selects the config file for the already selected scope. `--target <name>` disambiguates the destination/target. A target may be inferred from recorded state only when the explicitly selected scope and pack/resource context yield exactly one match; otherwise prompt or fail before publication. All operations accept `--dry-run`, `--yes` and `--format text|json` where meaningful; `--no-save` suppresses desired-config saving, never actual lock evidence. The singular `<name>` in rollback is one native name, not an ID or path.

**Mode applicability precedes cross-option semantics.** A recognized option that does not apply to the current source mode is warned and ignored, and is excluded from conflict checks that concern only applicable effects. For example, on a branch installation both `--bump` and `--release` are inapplicable and are each warned and ignored rather than rejected as mutually exclusive; malformed values and unknown options remain parser errors. `--release` with `--bump` is rejected only when the release mode makes both applicable. Likewise `--no-save` and `--save-policy` conflict only when `--save-policy` has an applicable requested effect. `--only` with `--skip-new` is always invalid because it contradicts selection semantics regardless of source mode.

```text
<cli> skills install <pack> [--only <name> ...] [--method canonical|copy|source-link]
    [--release <literal-tag>] [--no-save]
<cli> agents install <pack> [--only <name> ...] [--release <literal-tag>] [--no-save]
<cli> skills|agents update <pack> [--only <name> ... | --skip-new]
    [--bump patch|minor|major | --release <literal-tag>]
    [--include-prerelease] [--save-policy] [--no-save]
    [--keep-local <name> ...] [--replace-local <name> ...]
    [--approve-removal <name> ...]
<cli> skills update <pack> [--allow-folder <skill-name>:<root-folder> ...]
<cli> skills|agents source associate <pack> --only <name> [--only <name> ...]
<cli> skills|agents source change <pack> --to <configured-pack-key>
<cli> skills|agents remove <pack> --only <name> [--only <name> ...]
<cli> skills|agents rollback <pack> --only <name> --snapshot <recorded-ref>
<cli> skills|agents cleanup <pack> [--only <name> ...] [--local-edits]
<cli> config validate [--resolve] [--config <path>]
```

**First install choices.** A Skill installation requires a method from `--method`, the applicable pack/config setting, or an interactive prompt; there is no implicit method, and an unattended invocation without one fails before publication. `source-link` is Skill-only and requires a durable user-owned local source. Agent installation uses its native-copy behavior and rejects `--method`. A release-track first installation has no base version, so it requires `--release <literal-tag>` or an interactive exact release choice; never infer a range from nothing or pick latest silently. Missing type-specific source/track settings for a newly declared Git source prompt interactively or fail unattended; never silently assume `main`.

**Source association and change.** `source associate` requires one or more explicit `--only` names of supported adopted records whose source is unknown; the declared config source/track supplies the reviewed association for exactly those records. `source change` requires `--to <configured-pack-key>` naming the pack declaration that supplies the desired source/track for the shared pack context. Both are dedicated, explicitly requested operations, not ordinary update flags, and neither implies content update or resource conversion. Their plans are reviewed like any mutation plan, and `--yes` may approve that plan only because the operation and target declaration were already explicit; `--yes` on an ordinary update never authorizes a source or track change. If verified continuity evidence is inadequate, do not transfer folder approvals, and keep historical snapshots' truthful original provenance. Config keys for GitHub packs must agree with the authoritative source fields; a reviewed rename/transfer may move the declaration key while provider identity, locators, old history and new evidence remain distinguishable. Concurrent config changes are not overwritten; a conflicting declaration is reported for a fresh reviewed change.

**Removal.** Naming resources in an explicit `remove` command is itself a removal request; the review shows each removal, and `--yes` may approve that plan. In contrast, an update never deletes because a resource is absent upstream without explicit consent: interactive runs prompt, and unattended runs require a matching repeatable `--approve-removal <name>`. Absence inferred from a failed or incomplete acquisition, pagination limit, or partial discovery is never treated as upstream removal. `--approve-removal` cannot name resources outside the selected context or substitute for `--only` selection.

`rollback` requires exactly one `--only` and one recorded ref for that installation; there is no shared ref across resources. It performs normal ownership, edit-preservation and candidate verification, with link-only behavior for source links. `cleanup` selects the pack/context and optional named resources and shows each eligible deletion before approval. Without `--local-edits` it considers only expired ordinary snapshots; `--local-edits` explicitly selects eligible edited backups as well and makes their loss prominent. Never remove current, active-recovery, unexpired or shared-needed bytes; explicit selection is not a safety bypass. `--allow-folder` is Skill-only and cannot expand `--only`. Repeated identical selectors and conflicting keep/replace choices are invalid. An exact release selector affects only selected resources, not the shared track.

### Publication ordering and recovery

For each independently selected resource: (1) stage and validate, revalidate reviewed source/live/ownership/config evidence, then durably record publication intent; (2) verify the old state and preserve/verify the complete old content, including edits when present, before any destructive publication; (3) publish the complete staged entry and verify actual published state; (4) atomically publish matching lock truth and snapshot/approval evidence, then mark the journal complete. If lock publication fails after live publication, retain the intent and backups, and either verify restoration of the old state and its lock truth or record recovery-required; never report a clean failure without evidence. A failure with verified isolated recovery does not poison later independent resources. Stop if authoritative shared state or ownership/isolation evidence is unreliable. Save successful per-resource manifest selection after that resource succeeds, with crash-safe publication and truthful reporting if save fails; save shared policy only after the entire selected operation has no failures. No global atomicity and no rollback of unrelated successes. Never attribute locally edited backup bytes or mutable source-link target observations to an upstream snapshot.

### Additional acceptance cases

| Scenario | Expected result |
|---|---|
| [C] Missing selected/user file; explicit config override | Missing inherited defaults are empty; selected-file rules above apply; override changes only selected scope file and relative-path base. |
| [C,I] Host collision, alias and provider continuity | Duplicate normalized key/source aliases reject; verified GitHub numeric identity can support reviewed continuity; generic locator equality alone cannot reuse approval. |
| [A,L] First release, non-SemVer, `v` tags, builds and ties | Explicit first/exact choice required; strict parse and range checks; equal-precedence different candidates require exact choice, never timestamps. |
| [A,L] Shared release policy with different resource snapshots | Per-resource current lock establishes each range; advancing snapshots does not create config mismatch. |
| [L] `--only` with `--skip-new`, or applicable `--no-save` with `--save-policy` | Preflight invalid-input rejection, no hidden selection expansion or publication. Inapplicable recognized mode options are warned and ignored before conflict checks. |
| [A,L] Inapplicable `--bump` and `--release` on a branch source | Both are warned and ignored; no track change, no mutual-exclusion failure. |
| [L] Upstream absence on update with and without `--approve-removal` | Interactive prompt or explicit approval required; unattended silence fails preflight; incomplete discovery never counts as absence. |
| [C,L] Noninteractive mutation without `--scope` | Invalid-input failure; scope is never inferred from working directory, config location or state location. |
| [L,S] Rollback with multiple names or a ref from another installation | Reject before publication; exactly one resource/ref pairing, link-only if applicable. |
| [P] Lock-write failure following verified live publication | Verify restoration plus old lock truth, or retain recovery evidence and return recovery-required; never falsely mark success. |
| [P,S] Cleanup with active recovery, unexpired or local-edit content | Protect active/current/unexpired/shared bytes; local edits only through explicit reviewed selection, never automatic age pruning. |
