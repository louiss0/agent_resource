# First-release qualification and readiness

## Readiness decision

**Not qualified yet.** Feature completion and release qualification are
separate claims. The native CI matrix and compiled-artifact gate are required
evidence producers; a local green suite or a help-only executable smoke is not
a release claim.

The current local Windows gate observed built-production statuses 0, 1, 2, 3,
4, and 7 and all six conversion plan/apply/validate workflows. It did not
observe real statuses 5 or 6, and the host refused true directory-symlink
creation. Those are explicit blockers. macOS and Linux evidence must come from
their native CI jobs, not be inferred from Windows. A final approval requires
reviewing all three same-revision bundles and closing every mandatory blocker.

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
`actions/upload-artifact`.

Push/pull-request jobs retain evidence without claiming approval. A manual
`workflow_dispatch` runs the same gate with `--require-qualified`, which exits
nonzero when any blocker remains. Local reviewers can use that flag after the
evidence path argument for the same enforcement.

A bundle records the exact revision, artifact length/SHA-256, selected SDK,
lockfile SHA-256, native OS/architecture/filesystem observations, true
directory-link capability, CI job provenance, sanitized scenario arguments,
stream lengths, and observed/missing statuses. Raw native documents,
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
| AR-AUTH-002 | `agent_clone_test.dart`: separate definition-only clone, source provenance/bytes, no artifacts | Command; native CI suite |
| AR-AUTH-003 | `agent_edit_test.dart`: recorded unchanged identity and no-write managed edit | Command; lifecycle/recovery native suite |
| AR-AUTH-004 | `agent_compose_test.dart`: ordered instructions, stable plan, validated apply | Command and artifact apply |
| AR-AUTH-005 | `agent_authoring_service_test.dart`: conflicting selections require explicit field decisions | Operation; all native jobs |
| AR-PLAN-001 | Compose/conversion suites: same observations give stable IDs; changed request invalidates approval | Command/operation; artifact apply |
| AR-PLAN-002 | Planning snapshots show no target, state, locks, journals, staging, or backups | Command/operation and artifact full-project snapshots |
| AR-PRIV-001 | Default reports omit instruction sentinels; explicit show-instructions is opt-in | Command and artifact stdout assertions; sanitized bundles |
| AR-GRAPH-001 | `agent_graph_command_test.dart`: typed graph plus source-qualified exposure evidence | Command and built inspect graph evidence |
| AR-GRAPH-002 | `agent_graph_service_test.dart`: missing preload blocks, absent exclusion does not | Operation on every native OS |
| AR-GRAPH-003 | Graph coverage/budgets fail closed; no prose/script inference or runtime probes | Native parser/graph suites; runtime verification marked `notPerformed` |
| AR-CONV-001…006 | `agent_conversion_service_test.dart`: each Claude/Codex/Pi direction produces and publishes valid native output with exact instructions | Operation and six-direction artifact plan/apply/validate on every OS |
| AR-CONV-007 | Bound Codex conversion retains role/config provenance and exact source bytes | Operation on every native OS |
| AR-CONV-008 | Conversion command accounts represented/altered/omitted fields and preserves source | Command; per-field results in artifact plans |
| AR-LIFE-001 | Existing Skill/Agent install/adopt/replace/remove/backup/recovery suites assert entries, ownership, backups, and sentinels | Existing command/operation native suite |
| AR-LINK-001 | True-link entry ownership, target drift/broken targets, Windows subtype/privilege behavior | Existing native-link suite plus measured artifact-gate capability |
| AR-PARENT-001 | Parent selected-unit patches preserve unrelated bytes/settings and require acknowledgement | Existing parent/bound-role native suite; canonical/legacy CLI aliases |
| AR-REC-001 | Deterministic fault/restart tests assert restored, recovery-required, cleanup-pending, occupants, and corrupt evidence | Existing lifecycle/parent fault suites; real rare artifact statuses still required |
| AR-STATUS-001 | Real statuses 0, 1, 2, 3, 4, and 7 use correct streams/statuses | Built artifact on every native OS |
| AR-STATUS-002 | Windows holds a real target-file lock during managed replacement; any resulting restored/recovery outcome is recorded. Real statuses 5 and 6 still require reproducible native evidence, not backdoors/races | **Blocker for each status not observed on a capable native job** |
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
4. Obtain real status 5/6 evidence and required Windows true-directory-link
   capability/refusal evidence; do not substitute injected-fault results for
   production-process evidence.
5. Record remaining limits and blockers explicitly. Only an empty mandatory
   blocker set permits changing the readiness decision to qualified.
