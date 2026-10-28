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
- [x] 2. Local planning and Clix interactions (scripted component coverage complete; real terminal qualification remains slice 7).
- [x] 3. Resource-unit publication (initial coordinated install/no-op/rollback path; restart recovery expansion remains slice 6).
- [x] 4. Canonical lifecycle completeness.
- [x] 5. Remote acquisition.
- [x] 6. Batch fault/cancellation proof.
- [x] 7. Public migration and qualification (local Windows implementation gates complete; external platform/terminal/TLS evidence remains explicitly open).

## Architecture invariants

- Separate concrete `skill install` and `agent install` commands; no root install alias, universal resource manager, second installer, or borrowed Vercel pipeline.
- Curated `agent-resources.toml` only; exact resources are explicit. No heuristic scanning or implicit dependencies.
- Existing lifecycle/state service remains the sole transaction/recovery authority.
- Canonical skills own content plus tracked exposures; copies and source links remain distinct. Agents remain native file copies.
- Mamba owns delivery. Successful text/JSON is returned; aggregate handled failures throw `MambaException`.
- Production Chalk coloring remains enabled. `.pi/settings.json` and `.pi/multi-pass.json` stay local and uncommitted.

## Verification log

- Baseline `dart test`: 317 passed, 4 pre-existing Windows permission skips.
- `dart analyze`: no issues after slices 1–3.
- Focused Clix patch analysis: no issues.
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
- HTTPS credential forwarding and real TLS Git integration were not exercised; local plaintext HTTP and Git-daemon fixtures covered the protocol-independent bounds and redaction logic. A public HTTPS direct-file download was exercised without credential forwarding.

macOS/Linux and real terminal/PTY checks remain outstanding and are not inferred from these results.

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

Windows is available locally. macOS and Linux native checks require separate runners and must not be inferred from Windows or skipped tests. Real Windows/macOS/Linux PTY terminal-mode restoration and HTTPS/TLS credential-boundary integration remain unrun. Local plaintext HTTP and Git-daemon fixtures do not close those release-qualification blockers.
