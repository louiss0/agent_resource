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
- [ ] 4. Canonical lifecycle completeness.
- [ ] 5. Remote acquisition.
- [ ] 6. Batch fault/cancellation proof.
- [ ] 7. Public migration and qualification.

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

macOS/Linux and real terminal/PTY checks remain outstanding and are not inferred from these results.

## Review findings and resolutions

Pending final two-axis review against baseline `b251028`.

## Remaining platform/release evidence

Windows is available locally. macOS and Linux native checks require separate runners and must not be inferred from Windows or skipped tests.
