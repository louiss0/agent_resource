# Handoff

## Tests that are failing

- None in the latest full run: `dart test --concurrency=2 --reporter expanded` passed with 1,756 passed and 5 skipped. `dart analyze` also passed.
- An earlier full run had six Context tests using the old unattended invocation and one agent-list subprocess timeout. The fixtures now provide an explicit scope; the timeout passed on isolated rerun. The subsequent full run passed.

## What bugs are present

- #127 is incomplete: project-first scope and guided interactions have not been audited or implemented across all resource creation, inventory, and installation workflows. The partial changes are in commit `b0ce84f` and require review against the ticket.
- Product-audit findings remain to be verified and addressed by the tickets below; do not assume a finding is independently reproduced without a regression test. The audit is currently an untracked file in the original checkout at `C:/Users/bvlou/projects/agent_resource/docs/product-audit.md` and is not included in this branch.
- Configuration recovery coordinates through existing lifecycle scope and target-local locks, not a machine-wide cross-user lock. Do not reintroduce the latter.

## What to do next

1. Continue #127 on `ticket/127-project-first-scope`; use the current directory as project context when there is no Git marker, as the user chose. Finish the acceptance criteria and tests, review, then merge into `integration/resource-workflows-125`. The integration branch already contains the #126 implementation; it has not been merged to main and GitHub issues remain open.
2. Wait for upstream PR #124 to be merged before starting work blocked by #118–#123; do not merge that PR yourself without authorization. Refresh ticket and PR status first.
3. Implement the remaining task graph, using the issue bodies as the source of acceptance criteria:
   - #125 capability/provenance contracts (blocked by #118, #121).
   - #128 consistent installation preferences (blocked by #125, #126, #127).
   - #129 route replay and migration (blocked by #125, #128).
   - #130 derived Skill Prompts (blocked by #125, #128, #129).
   - #131 canonical exposure inventory (blocked by #125, #121).
   - #132 Context publication safety (blocked by #119).
   - #133 declarative MCP replacement (blocked by #120).
   - #134 validation and lifecycle boundaries (blocked by #125, #129, #130, #133).
   - #135 first-success documentation (blocked by #127, #130, #132, #133, #134).
   - #136 release qualification (blocked by #127, #129–#135).
4. After all tickets are integrated, run the requested code review and fix findings, complete qualification, resolve tickets through the tracker, and clean up ticket worktrees. Follow `docs/agents/issue-tracker.md` and the project `AGENTS.md` instructions.
5. The original `main` checkout has pre-existing changes to `README.md` and untracked `docs/adr/`, `docs/product-audit.md`, and `docs/release-qualification.md`. Preserve them; they were not included in this handoff.
