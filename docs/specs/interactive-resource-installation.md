# Interactive resource installation refactor

**Status: approved.** The human approved this implementation route, operational budgets, scheduling, status mapping and success-envelope proposals. This is a planning artifact, not authorization to implement or claim shipped behavior.

Decision: [Define refactor seams and migration into the interactive installation contract](https://github.com/louiss0/agent_resource/issues/42).
Map: [Chart default-interactive skill and agent-definition installation](https://github.com/louiss0/agent_resource/issues/35).

## 1. Authority and destination

Design from Agent Resource's existing implementation and the resolved product contracts. **Discard the borrowed Vercel implementation blueprint**: do not copy its installer or adopt the originally suggested pipeline classes. The upstream research remains historical comparison evidence, not architectural authority. No proposed class name or one-class-per-stage structure is inherited from it.

The destination is a clear implementation route for default-interactive `skill install` and `agent install`, curated source offerings, owned installations, and migration. Implementation happens after this planning effort.

Binding decision details live in their tickets:

- [Interactive installation and automation](https://github.com/louiss0/agent_resource/issues/37).
- [Curated source and acquisition contract](https://github.com/louiss0/agent_resource/issues/38).
- [Native agent compatibility](https://github.com/louiss0/agent_resource/issues/39).
- [Installation ownership](https://github.com/louiss0/agent_resource/issues/40).
- [Batch safety and Mamba errors](https://github.com/louiss0/agent_resource/issues/41).
- [Typed source-configuration schema](https://github.com/louiss0/agent_resource/issues/43).

This document resolves their integration, not competing copies of those decisions. Where an earlier generic interaction description conflicts with the later agent-specific or curated-source refinement, the later explicit decision controls.

## 2. Architectural shape

Use **resource-specific installation workflows with focused shared modules**. Concrete commands own Mamba inputs, call the applicable workflow, and translate its aggregate outcome to Mamba success/failure. Do not introduce a universal ResourceManager, resource/operation command factory, global input registry, second installer, or chain of public pass-through classes.

### Existing implementation to retain and deepen

| Existing module | Refactor responsibility |
| --- | --- |
| `lib/skill_lifecycle_commands.dart` | Adapt concrete skill installation inputs and result delivery; retain other lifecycle behavior except explicit canonical-artifact extensions. |
| `lib/agent.dart`, `lib/lifecycle.dart` | Replace the generic agent-install branch with a concrete command; do not rewrite unrelated operations merely for symmetry. |
| `lib/src/services/skill_lifecycle_service.dart` | Retain skill validation, package safety and native conflict knowledge; add canonical content/exposure planning and distinguish intentional replicas from conflicts. |
| `lib/src/services/agent_lifecycle_service.dart` | Retain native file publication eligibility, validation and ownership; accept already-acquired, explicitly profiled candidates. |
| `lib/src/services/lifecycle_state_service.dart` | Extend the existing transaction/recovery authority to coordinated resource units and associated exposure entries. |
| `lib/src/services/native_link_service.dart` | Retain native-kind verification, refusal behavior and safe link operations; no silent junction/copy fallback. |
| Existing skill/native-agent validation and reference modules | Remain authoritative for resource correctness, native semantics and bounded offline readiness. |
| `lib/agent_resource.dart` | Compose fresh commands and injected production dependencies; expose the same composition to tests. |
| `bin/agent_resource.dart` | Keep `create()` as the process-facing entry point. Remove global Chalk suppression and its misleading comment. |

### Real shared modules and seams

1. **Acquired workspace:** resolve supported locators, acquire an inert bounded source, retain requested/resolved provenance and own temporary cleanup. Callers receive a scoped local workspace, not Git/HTTP/archive implementation details. Local source ownership remains external. Git, HTTP, archive and local adapters implement genuinely different acquisition behavior.
2. **Curated configuration:** bounded TOML loading produces immutable typed skill/agent offerings or typed diagnostics with resource-type isolation. It does not crawl, install, prompt, infer ownership or become an application configuration framework.
3. **Interaction:** production application components use interact2 directly; Mamba remains the command framework. Scripted adapters supply answers in workflow tests. The interface speaks in candidate identities and explicit outcomes, not display strings or raw indices.
4. **Batch coordination:** schedule approved resource units, accumulate truthful outcomes, continue only independent units after safely restored failures, stop on uncertainty/interruption and provide one aggregate report. Native planning and resource-unit publication remain delegated to their existing modules.
5. **Publication/recovery:** one authority in the lifecycle/state machinery owns locks, intents, staged entries, records, baselines and recovery. Add a resource-unit operation there; never fake recovery with repeated public `install()`/`remove()` calls.

Keep acquisition handles, validated catalog entries, source/profile/method variants, observations, plans and outcomes typed. TOML maps and arbitrary strings stop at validating constructors/factories. Use closed skill/agent and expected-outcome variants; do not make callers assemble unchecked maps. Existing persisted formats may be adapted at their own validated interfaces. Prefer the Dart 3.13 conventions documented in the project skills.

Commands expose few operations and retain their private Mamba declaration handles. No mutable invocation data belongs on reused command instances. Overlapping fake/production invocations must not share selection, approval, plan or report state inadvertently.

## 3. Public installation inputs

The following vocabulary was approved. Exact help must state applicability and conflicts.

```text
skill install [source]
  --resource <catalog-id> ... | --all-resources
  --target claude|codex ...
  --scope project|user
  --method canonical|copy|source-link
  --ref <branch-or-tag-or-commit>
  --subpath <source-relative-path>
  --source-kind collection|resource
  --dry-run
  --yes
  --format text|json

agent install [source]
  --resource <catalog-id> ... | --all-resources
  --target claude|codex|pi ...
  --profile claude|codex|pi-common
  --scope project|user
  --ref <branch-or-tag-or-commit>
  --subpath <source-relative-path>
  --source-kind collection|resource
  --dry-run
  --yes
  --format text|json
```

- Preserve applicable cwd/project/home/native-home/state/read-root context overrides with their current scope semantics; they do not configure native clients.
- Use an optional string-shaped source positional suitable for paths and locators, not the old mandatory separator-terminated local-directory positional. Do not replace Mamba's parser.
- `--resource` repeats; it conflicts with `--all-resources`. IDs match exactly. These selectors apply to collections; exact-resource intent does not invent a catalog ID.
- `--target` repeats and denotes consuming harnesses, not validation-only profiles. Deduplicate identical occurrences without broadening the requested set.
- `--profile` supplies a direct agent file's missing declaration. Catalog entries already declare their profile; a redundant/conflicting direct-only profile input on a collection is rejected, not used to reinterpret catalog entries.
- Skill methods are `canonical` (default), `copy`, `source-link`. Agents are copy-only and reject a method selector.
- Interactive default scopes remain skill/user and agent/project. Missing unattended scope or applicable method fails rather than accepting those interactive defaults.
- `--source-kind` resolves collection/exact-resource intent. For unattended exact resources it is required; explicit `resource` plus the supplied exact source is explicit resource selection. Collections require explicit IDs or `--all-resources` unattended.
- Skill repository discovery amendment: acquire Git sources into the existing inert temporary workspace and discover Skills there. GitHub `owner/repo` and root repository HTTPS URLs, including trailing slash, use Git acquisition; existing local paths win over shorthand, and explicit `./` remains local. A root Skill remains exact; a present curated config remains authoritative. A directory with both requires explicit kind. Explicit `resource` never scans. Without either marker, Skill directories are discovered as a collection; explicit `collection` can likewise use discovery without a manifest. Agents remain catalog/exact-file only.
- Discovery recursively searches conventional `skills/`, `.agents/skills/`, `.claude/skills/`, `.codex/skills/`; absent all such directories, search the selected tree. Never broaden beyond selected `--subpath`. Match exact regular-file `SKILL.md`, stop at package boundaries, skip hidden descendants, `node_modules`, and `vendor`, and never follow directory/marker links. Fail closed on incomplete reads/budget exhaustion: depth 16, 2,000 directories, 20,000 entries, 1,000 candidates. Sort source-relative forward-slash paths deterministically; those paths are discovered selection IDs, not invented manifest IDs or configuration digests. Validate selected packages using existing full preflight, including destination collisions; do not deduplicate same-named Skills silently. Interactive collections always ask for selection; unattended collections require exact IDs or `--all-resources`. No candidates is a diagnostic, never a partial success.
- Git symlinks are never materialized or followed. Acquisition records their repository-relative paths; unrelated links outside selected packages do not block discovery. A selected package containing an omitted link is refused rather than silently installed incomplete, including with `--subpath`. HTTP archives retain strict link rejection.
- `--ref` is Git-only. Reject inapplicable selectors; explicit source-relative `--subpath` never expands to a broader scan. Explicit revision/subpath options govern provider convenience normalization. Unresolvable or ambiguous requests fail with guidance.
- Remote collections come from repositories or archives. A direct downloaded configuration file does not authorize crawling its host for the declared directories; reject that unsupported collection form with guidance to a repository/archive.
- `--yes` approves only the current final plan. It supplies no selection/default, force, takeover, repair or adoption authority.
- `--dry-run` may read/acquire temporarily and collect interactive choices, but performs no installation/management writes and requires no approval. A later invocation recomputes observations; dry-run is not a reservation or reusable approval token.
- JSON and lack of a usable terminal require explicit planning choices. JSON bypasses prompts/progress even on a terminal. Parser failures remain Mamba failures.

### Retired install inputs

Reject obsolete install `--destination`, `--harness`, `--mode` and opt-in `--interactive` with actionable migration guidance. Do not reinterpret old skill `--harness` validation-only semantics as consuming-target authorization. Maintain unrelated lifecycle command behavior unless explicitly extended for the new artifact. Help and parser rejections must occur before domain effects.

## 4. Interaction implementation

Start supported declarations using the matching Mamba generators; edit them afterward, wire generated commands and replace starter tests. Mamba components are plain async `render()` classes, not registered commands.

- Source prompt: interact2 `Input`; trimmed blank input cancels.
- Resource selection: interact2 `MultiSelect`, initially unchecked, map indices to the exact offered typed identities. The separate explicit Select All acceptance requirement remains; stock interact2 does not implement it.
- Skill target selection: interact2 `MultiSelect`, detected compatible targets preselected via a boolean mask; sole detected compatible target skips the question; zero detected starts unchecked.
- Agents: selected explicitly profiled native definitions determine targets; no redundant harness multiselect. Explicit target filters narrow catalog offerings before selection.
- Approval: application-rendered complete plan followed by interact2 `Confirm(defaultValue: false, waitForNewLine: true)`. Lifecycle and authoring confirmations use the same component. Without both terminal handles, decline without invoking raw-key input or reading redirected stdin; approval must never be inferred from EOF.
- Acquisition/discovery progress: interact2 spinner, completed on success and failed/disposed on handled acquisition failure; cleanup must not mask the acquisition error.
- Scope and method are disclosed defaults, not extra questions.

The user explicitly selected interact2 after a standalone Windows multiselect succeeded and stock Clix failed. Application components import interact2 directly; Mamba remains the command parser and may retain Clix transitively. No application prompt uses Mamba's Clix re-exports. Prompt exceptions trigger best-effort interact2 reset without hiding the original exception; this restores cursor/colors, not a guarantee of complete terminal-mode restoration. interact2 handles Ctrl+C by resetting and exiting with status 1, not a typed cancellation answer. Empty option lists must not enter the library (which rejects them). Existing typed workflow cancellation remains separate from process interrupts.

The adapter still owns empty selection and identity mapping. The migration is not proof of graceful EOF, Select All, viewport/wrapping, resize, or cross-platform PTY acceptance; those remain explicitly unverified requirements. Do not edit the user's pub cache or assume Executor.fake() answers raw prompts. Any dependency change must be inspected and tested against the resolved Mamba version before adoption.

## 5. Acquisition implementation and provenance

Approved tool strategy: **system Git plus Dart HTTP/archive handling**.

- Invoke Git without a shell. Require it only for Git sources, diagnose absence early, and do not install/elevate tools automatically.
- Implement inert materialization: no source hooks, submodules, source-selected executable filters/helpers or resource execution. Git configuration/attributes, credential-helper use and environment handling need explicit tests; a normal checkout with trusted defaults is not sufficient proof. Reuse configured authentication deliberately, never source-supplied commands or a new login wizard.
- Use Dart HTTP I/O with bounded streaming, timeouts and redirect handling. Do not leak URL credentials, authorization headers or credential-helper output into reports/provenance.
- Inspect and pin a Dart archive dependency before adoption. Validate members and expansion budgets during processing, before unsafe writes. Reject escaping paths, absolute entries and unsupported links/special entries. No external tar/unzip dependency or unsafe fallback.
- Hosted download optimizations are optional internal adapters only when they preserve selected revision, package boundary, provenance and safety. They cannot broaden source coverage or change identity.
- Workspaces are scoped and temporary; no persistent cache before approval. Cleanup retains protected transaction evidence when recovery needs it, and required cleanup failures remain visible.
- A local skill directory supplies its complete validated tree. A direct file supplies only that file, disclosed as such. A durable local source-link requires an explicitly selected local directory and never a temporary acquired target.

New records must carry evidence-backed origin information: sanitized requested locator/source kind, resolved repository identity and commit where applicable, selected subpath, config digest and entry ID for collections, declared profile, observed resource-content evidence and download digest where applicable. Record requested ref separately from resolved commit. Local source-link target observations are not owned-content history. Never synthesize an origin for old unknown-origin records or use an equal name/hash as proof of management identity.

### Approved bounded defaults

These are trusted application limits, not source-configurable policy:

| Processing | Limit |
| --- | --- |
| Source config | 1 MiB bytes; nesting depth 16; 100,000 parsed nodes |
| Requested catalog | 1,000 entries, including entries later excluded by selectors |
| Config ID | Previously agreed 64 ASCII characters |
| Config path / label | 4,096 UTF-8 bytes / 256 Unicode scalar values |
| HTTP redirects | 5, retaining secure transport/credential boundaries |
| One direct download or compressed archive | 64 MiB streamed input |
| Materialized acquisition tree | 20,000 entries; depth 32; 256 MiB ordinary contents; 64 MiB per ordinary file |
| Acquisition deadline | 120 seconds overall, including subprocess cancellation/cleanup handling |

Retain independently binding existing smaller skill/native parser, resource tree, inventory and management-state budgets. These acquisition/config limits do not raise them. Reject budget exhaustion with bounded diagnostics; never infer absence, uniqueness or readiness from partial processing. Apply bounds during reads/extraction/materialization, not after unlimited allocation. If a chosen library cannot enforce the contract, fix/replace that implementation before release; do not weaken the limits. Global read/parser safety exhaustion can block both types, unlike ordinary type-isolated semantic catalog errors.

Downloads use HTTPS by default; explicit plaintext HTTP inputs must not receive credentials or be silently upgraded/downgraded. Never follow HTTPS-to-HTTP redirects. Cross-origin redirects must strip authorization and be bounded/validated; no forwarding secret material to a new origin. Only supported Git/HTTP transport schemes are accepted; executable Git transports and shell interpolation are forbidden.

## 6. Publication, ownership and scheduling

Extend existing lifecycle/state transaction machinery for a resource-unit operation. A validated immutable plan enumerates owned contents, link entries and record changes, required observations, existing identities, no-ops and recovery preconditions. Stage and journal through this authority; the workflow does not implement another mutation engine.

Canonical skill records own one content tree and associated tracked exposure entries/direct-consumer relationships. Keep link baselines separate from canonical content and do not create independent ownership of the same bytes. Independent copies and external-source links retain their existing distinct ownership semantics. New agent copies stay standalone native files.

For new skill installs, use the selected documented compatibility baseline: Claude native exposure/copy roots, and Codex direct consumption through scope-specific `.agents/skills`. Existing `.codex/skills` locations remain legacy inventory/management inputs, not recommended new Codex targets. Respect home/Claude overrides without inventing `$CODEX_HOME/.agents/skills`. Paths and capability mappings are application-owned, not source-configurable. Project roots remain the explicitly resolved project boundary, not an arbitrary ancestor.

**Approved scheduling:** execute sequentially in the displayed deterministic plan order. Shared ownership/conflict dependencies are established during preflight. Expected changes of completed planned units are accounted for explicitly; unrelated drift is not permitted. No initial parallel publication scheduler is needed.

Full preflight gates the complete batch. After approval, revalidate reviewed observations and before-write predicates. One selected resource across all requested targets and tracking is one recovery unit. On safely restored failure, retain completed units and continue only independent planned units. Unresolved recovery/shared-state uncertainty/required cleanup pending stops remaining work. Source changes, ownership drift and new occupants never authorize stale publication or destructive rollback.

Ctrl-C after writes requests no new units and a safe current-unit conclusion; completed installations remain. Persist evidence for forced-stop recovery; no guaranteed cleanup after process kill/power loss. Normal error and interruption outcomes remain typed until final Mamba translation. Unexpected programmer Errors are not swallowed as recoverable resource failures.

## 7. Existing state and lifecycle migration

- Read supported existing copied/linked/native-file records with their original installation identities and ownership meaning. Do not bulk rewrite records, infer source origin, rebaseline, relocate content or promote old shared copies to canonical ownership.
- Version new origin/compound canonical record and intent variants explicitly. New writers must preserve supported historical evidence; unknown/incompatible schemas refuse instead of resetting state. Unsupported older writers/downgrades are not a supported concurrent operating mode; document capability/version refusal and backup/recovery requirements.
- No general old-to-canonical conversion/relocation command in this effort.
- Provide a migration guide: verify source availability, inspect/verify old ownership, retain adequate recovery evidence, deliberately remove the old installation, then install with the new contract. Disclose the interruption gap, potential failures and lack of sequence-wide atomicity. Never delete a source-link target. If source/evidence is unavailable, stop rather than erase the only copy.
- Existing source-copy/link replacement modes continue for old artifacts. Canonical replacement preserves its identity/method, validates all associated entries and discloses all consumers' content effects; it does not implicitly change method or acquire a new destination.
- `skill list` reports canonical identity/content, exposure baselines and direct-consumer observations without claiming runtime activation.
- `skill remove <installation-id>` previews full canonical deletion/all owned exposure effects. For canonical artifacts, explicit `--target <harness>` detaches a managed exposure link only, retaining canonical contents. Reject an attempt to revoke a direct reader through metadata removal; explain that shared content remains discoverable. Do not apply this selector ambiguously to legacy artifact kinds.
- Backup/restore/recovery must support the canonical content plus owned exposure entries and records before new canonical installs ship. Preserve external-target exclusion and new-occupant/later-edit safety.
- Old canonical-path occupants without proven matching canonical records are conflicts, not automatically adopted/no-op installations. Separate explicit adoption remains under its supported artifact kinds; no canonical takeover shortcut.

## 8. Mamba delivery, color and status mapping

The executable continues `create()` delivery. Tests use `fake()` with application-owned dependencies. Return successful rendered output; throw MambaException with an aggregate diagnostic and nonzero status for handled failures. Mamba owns stderr and process status. No manual exit-code assignment, failure-shaped success string, separate stdout failure writer or success-only post-hook rollback.

**Remove `chalk.level = 0` from production.** Normal human output/Mamba stderr may be colored. JSON success serialization contains plain data and no prompts/progress/ANSI; failed JSON requests still use normal Mamba stderr text with empty stdout. Exact-output tests control color in isolated setup and restore globals, rather than impose production policy. Test real normal-color behavior as well as deterministic no-color fixtures.

### Approved install status mapping

| Code | Meaning |
| --- | --- |
| 0 | Complete install/no-op, valid preview, or explicit pre-write cancellation |
| 1 | Invocation/config-shape/general request failure not classified below; unexpected caught Exceptions retain Mamba's default mapping unless deliberately translated |
| 2 | Blocking resource/native correctness or required-reference failure |
| 3 | Required acquisition/read/preflight coverage incomplete, unavailable source or exhausted processing budget |
| 4 | Ownership/safety/approval/capability refusal, including relevant stale-plan observations before affected writes |
| 5 | Execution failed but affected state was safely restored, or a safely concluded batch contains failures/retained successes with no unresolved recovery |
| 6 | Recovery required, uncertain committed management state or required cleanup pending |
| 7 | Post-write interruption safely concluded, with truthful retained-change reporting |

For aggregate execution, unresolved recovery (6) outranks interruption (7); otherwise a safely concluded mixed-success/failure batch uses 5. A wholly pre-write refusal uses the relevant 1–4 classification, never success. State exactly which resources/targets changed, restored, failed or never started; an exit code alone is not a report. Existing unrelated lifecycle status conventions remain unchanged.

### Approved successful JSON envelope

Use `schemaVersion: 2` **for the new install commands only**, retaining the familiar `command`, `outcome`, `data`, `diagnostics` envelope shape. Do not change all existing reports globally.

- `command`: `skill install` or `agent install`.
- `outcome`: `planned`, `installed`, or `unchanged`; human explicit pre-write cancellation uses text outcome `cancelled` because JSON never prompts.
- `data`: `planId`, `source`, `scope`, `units`, `summary`.
- `planId`: deterministic versioned digest of request and relevant observations, not a reservation or persisted approval token.
- `source`: sanitized acquisition/provenance observations; no credentials or instruction bodies.
- Each unit: `resourceType`, `resourceId` (catalog ID, or explicit exact-resource identity), `nativeName`, `profile`, `method`, `status`, `installationIds`, `entries`.
- Entry reports identify `path`, owned `kind`, `action`, relevant `target`/`linkTarget` and direct-reader relationships. Structurally inapplicable information is omitted, not invented.
- Successful status/action vocabulary: units `planned`, `installed`, `unchanged`; entries `create-content`, `create-copy`, `create-link`, `record-consumer`, `unchanged` as applicable.
- `summary` counts requested units, installed, unchanged and planned, plus owned-entry effects; no instruction/secret dumps.
- `diagnostics` remains structured bounded non-sensitive notes. On failure no success document is emitted; the MambaException text contains aggregate unit/target outcomes and recovery guidance.

Specify deterministic ordering and wire fixtures in implementation. Domain invariants are typed; only final serialization uses maps.

## 9. Implementation route and release gates

These are execution slices, not new wayfinding decisions. Start supported declarations using Mamba generators and replace scaffold tests. Each slice adds behavior through the same production command tree.

1. **Typed inputs/catalog and parser contract.** Add bounded curated TOML loading; concrete agent-install command; new Mamba declarations/conflicts and obsolete-input guidance. Verify no domain effects for help/parser rejection. No fake discovery aliases or unimplemented command wiring.
2. **Local planning and interact2 interactions.** Implement exact/collection local workspaces, scripted interaction seam and production application components; source/profile/selection flow, scope/method disclosure, stable plan observations, preview-only and final approval. Verify interact2 terminal/cancellation behavior and fix demonstrated underlying defects. No release of an unsafe raw-input path.
3. **Resource-unit publication.** Extend existing lifecycle/state machinery for staged multi-entry units, versioned provenance/canonical records, link/copy actions, known no-ops, revalidation and deterministic aggregate outcomes. Keep native validators and publication guards authoritative.
4. **Canonical lifecycle completeness.** Implement list/replace/remove/exposure-detach/backup/restore/recovery for new records and old-record compatibility tests. Do not enable shipped canonical installation before these operations work.
5. **Remote acquisition.** Add configured Git, Dart HTTP and verified archive adapters through the workspace seam. Test safe materialization, refs/subpaths, direct-file limitations, credentials/redirections, budget enforcement and cleanup. Remote candidates still enter through the same typed config/native validation and publication paths; no second installer.
6. **Batch fault/cancellation proof.** Exercise full preflight, safely restored failure with independent continuation, uncertain recovery stop, tracking commit failure, stale observations, shared-content effects, interruption and restart recovery with persisted evidence. Assert exact actual retained state.
7. **Public migration and qualification.** Update README/help/spec amendments/completions, migration guide and release qualification. Remove production Chalk suppression; verify Mamba delivery and normal color. Run formatting, analysis, focused/full suites and built-process tests on supported native systems, including real symlink positives/refusals. Review standards and spec compliance against the fixed implementation baseline.

Development may be incremental, but full supported behavior is gated by these acceptance requirements. Do not advertise partially implemented providers/methods as complete or use green capability skips as platform support evidence.

## 10. Acceptance matrix

- Separate skill/agent commands, no root install alias, coherent new flags, explicit unattended choices, exact-resource exception, direct profile applicability, migrated obsolete-input diagnostics, correct context overrides and side-effect-free help/parse rejection.
- Every TOML v1 field/namespace/path/type-isolation/duplicate/version/empty-catalog case in the schema decision; strict processing budgets and diagnostic privacy.
- Production interact2 selection/default/index mapping, explicit Select All, empty selection, and source/profile prompts. Escape/Ctrl-C/EOF handling, prior terminal-mode restoration, long-list viewport/wrapping, and resize behavior on supported real Windows/macOS/Linux terminals. No assumption that Executor.fake supplies prompt answers.
- Canonical skill contents, direct readers and managed links; independent-copy fan-out; durable local-source-link ownership; native agent copies; no redundant links, implicit conversion/registration/repair or source mutation.
- Source provenance, immutable commit evidence versus requested refs, direct-file boundary disclosure, safe Git/HTTP/archive processing, private workspace lifetime, no credential leaks, remote-to-source-link rejection and cleanup failures.
- Complete preflight/no writes; correct no-ops; intentional replicas versus conflicts; races/new occupants; stale source/baseline/exposure observations; existing canonical content preserved on failed exposure addition.
- Fault injection before/after preparation, intent, backup, quarantine, publication, verification, record commit, restoration and cleanup; independent continuation versus stop-on-uncertainty; forced-stop restart recovery from persisted evidence.
- Old state/artifact kinds remain manageable; unknown schemas refuse; no origin inference or implicit upgrade. Migration guide demonstrably preserves external sources and does not claim atomic removal/reinstallation.
- Complete Mamba fake result/phase/path/status assertions plus built-executable stream/status tests. JSON failure has empty stdout; normal color is not globally suppressed. No manual process-exit writes in commands and no success-only-hook cleanup dependency.
- Observed filesystem contents, entry kinds/targets, protected records/backups, permissions and untouched external sentinels matter more than output snapshots. Test through public operations, not private helper shape.

## 11. Scope closure

Standalone native installation excludes role bindings, parent changes, engine installation, runtime orchestration/probes and dependency repair. Curated source catalogs exclude external includes and automatic dependencies. Skill collections additionally support the bounded repository discovery amendment in §3; this does not introduce Agent discovery or a dependency solver. This route covers references through existing bounded native readiness, not a new dependency solver.

Lifecycle support necessary to avoid stranding canonical installations is included. Remote check/update/synchronization commands, general conversion/relocation, automatic garbage collection and further maintenance UX are separate future efforts, not remaining requirements of this installation-refactor map. No unresolved future-runtime or unlisted-resource speculation belongs in its fog.

No application implementation or dependency additions are made by approving this specification. The only repository changes during planning are this spec and concise glossary vocabulary.
