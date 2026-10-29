# Repository Skill discovery: research recovery and contract correction

## Existing research

The report for [issue #36](https://github.com/louiss0/agent_resource/issues/36)
was completed on a separate research branch, but is not present in the current
main checkout. Its [resolution comment](https://github.com/louiss0/agent_resource/issues/36#issuecomment-6455023043)
links the [complete pinned report](https://github.com/louiss0/agent_resource/blob/d1cbc927861ef3d5c7b19818e79c90c1ab3d5e94/docs/research/interactive-install-baseline.md).
That report was retrieved and read for this correction; no new upstream
execution or full Vercel compatibility claim is implied.

The report pins Vercel Skills source to
`d8eca76d5dbe47df2d146d036e32534b74ece57a` (source package version 1.7.4).
Its “Source parsing is not discovery, and neither is installation” section
establishes:

- GitHub shorthand and repository URLs are parsed as repository sources.
- Source resolution/fetching precedes Skill discovery.
- Discovery checks exact `SKILL.md` and metadata, prioritizes root Skills,
  `skills/` and harness-specific containers, and supports bounded recursion.
- Vercel also has manifest paths, internal-Skill filtering, lock-based
  suppression, duplicate handling and full-depth/fallback policies. These are
  observations, not automatically Agent Resource requirements.

Primary sources linked by the report:
[source parser](https://github.com/vercel-labs/skills/blob/d8eca76d5dbe47df2d146d036e32534b74ece57a/src/source-parser.ts),
[discovery](https://github.com/vercel-labs/skills/blob/d8eca76d5dbe47df2d146d036e32534b74ece57a/src/skills.ts),
[resolution/install flow](https://github.com/vercel-labs/skills/blob/d8eca76d5dbe47df2d146d036e32534b74ece57a/src/add.ts).

## What happened in our specification

The research did not omit repository discovery. The later curated-installation
spec deliberately excluded it. Commit `b251028` introduced the installation
spec with these requirements:

- “inspect only the selected root/entry, not a tree scan” (§3).
- “Missing markers are not permission to search elsewhere” (§3).
- “Source catalogs exclude heuristic discovery” (§11).

The implementation report likewise said “Curated `agent-resources.toml` only”
and “No heuristic scanning”. Thus the observed behavior followed the written
contract, but that contract did not satisfy the requested repository-install
workflow. There is no basis here to claim the research required this exclusion.
The GitHub URL misclassification additionally made the error misleading.

## Adopted correction

The installation spec §3 now permits bounded discovery of Skill collections
within the already-acquired source root. Conventional folders are searched
recursively, with selected-tree fallback if none exists. IDs are deterministic
source-relative paths, not fabricated catalog IDs. Curated manifests remain
authoritative; explicit exact-resource intent never scans. Selected candidates
still undergo existing validation and full batch preflight before publication.

This adopts Vercel's separation of parsing, acquisition and discovery, not its
installer architecture, overwrite behavior, automatic selections, deduplication,
or tracking model. Agent Resource retains explicit unattended selection,
managed ownership, retained backups, and fail-closed traversal budgets.
See [the amended contract](../specs/interactive-resource-installation.md) and
[public usage](../../README.md) for the exact supported roots and limits.
