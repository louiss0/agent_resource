# First-release qualification and readiness

## Readiness decision

**Not qualified for release — pending CI on the release commit.** This
document is the evidence index and blocker list referenced by
`README.md` and `docs/releasing.md`. Green tests, a green local
built-executable gate, or a successful help smoke test is not a release
decision.

The decision is **conditional**: it becomes *qualified* only when the CI
`workflow_dispatch` run for the release commit produces green
release-blocking jobs (`windows-latest`, `ubuntu-latest`) and a
`release-decision` bundle with an empty mandatory blocker set and
`qualified: true`. Until that run exists and is reviewed, the project is
not qualified. Any source, SDK, lockfile, or executable change after
that run requires fresh evidence. A local
`build/release-evidence.json` has `revision: local-working-tree` and no
CI job provenance, so it is a native-job result only and cannot be
submitted to the integrated release decision aggregator.

## Current local evidence

| Check | Result |
| --- | --- |
| `dart analyze` | No issues found. |
| `dart format --output=none --set-exit-if-changed lib bin test` | 205 files checked; none changed. |
| `dart test` | 2,170 passing; 5 platform-conditional skips (itemized below). |
| `dart compile exe bin/agent_resource.dart -o build/agent_resource.exe` | Windows executable built; SHA-256 `ae01628959611cc05c5efbf8c572922a7a2941dd2c54e5021b0278131110eab1`. |
| `test/support/release_gate.dart ... --require-qualified` | Windows native-job `qualified: true`; 0 blockers. |
| Built-production statuses | Real statuses 0, 1, 2, 3, 4, 5, 6, and 7 observed. |
| Native links | True directory-symlink creation observed. |
| HTTPS Git acquisition | Real Git smart HTTPS against a fixture-local certificate authority; certificate verification enabled; synthetic credentials. Authenticated success and wrong credentials, untrusted certificate, hostname mismatch, cross-origin redirect, and HTTPS-downgrade refusals were observed. |
| Privacy | Raw native documents, streams, HTTP requests, and credentials are not retained in the evidence bundle. |

The platform-conditional skips are itemized in the
[Platform-conditional skips](#platform-conditional-skips) table below.
Each skip's condition and the CI operating system that discharges it are
recorded there; a Windows-only full-suite result does not discharge
cross-platform verification on its own.

## Platform qualification

Windows and Linux are release-blocking platforms; macOS runs the same CI
job and is reported best-effort. `dart test` runs the entire suite —
including the filesystem/link-boundary and terminal-behavior tests — on
`ubuntu-latest`, `windows-latest`, and `macos-latest` in
`.github/workflows/ci.yml`, and `test/support/release_gate.dart`
exercises the compiled executable on each runner's real filesystem.

| Boundary | Windows evidence | Linux evidence | macOS evidence |
| --- | --- | --- | --- |
| Symlink creation, inspection, and refusal | `native_link_service_test`, `skill_files_test`, `agent_list_test` link cases; gate's `built-skill-link-install` and `trueDirectorySymlink` | same suites on POSIX symlinks | same suites |
| Windows junctions / reparse points | `context_injection_service_test` — `refuses a Windows junction in a Context destination`; `native_link_service_test` — `distinguishes dangling directory and file links on Windows` | covered by the generic link-refusal cases (junction semantics are Windows-only) | same as Linux |
| Case sensitivity / journal path keys | Windows case-folds action paths (`PathActionDiff`); route-recovery suites build journal rows through the real diff | case-sensitive paths exercised by the same suites | same |
| Linked-ancestor refusal | `context_injection_service_test` — `refuses a linked intermediate destination directory`; route-recovery refusal tests | same; additionally guards symlinked temp ancestors (see below) | `/var`→`/private/var` temp ancestors resolved in tests |
| Cross-root renames | `context_injection_service_test` staging/compensation suites | same | same |
| Terminal detection (stdin AND stdout) | `pack_action_test` — `does not prompt when stdout is redirected`; interactive gating tests | same | same |
| Non-TTY refusal / fallback | `cli_process_test` interactive refusal on redirected stdin; `context_delete_test` — `no usable terminal implies unattended confirmation` | same | same |

Documented boundary: a project root, state root, or Context destination
under a **symlinked ancestor** (macOS `/var` and `/tmp`, distributions
with a symlinked `/home`, or any user-created link) is refused as a
linked coordination authority. Work under real (resolved) directories;
this is an intentional limit, not a bug.

## Platform-conditional skips

The test suite's only platform-conditional skips are capability gates
(`markTestSkipped`) that fire when the runner OS or filesystem lacks the
required capability. Each is discharged — executed for real — on at
least one CI operating system:

| Test | Skip condition | Discharged on |
| --- | --- | --- |
| `test/src/services/native_link_service_test.dart` — `distinguishes dangling directory and file links on Windows` | non-Windows OS, or a Windows filesystem that cannot create true directory symlinks | windows-latest (or a capable Windows runner) |
| `test/src/authoring/editor_platform_test.dart` — `a platform without a documented default text editor action fails clearly` | Windows or macOS (both have a documented default editor action) | ubuntu-latest |
| Symlink-capability tests in `agent_list_test`, `agent_test`, `inspect_test`, `skill_files_test`, `skill_validation_test` ("symlink creation is unavailable") | filesystem cannot create symlinks (e.g. Windows without the link privilege) | ubuntu-latest, macos-latest, capable Windows |
| POSIX permission tests in `agent_list_test`, `agent_test`, `inspect_test`, `skill_validation_test` ("chmod is unavailable") | `chmod` does not exist or fails (Windows) | ubuntu-latest, macos-latest |
| `test/src/services/native_link_service_test.dart` — `inspects a supported directory link and target representation` ("true directory-symlink creation is unavailable") | filesystem cannot create a true directory symlink | ubuntu-latest, macos-latest, capable Windows |

No boundary above depends on a skipped-only path: linked-ancestor
refusals, cross-root renames, case handling, and TTY gates execute on
every CI operating system.

## Evidence classes

`test/support/release_gate.dart` classifies every executed check in the
sanitized bundle with a `verification` class:

- `native` — the behavior ran against the real filesystem/process layer
  on the runner OS (all built-executable scenarios, including the real
  Git smart-HTTPS fixture, are `native`).
- `static` — analysis or declarative validation with no runtime claim
  (used by `mcp validate`/`mcp inspect` output, which state
  `verification: static`; no built-gate scenario is static-only).
- `unverified-live-harness` — behavior that depends on Claude, Codex,
  Pi, or Antigravity actually loading the produced artifacts, which CI
  never runs.

The bundle's `unverifiedLiveHarness` list names those behaviors
explicitly: Skill invocation by the target harness, manual-only Prompt
behavior, MCP server connectivity and credential authentication, and
Context consumption by the harness. `release_decision.dart` rejects a
bundle whose checks lack a verification class or whose live-harness
boundary list is absent or malformed.

## Behavior-to-evidence index

| Area | Local evidence | Remaining limit |
| --- | --- | --- |
| Command help, validation, and process statuses | Full command suites plus built-executable status 0–7 scenarios in `build/release-evidence.json`. | Same-revision native macOS/Linux CI evidence is required. |
| Skill inventory, inspection, install, replace, adopt, backup, and recovery | Full service/command suites and built Skill lifecycle scenarios, including copy, canonical, and source-linked installs. | No harness runtime activation or precedence is certified. |
| Agent inspection, graph readiness, authoring plans, and publication | Full authoring/conversion suites and built create, clone, edit, compose, and parent-setting scenarios. | Runtime model, tool, and permission availability are not certified. |
| All six Claude/Codex/common-Pi conversion directions | Built plan/apply/validate scenarios on Windows and the native conversion suites. | Behavior-lossless conversion and round-trip equivalence are not claimed. |
| Coordinated interruption recovery | Deterministic transaction suites and real Windows built-production statuses 5 and 6. | The integrated decision must verify the capable Windows job's evidence against the other native jobs. |
| Native link ownership and bounded traversal | Native-link suites and the gate's true-directory-symlink capability result. | Windows-specific link subtypes and hostile concurrent filesystem races remain outside the cooperative-local-root trust model. |
| Source acquisition security | `httpsGitQualification` in the gate evidence records certificate verification, credential kind, redirect policy, and six fixture scenarios. | Fixture-local HTTPS does not certify arbitrary public hosts, credential stores, or live accounts. |
| Interactive selectors and confirmations | Scripted adapter and command suites cover unattended and safely redirected-input behavior. | Graceful EOF, complete terminal-mode restoration, long-list rendering, resize behavior, and real Windows/macOS/Linux PTY acceptance remain unverified. |
| Runtime activation and equivalence | Explicitly `false` in the gate evidence. | Native harness activation and behavioral equivalence are not release claims. |

## Evidence protocol

`.github/workflows/ci.yml` runs Dart 3.13.2 on Windows, macOS, and
Linux. Each job enforces `pubspec.lock`, formatting, analysis, the full
suite, a compiled executable, a help smoke test, and
`test/support/release_gate.dart`. Each job uploads only the sanitized
`build/release-evidence.json`. Ordinary push and pull-request jobs
retain evidence; a manual `workflow_dispatch` adds
`--require-qualified`.

The `release-decision` job then runs
`test/support/release_decision.dart` over all three same-revision
bundles. It checks schema and safety fields, CI job provenance, native
OS coverage, SDK and lockfile identity, artifact identity, Windows
directory-link capability, observed statuses 0–7, mandatory blockers,
and valid rare-status deferrals. A per-job `qualified: true` is not an
integrated release verdict.

To regenerate the local Windows evidence:

```text
dart compile exe bin/agent_resource.dart -o build/agent_resource.exe
dart run test/support/release_gate.dart build/agent_resource.exe build/release-evidence.json --require-qualified
```

Use the extensionless `build/agent_resource` path on macOS/Linux. Do
not set CI environment variables locally to manufacture job provenance.

## Current qualification blockers

1. There is no same-revision Windows, macOS, and Linux CI evidence set
   with matching SDK, lockfile, artifact, and CI job provenance.
2. No integrated `release-decision` result exists for the current
   candidate. Local evidence has `revision: local-working-tree`.
3. Real cross-platform PTY acceptance, cancellation/EOF behavior,
   terminal-mode restoration, long-list rendering, and resize behavior
   are not evidenced. Scripted byte streams are not substitutes.
4. Final human approval has not been recorded in this document.

## Release prerequisites

`docs/releasing.md` additionally requires the Homebrew tap, WinGet
fork, protected `release` environment and reviewers, `RELEASE_TOKEN`
secret, and aligned `pubspec.yaml`/`applicationVersion` values. These
are release-process prerequisites, not substitutes for evidence. Tag
creation must not bypass either this readiness decision or the human
approval gate.

## Final approval checklist

1. Run the CI matrix with `workflow_dispatch` on one committed
   revision on Windows, macOS, and Linux.
2. Review every sanitized bundle and the integrated decision; require
   an empty mandatory blocker set and `qualified: true`.
3. Review the PTY evidence and the reason for every platform skip.
4. Record remaining limits explicitly; do not infer runtime activation,
   account/model/tool availability, permission enforcement, universal
   filesystem behavior, or behavior-lossless conversion.
5. Complete the external release prerequisites in `docs/releasing.md`.
6. Record the named human approval and change this decision to
   qualified only after every preceding item is complete.
