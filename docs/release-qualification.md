# First-release qualification and readiness

## Readiness decision

**Not qualified yet.** Feature completion and release qualification are
separate claims. The native CI matrix and compiled-artifact gate are required
evidence producers; a local green suite or a help-only executable smoke is not
a release claim.

The current candidate uses `interact2` for all six application components and
for shared lifecycle/authoring confirmations. Mamba remains the command
framework and may retain Clix transitively, but no application prompt imports
Mamba's Clix re-exports. The vendored Clix fork, dedicated fork tests, and
direct Clix dependency were removed. Stock interact2 `MultiSelect` has no bulk
Select All action; the first-release contract does not require one. Its Ctrl+C
handling resets and exits with status 1 rather than returning a typed
cancellation answer. Graceful EOF behavior, complete terminal-mode restoration,
long-list viewport/wrapping, resize behavior, and real Windows/macOS/Linux PTY
acceptance remain unverified. Those items require implementation review and
native terminal evidence rather than being inferred from scripted adapters or
the standalone demo.

The earlier implementation candidate at `ec48558` passed the integrated native CI gate
([run 40745695510](https://github.com/louiss0/agent_resource/actions/runs/40745695510)):
Windows, macOS, and Linux jobs all passed with `--require-qualified`, the
aggregator reported `qualified: true` with no blockers, and production statuses
0–7 were observed. This is native matrix evidence, not the final readiness
decision below; real PTY terminal evidence and HTTPS credential/TLS Git
integration remain open. That evidence used the removed fork and a different
lockfile, so it does not qualify the current interact2 candidate. A release
still requires final human approval.

At the interact2 migration checkpoint, the local Windows built-artifact gate
observed true directory-symlink creation and built-production statuses 0
through 7, including a real restored
commit failure and committed-cleanup-pending outcome, schema-version-2 native
Agent and Skill installation, canonical content/exposure publication, and all
six conversion plan/apply/validate workflows. The gate now also exercises a
definition-only clone apply, a bound Codex role conversion with preserved
config/role bytes, a Claude parent settings plan/apply with unrelated-sentinel
preservation and acknowledgement refusal, a retained Skill backup restore, and
source-qualified graph exposure evidence marked `notPerformed` for runtime
verification. Its built-artifact blockers are cleared. macOS and Linux evidence
must still come from their native CI jobs, not be inferred from Windows. Real
terminal/PTY qualification and TLS credential-forwarding integration evidence
also remain open; scripted byte streams and plaintext local fixtures are not
substitutes. A final approval requires reviewing all three same-revision
bundles and closing every mandatory blocker.

Qualification does not authorize tags, releases, signing, distribution,
production cutover, live accounts, or harness installation. Offline native
validation does not certify runtime activation, account/model/tool
availability, permission enforcement, universal filesystems/architectures,
behavior-lossless conversion, or round-trip equivalence.

## Evidence protocol

`.github/workflows/ci.yml` pins Dart 3.13.2, enforces `pubspec.lock`, checks
formatting/analysis, runs the complete suite, builds the production executable,
and runs `test/support/release_gate.dart` on Windows, macOS, and Linux. Each
job uploads only `build/release-evidence.json` through
`actions/upload-artifact`. The gate's `qualified` field covers its native-job
artifact scenarios; it does not exercise raw interact2 MultiSelect prompts
and does not clear the interaction blockers described above.

Push/pull-request jobs retain evidence without claiming approval. A manual
`workflow_dispatch` runs each native gate with `--require-qualified`, then a
`release-decision` job aggregates all three same-revision bundles. The
aggregator—not a self-declared per-job deferral—verifies native job presence,
SDK/lockfile/revision/artifact identity, Windows link capability, and observed
statuses 0–7 before issuing the integrated verdict. Local reviewers can use
`--require-qualified` after the evidence path for per-job enforcement and
`test/support/release_decision.dart` for the integrated decision.

A bundle records the exact revision, artifact length/SHA-256, selected SDK,
lockfile SHA-256, native OS/architecture/filesystem observations, true
directory-link capability, CI job provenance, sanitized scenario arguments,
stream lengths, and observed/missing/deferred statuses. Rare statuses 5/6 are
mandatory across the release but may be deferred to the capable native Windows
job; they are blockers only when the release bundle lacks that evidence. Raw native documents,
instructions, stdout, stderr, credentials, and unrelated account state are not
retained. Test fixtures are synthetic and isolated from real cwd/home/config/
state/temp locations.

Changing the SDK, lockfile, implementation, or artifact invalidates affected
evidence. Missing mandatory positives, unexplained skips, flaky safety cases,
unobserved native capabilities, or stale revision/artifact references block
qualification. There is no repeat-until-green or coverage-percentage
substitute. During development, one combined Windows run reported a transient
lifecycle lock-acquisition failure and an isolated rerun passed; this incident
is not counted as resolved native reliability evidence and must be assessed
for recurrence in the mandatory matrix.

## Behavior-to-assertion-to-execution index

The requirement IDs below are stable traceability anchors, not a numerical
coverage score. “Command” means the production hierarchy via `Executor.fake`;
“operation” means a public operation with real isolated files; “artifact”
means the compiled production executable. Native execution evidence is the
three-OS CI matrix plus the per-job sanitized bundle.

| Requirement | Observable assertion and seam | Native/artifact execution |
| --- | --- | --- |
| AR-AUTH-001 | `agent_create_command_test.dart`: canonical positional create, native fields, privacy, no-write plan | Command; create/convert artifact workflows |
| AR-AUTH-002 | `agent_clone_test.dart`: separate definition-only clone, source provenance/bytes, no artifacts | Command and artifact clone apply; native CI suite |
| AR-AUTH-003 | `agent_edit_test.dart`: recorded unchanged identity and no-write managed edit | Command; lifecycle/recovery native suite |
| AR-AUTH-004 | `agent_compose_test.dart`: ordered instructions, stable plan, validated apply | Command and artifact apply |
| AR-AUTH-005 | `agent_authoring_service_test.dart`: conflicting selections require explicit field decisions | Operation; all native jobs |
| AR-PLAN-001 | Compose/conversion suites: same observations give stable IDs; changed request invalidates approval | Command/operation; artifact apply |
| AR-PLAN-002 | Planning snapshots show no target, state, locks, journals, staging, or backups | Command/operation and artifact full-project snapshots |
| AR-PRIV-001 | Default reports omit instruction sentinels; explicit show-instructions is opt-in | Command and artifact stdout assertions; sanitized bundles |
| AR-GRAPH-001 | `agent_graph_command_test.dart`: typed graph plus source-qualified exposure evidence | Command and built inspect graph with source-qualified exposure notes and `runtimeVerification: notPerformed` |
| AR-GRAPH-002 | `agent_graph_service_test.dart`: missing preload blocks, absent exclusion does not | Operation on every native OS |
| AR-GRAPH-003 | Graph coverage/budgets fail closed; no prose/script inference or runtime probes | Native parser/graph suites; runtime verification marked `notPerformed` |
| AR-CONV-001…006 | `agent_conversion_service_test.dart`: each Claude/Codex/Pi direction produces and publishes valid native output with exact instructions | Operation and six-direction artifact plan/apply/validate on every OS |
| AR-CONV-007 | Bound Codex conversion retains role/config provenance and exact source bytes | Operation and artifact bound-role plan/apply on every native OS |
| AR-CONV-008 | Conversion command accounts represented/altered/omitted fields and preserves source | Command; per-field results in artifact plans |
| AR-LIFE-001 | Existing Skill/Agent install/adopt/replace/remove/backup/recovery suites assert entries, ownership, backups, and sentinels | Existing command/operation native suite |
| AR-INSTALL-001 | `skill_install_test.dart`, `agent_install_test.dart`, and catalog suites cover explicit unattended choices, curated TOML, full preflight, schema-v2 envelopes, and no-effect rejection | Command and built-artifact schema-v2 install scenarios |
| AR-INSTALL-002 | Canonical content/direct consumers/managed exposures, independent copies, durable source links, and native Agent copies retain distinct ownership | Operation on isolated filesystems; built canonical/copy/link scenarios |
| AR-ACQ-001 | `acquisition_service_test.dart` covers inert immutable Git, bounded HTTP/archive processing, provenance privacy, malicious entries, duplicate members, deadlines, and cleanup | Native operation suite; TLS credential integration remains a blocker |
| AR-REC-002 | `resource_unit_transaction_test.dart` and `installation_batch_test.dart` prove coordinated restart recovery, commit-state classification, independent continuation, dependency skipping, and interruption | Deterministic isolated-filesystem operation tests plus real Windows statuses 5/6 |
| AR-MIG-001 | `docs/migrate-interactive-installation.md` requires source/evidence verification, retained backups, deliberate non-atomic removal/reinstall, and source-target preservation | Documentation review; no automatic conversion or origin inference |
| AR-TERM-001 | interact2 MultiSelect has no bulk Select All action (not required by this contract); Ctrl+C exits with status 1 rather than typed cancellation; EOF, terminal restoration, long-list/resize behavior, and cross-platform PTY behavior remain unverified | Real Windows/macOS/Linux PTY acceptance and the remaining interaction checks are mandatory evidence |
| AR-LINK-001 | True-link entry ownership, target drift/broken targets, Windows subtype/privilege behavior | Existing native-link suite plus measured artifact-gate capability |
| AR-PARENT-001 | Parent selected-unit patches preserve unrelated bytes/settings and require acknowledgement | Existing parent/bound-role native suite; artifact parent plan/apply with unrelated-sentinel preservation and status-4 acknowledgement refusal; canonical/legacy CLI aliases |
| AR-REC-001 | Deterministic fault/restart tests assert restored, recovery-required, cleanup-pending, occupants, and corrupt evidence | Existing lifecycle/parent fault suites with protected journal/baseline assertions, real Windows statuses 5/6, and artifact Skill backup restore |
| AR-STATUS-001 | Real statuses 0, 1, 2, 3, 4, and 7 use correct streams/statuses | Built artifact on every native OS |
| AR-STATUS-002 | A read-only ledger produces real post-publication restored status 5; a read-only managed Agent produces committed-cleanup-pending status 6 while preserving its baseline | Observed on native Windows; deferred on other jobs, never replaced with injected-fault evidence |
| AR-BOUND-001 | Existing exact/one-over parser, inventory, tree, parent, request, management, graph, and aggregate budgets | Native full suite; over-cap artifact status 3 |
| AR-ISO-001 | Process/environment helpers isolate cwd/home/config/state/temp and preserve escape sentinels | Existing process suite and artifact gate |
| AR-IFACE-001 | Help/parser tests cover retained declarations, request aliases, operation agreement, conflicts, and no-effects rejection | Command and artifact smoke |
| AR-PROV-001 | Bundle revision/artifact/SDK/lockfile/OS/job fields match the selected candidate | Per-job uploaded JSON; reviewed together before approval |

## Final approval checklist

1. Confirm all three native bundles name the same revision, selected SDK, and
   lockfile hash, with each artifact hash matching its executed binary.
2. Review the index for orphan requirements, missing platform/scenario
   results, skipped mandatory positives, and unsafe artifact contents.
3. Require successful formatting, analysis, focused/full suites, native matrix,
   and built-artifact workflows on the candidate.
4. Verify real status 5/6 evidence and required Windows true-directory-link
   capability/refusal evidence; do not substitute injected-fault results for
   production-process evidence.
5. Record remaining limits and blockers explicitly. Only an empty mandatory
   blocker set permits changing the readiness decision to qualified.
6. Do not qualify interactive installation until interact2's cancellation/EOF
   behavior, terminal restoration, long-list rendering, resize behavior, and
   real Windows/macOS/Linux PTY acceptance meet the approved contract.
