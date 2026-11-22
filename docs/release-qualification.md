# First-release qualification and readiness

## Readiness decision

**Not qualified for release.** This document is the evidence index and
blocker list referenced by `README.md` and `docs/releasing.md`. Green
tests, a green local built-executable gate, or a successful help smoke
test is not a release decision.

The evidence below describes executable behavior built from commit
`60f97db44fe82b0626f27a3d297b738714b74e0c` on Dart 3.13.2. Any source,
SDK, lockfile, or executable change requires fresh evidence. The local
`build/release-evidence.json` has `revision: local-working-tree` and no
CI job provenance, so it is a native-job result only. It cannot be
submitted to the integrated release decision aggregator.

## Current local evidence

| Check | Result |
| --- | --- |
| `dart analyze` | No issues found. |
| `dart format --output=none --set-exit-if-changed lib bin test` | 205 files checked; none changed. |
| `dart test` | 1,322 passing; 5 platform-conditional skips. |
| `dart compile exe bin/agent_resource.dart -o build/agent_resource.exe` | Windows executable built; SHA-256 `ae01628959611cc05c5efbf8c572922a7a2941dd2c54e5021b0278131110eab1`. |
| `test/support/release_gate.dart ... --require-qualified` | Windows native-job `qualified: true`; 0 blockers. |
| Built-production statuses | Real statuses 0, 1, 2, 3, 4, 5, 6, and 7 observed. |
| Native links | True directory-symlink creation observed. |
| HTTPS Git acquisition | Real Git smart HTTPS against a fixture-local certificate authority; certificate verification enabled; synthetic credentials. Authenticated success and wrong credentials, untrusted certificate, hostname mismatch, cross-origin redirect, and HTTPS-downgrade refusals were observed. |
| Privacy | Raw native documents, streams, HTTP requests, and credentials are not retained in the evidence bundle. |

The five skipped tests are platform-capability skips on this Windows
runner, chiefly symlink, permission, and editor/PTY-sensitive cases.
They must be reviewed on capable Linux/macOS runners or a suitably
configured Windows runner; a Windows-only full-suite result does not
discharge cross-platform verification.

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
4. The five Windows platform skips have not been reviewed on the other
   native platforms.
5. Final human approval has not been recorded in this document.

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
