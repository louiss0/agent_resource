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

## Audit findings → evidence

Every actionable finding in `docs/product-audit.md` carries a stable
`PA-x.y` identifier (HTML comment markers). This table maps each finding
to the ticket that resolved it, the focused regression tests that guard
the fix, and its status. `test/release_qualification_test.dart` fails if
any audit ID is missing here or any referenced test name disappears.

| Finding | Ticket | Focused evidence (test file — test name) | Status |
| --- | --- | --- | --- |
| PA-1.1 | #134 | `test/resource_lifecycle_boundaries_test.dart` — `has no registered command`; `test/support_test.dart` — `prompt help discloses the real install routes` | intentional boundary |
| PA-1.2 | #134 | `test/pack_test.dart` — `installs both resource types through the real service`; `test/prompt_read_test.dart` — `Pi template validation is recognized but installation stays unsupported` | intentional boundary |
| PA-1.3 | #130 | `test/skill_install_test.dart` — `publishes a derived prompt template with the skill`; `test/src/services/pack_lifecycle_service_test.dart` — `--prompt-target publishes the pi template` | resolved |
| PA-1.4 | #134 | `test/prompt_create_command_test.dart` — `refuses a managed Prompt without falling back to author-only` | intentional boundary |
| PA-1.5 | #134 | `test/support_test.dart` — `context help explains the one-shot injection boundary` | intentional boundary |
| PA-1.6 | #134 | `test/mcp_test.dart` — `states the static verification boundary in text and JSON`; `test/support_test.dart` — `mcp help discloses the static-check boundary` | intentional boundary |
| PA-1.7 | #134 | `test/mcp_lifecycle_test.dart` — `Claude user/local mutations are refused for every operation` | intentional boundary |
| PA-2.1 | #128 | `test/skill_install_test.dart` — `direct and pack previews disclose the same configured defaults and origins` | resolved |
| PA-2.2 | #126 | `test/config_test.dart` — `shows default settings with explicit paths and origins` | resolved |
| PA-2.3 | #126 | `test/config_test.dart` — `labels XDG_CONFIG_HOME as the user config origin`; `test/skill_install_test.dart` — `unattended plan reports explicit origins in JSON` | resolved |
| PA-2.4 | #126 | `test/config_test.dart` — `reports discovered paths and layered origins as JSON` | resolved |
| PA-2.5 | #126 | `test/config_test.dart` — `shows explicit target and method origins` | resolved |
| PA-2.6 | #126 | `test/config_test.dart` — `previews safe changes without writing configuration` | resolved |
| PA-2.7 | #128 | `test/config_test.dart` — `applies eligible preferences at` | resolved |
| PA-2.8 | #128 | `test/agent_install_test.dart` — `exact unattended dry-run requires and preserves explicit native profile` | resolved |
| PA-3.1 | #127 | `test/guided_profile_cli_test.dart` — `guides the missing native profile` | resolved |
| PA-3.2 | #127 | `test/project_scope_cli_test.dart` — `defaults to project inventory`; `test/skill_install_test.dart` — `interactive installation defaults to project scope` | resolved |
| PA-3.3 | #127 | `test/agent_create_command_test.dart` — `shows the bound-role plan before requesting approval`; `test/skill_install_test.dart` — `reviews a canonical target change before publishing` | resolved |
| PA-3.4 | #132 | `test/context_inject_test.dart` — `refuses destination changes made during approval`; `test/context_inject_test.dart` — `uses the selected harness and template interactively` | resolved |
| PA-3.5 | #127 | `test/pack_action_test.dart` — `does not prompt when stdout is redirected` | resolved |
| PA-3.6 | #135 | `test/application_test.dart` — `root help gives task-oriented first-success guidance` | resolved |
| PA-3.7 | #135 | `test/application_test.dart` — `shows nonempty root help when no arguments are supplied` | resolved |
| PA-3.8 | #135 | `test/application_test.dart` — `root help gives task-oriented first-success guidance`; `test/guided_profile_cli_test.dart` — `guides the missing native profile` | resolved |
| PA-3.9 | #127 | `test/skill_install_test.dart` — `unattended plan reports explicit origins in JSON` | resolved |
| PA-3.10 | #128 | `test/config_test.dart` — `previews safe changes without writing configuration` | resolved |
| PA-3.11 | #127 | `test/context_inject_test.dart` — `refuses a cancelled apply confirmation`; `test/agent_create_command_test.dart` — `shows the bound-role plan before requesting approval` | resolved |
| PA-3.12 | #127 | `test/pack_action_test.dart` — `does not prompt when stdout is redirected`; `test/context_delete_test.dart` — `no usable terminal implies unattended confirmation` | resolved |
| PA-3.13 | #127 | `test/agent_create_command_test.dart` — `prints a replayable guided bound-role command`; `test/context_inject_test.dart` — `prints a quoted explicit command without template content` | resolved |
| PA-4.1 | #131 | `test/skill_install_test.dart` — `canonical inventory follows only its tracked exposure`; `test/prompt_read_test.dart` — `refuses a linked skill marker` | resolved |
| PA-4.2 | #134 | `test/skill_native_view_test.dart` — `inspect reports installation admission separately from native`; `test/src/services/pack_lifecycle_service_test.dart` — `validate separates native validity from installation eligibility` | resolved |
| PA-4.3 | #133 | `test/mcp_lifecycle_test.dart` — `TOML: replacement removes omitted fields and preserves unrelated bytes`; `test/mcp_lifecycle_test.dart` — `replaces stdio with a complete HTTP registration` | resolved |
| PA-4.4 | #133 | `test/mcp_lifecycle_test.dart` — `encodes Codex HTTP environment references natively`; `test/mcp_lifecycle_test.dart` — `forwards a Codex stdio environment variable by name`; `test/mcp_lifecycle_test.dart` — `refuses credential references containing literal defaults` | resolved |
| PA-4.5 | #132 | `test/context_inject_test.dart` — `refuses destination changes made during approval`; `test/context_inject_test.dart` — `refuses a stale plan after target drift` | resolved |
| PA-4.6 | #132 | `test/src/services/context_injection_service_test.dart` — `compensates an earlier write when a later target fails`; `test/src/services/context_injection_service_test.dart` — `preserves an independently changed published target on failure`; `test/src/services/context_injection_service_test.dart` — `reports retained recovery when compensation also fails` | resolved |
| PA-4.7 | #132 | `test/src/services/context_injection_service_test.dart` — `refuses a linked intermediate destination directory`; `test/src/services/context_injection_service_test.dart` — `refuses a Windows junction in a Context destination` | resolved |
| PA-5.1 | #135 | `test/documentation_test.dart` — `the harness matrix matches the catalog`; `test/documentation_test.dart` — `the lifecycle matrix matches the boundary contract` | resolved |
| PA-5.2 | #135 | `test/documentation_test.dart` — `every fenced agent-resource invocation resolves and parses`; `test/application_test.dart` — `root help gives task-oriented first-success guidance` | resolved |
| PA-5.3 | #135 | `test/documentation_test.dart` — `every docs/specs document carries the banner` | resolved |

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
