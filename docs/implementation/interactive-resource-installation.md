# Interactive resource installation implementation report

Baseline: `b251028` on `openhands/implement-interactive-installation-kimi`.
Authoritative specification: `docs/specs/interactive-resource-installation.md`.

This file is a durable resume aid. Checkboxes mean verified implementation, not merely scaffolded code.

## Agreed verification seams

- Real production command tree through `Executor.fake`, with injected interaction/acquisition dependencies and real isolated temporary filesystems.
- Public typed catalog and lifecycle/state transaction operations.
- Built executable stdout/stderr/status checks.
- Focused native-link, acquisition budget/privacy, fault/recovery, and terminal tests.

## Seven implementation slices

- [x] 1. Typed inputs/catalog and parser contract.
- [ ] 2. Local planning and Clix interactions (planning and stock-Clix wiring compile; required Select All, graceful cancellation/EOF, and terminal restoration are not provided by stock Clix 1.2.0).
- [x] 3. Resource-unit publication (initial coordinated install/no-op/rollback path; restart recovery expansion remains slice 6).
- [x] 4. Canonical lifecycle completeness.
- [x] 5. Remote acquisition.
- [x] 6. Batch fault/cancellation proof.
- [ ] 7. Public migration and qualification (migration and non-interactive gates are implemented; the stock-Clix interaction contract is a release blocker).

## Architecture invariants

- Separate concrete `skill install` and `agent install` commands; no root install alias, universal resource manager, second installer, or borrowed Vercel pipeline.
- Amended after repository-discovery feedback: curated `agent-resources.toml` stays authoritative; exact resources are explicit. Skill collections without a catalog use bounded conventional-folder discovery (see spec §3); Agents remain curated/exact-file only. No implicit dependencies.
- Existing lifecycle/state service remains the sole transaction/recovery authority.
- Canonical skills own content plus tracked exposures; copies and source links remain distinct. Agents remain native file copies.
- Mamba owns delivery. Successful text/JSON is returned; aggregate handled failures throw `MambaException`.
- Production Chalk coloring remains enabled. `.pi/settings.json` and `.pi/multi-pass.json` stay local and uncommitted.

## Verification log

- Baseline `dart test`: 317 passed, 4 pre-existing Windows permission skips.
- `dart analyze`: no issues after slices 1–3.
- Historical pre-removal focused Clix patch analysis: no issues. This evidence does not apply to the current stock-Clix dependency.
- Checkpoint `dart test`: 380 passed, 4 pre-existing Windows permission skips.
- `test/cli_process_test.dart`: production streams/status/color and schema-v2 lifecycle smoke passed on Windows.
- Real canonical directory-link creation and mid-publication rollback passed in isolated temporary filesystems.
- Resume baseline: the preserved canonical draft initially had six compile errors; after minimal compile repairs, the full suite independently passed 380 tests with the same four Windows skips.
- Slice 4: canonical list/replace/detach/remove/backup/restore, versioned record and backup validation, true no-op revalidation, and schema-v2 coordinated restart rollback/completion passed in `resource_unit_transaction_test.dart` (9 tests).
- Slice 5: 12 acquisition tests passed for local sources, inert immutable Git archive materialization, bounded HTTP, ZIP/TAR/TAR.GZ, redirects/privacy, duplicate/path/special-entry refusal, deadlines, and cleanup. `archive: 4.0.7` is pinned and its decoder callback is used so duplicate entries cannot be silently deduplicated before validation.
- Slice 6 focused scheduler tests pass for independent continuation, dependency skipping, recovery-required stop, and post-write interruption. The 15-test resource-unit matrix also covers verified-old commit rollback (5), committed/uncertain recovery (6), terminal-journal failure, new occupants, stale exposures, committed cleanup, and fresh-service rollback/completion.
- The rebuilt Windows production release gate observed statuses 0 through 7 with zero blockers, including real read-only-ledger rollback, protected cleanup evidence, and canonical content/exposure publication. It was rerun with `--require-qualified` after final review fixes.
- Final local qualification: `dart pub get --enforce-lockfile`, formatting, and `dart analyze` passed; the full suite passed 410 tests with 4 pre-existing Windows permission skips.
- Independent coordinator reverification on the committed checkpoint: formatting and analysis passed; the full suite passed 410 tests with the same 4 Windows skips; the rebuilt Windows artifact gate observed statuses 0 through 7 with `Qualified: true; blockers: 0`.
- Independent built-artifact smoke found and fixed two uncovered source-boundary defects. A direct downloaded/local `SKILL.md` was accepted as an exact Skill but failed preflight because inspection received the file rather than its single-file staging directory; exact-file Skill planning now uses that directory and a regression proves only `SKILL.md` is installed. HTTP content encoding was also written compressed to disk; `HttpClient` now decodes transport compression and the decompressed byte stream remains bounded. A local HTTP gzip regression and a real HTTPS dry-run against a public `raw.githubusercontent.com` Skill both pass.
- After those fixes: formatting and analysis passed, the full suite passed 412 tests with 4 pre-existing Windows permission skips, and the rebuilt Windows artifact gate again observed statuses 0 through 7 with zero blockers.
- Native CI then exposed and the coordinator fixed four release/test-harness issues: macOS `/var` versus `/private/var` process-sandbox paths, CRLF-sensitive lockfile evidence hashing, macOS's version string not naming macOS (native identity now comes from the explicit OS field), and the pre-existing agent-edit test sharing the user lifecycle coordination lock. Each has focused coverage or was reverified by the native suite.
- Integrated CI qualification at revision ec48558: [workflow run 40745695510](https://github.com/louiss0/agent_resource/actions/runs/40745695510). Windows, macOS, and Linux native jobs all passed with `--require-qualified`; the release-decision job passed. Its decision reports `qualified: true`, no blockers, statuses 0 through 7, and runtime activation/equivalence explicitly unverified.
- HTTPS credential forwarding and real TLS Git integration were not exercised; local plaintext HTTP and Git-daemon fixtures covered the protocol-independent bounds and redaction logic. A public HTTPS direct-file download was exercised without credential forwarding.

### Current stock-Clix removal and interaction blocker

The vendored `third_party/clix` fork and its dedicated patch-behavior tests are removed. The application now uses hosted `clix: 1.2.0` with Mamba 1.0.0 and no dependency override. Fork-only `CliPromptCancelledException` and `CliInputClosedException` references are removed; no replacement prompt library, shim, fork, or Cancel option was introduced.

Application-owned prompt labels include the literal `(Ctrl+C to cancel)` hint. With stock Clix this is only guidance for an external process interrupt. It does not perform graceful cancellation, restore terminal modes, or return `InteractionAnswer.cancelled`. Stock `MultiSelect` has no Select All action, does not map Escape or Ctrl+C to typed cancellation, can continue looping on EOF, and restores echo/line modes only through its normal `finally` path. The approved interaction contract is therefore not implemented by the current stock dependency, and real PTY qualification cannot be claimed.

Stock-Clix removal verification: formatting and analysis passed; 56 focused installation/workflow tests passed; the full suite passed 407 tests with 4 pre-existing Windows permission skips; and the rebuilt Windows artifact gate observed statuses 0 through 7. The dedicated fork component suite was deleted. These tests use scripted interaction adapters or unattended commands and do not prove raw stock-Clix prompt safety.

## Review findings and resolutions

Two independent reviews ran against baseline `b251028` after commit `d1a53a4`.

- Spec: single-offering catalogs now always use the resource MultiSelect interaction; no silent lone-item selection remains.
- Spec/Standards: consumer-only Codex additions now commit direct-consumer metadata without rewriting canonical content.
- Spec: general preflight errors retain status 1 rather than being reclassified as ownership refusals.
- Spec: unchanged-unit failures enter the same aggregate outcome and continuation policy as other units.
- Spec: HTTP uses an overall deadline timer that forcibly closes stalled redirect/download IO.
- Standards: redirected archives pass the resolved URL format explicitly to the decoder; a redirect-to-ZIP regression is covered.
- Standards judgement call: the two thin domain-facing MultiSelect wrappers share similar mapping code but retain their distinct typed candidate/target contracts; this was not a correctness finding.
- Independent coordinator regression fixes: exact single-file Skill planning and HTTP transport decompression now have focused tests and were rechecked by the full suite and built-artifact gate.

All actionable review findings have regression coverage and were rechecked by the final full suite and built-artifact gate.

## Remaining platform/release evidence

The stock-Clix interaction limitations above are implementation blockers, not merely missing platform evidence. Earlier integrated native-CI results were produced with the removed fork and changed lockfile, so they do not qualify the current candidate. Real Windows/macOS/Linux PTY behavior and HTTPS/TLS credential-boundary integration remain unverified. Non-interactive built-artifact and lifecycle evidence does not establish Select All, graceful cancellation/EOF handling, or terminal restoration.
