# Read-only project skill discovery

> **Research-audit amendment — current command tree and scope.** This amendment supersedes the earlier root-level action-command hierarchy and stale direct invocation examples in this specification. Production exposes `skill` and `agent` groups under `agent_resource`. The `skill` group has `discover`, `inspect`, and `validate` children and no root-level aliases. Invoke this feature as `agent_resource skill discover ...`; root help lists both groups, while `agent_resource skill --help` lists the child commands. Existing tests stay in `test/` and assert the command path `agent_resource` → `skill` → `discover`; process-isolation snapshots initialize all working, home, configuration, and temporary directories before comparison. Compare names, types, and bytes, not access timestamps: read-only behavior does not claim that SDK/filesystem reads cause no physical access-time updates.
>
> The `.agents/skills`, `.claude/skills`, and `.codex/skills` destinations are explicit Agent Resource search conventions. `.agents/skills` labeled `shared` is not a universal multi-harness guarantee; `.codex/skills` is a legacy compatibility scan, not the current documented universal Codex root. Discovery does not claim native precedence or runtime visibility. Lookup is fail-closed: a missing destination is empty only after its parent listing positively confirms absence; lookup or scan failures reject the invocation rather than returning an incomplete inventory. The supported assumption is a trusted, stable local root, not resistance to hostile concurrent replacement.

## Problem Statement

A developer needs to see which skill candidates exist in a selected project without modifying resources, adopting installations, or assuming a harness discovers every location. Agent Resource currently provides only help and version reporting.

## Solution

Add `skill discover --project <directory>` to report discovery occurrences from that project's shared, Claude-specific, and Codex-specific skill destinations. Return deterministic JSON with location, project installation scope, destination, and the presence of a regular SKILL.md file. Discovery establishes neither validity nor management ownership or consuming-harness compatibility.

## User Stories

1. As a developer, I want to explicitly select a project, so that discovery cannot accidentally scan a different working directory.
2. As a developer, I want shared skill candidates listed, so that I can inspect the shared destination.
3. As a developer, I want Claude-specific candidates listed separately, so that destination is not confused with compatibility.
4. As a developer, I want Codex-specific candidates listed separately, so that all three agreed destinations are represented.
5. As a developer, I want each occurrence's absolute path, so that identically named candidates remain distinguishable.
6. As a developer, I want project installation scope recorded, so that scope is independent of destination.
7. As a developer, I want SKILL.md presence reported, so that incomplete candidates remain visible without being called valid.
8. As a developer, I want malformed marker contents left uninterpreted, so that discovery is not mistaken for validation.
9. As a script author, I want deterministic JSON, so that I can consume results without parsing terminal tables.
10. As a script author, I want missing destination directories to produce an empty result, so that newly created projects are supported.
11. As a script author, I want invalid project selections rejected, so that configuration mistakes are visible.
12. As a developer, I want ordinary files ignored as candidates, so that unrelated files do not become resources.
13. As a developer, I want linked entries excluded without following their targets, so that this bounded scan stays inside the selected project's real directory entries.
14. As a developer, I want same-name candidates retained at different destinations, so that location-based identity is preserved.
15. As a developer, I want nested directories left unsearched, so that discovery is predictable and bounded.
16. As a developer, I want discovery to leave contents unchanged, so that inspection is safe for unmanaged resources.
17. As a developer, I want scan failures reported without partial success output, so that automation cannot mistake incomplete results for a complete inventory.
18. As a developer, I want help to explain discovery's limits, so that I do not infer adoption, validation, or harness support.

## Implementation Decisions

- Register `discover` as a child of the `skill` group using the existing shared executor and the required Mamba command generator. Do not register a root-level discover alias.
- Require named `--project` input. No implicit current-directory or home-directory selection. Resolve relative input against invocation working directory; emit normalized absolute lexical paths without canonicalizing candidate targets.
- A selected project must exist as a directory. An explicitly selected project root may itself be a directory link; exclusions below apply below that selected boundary.
- Scan only immediate directory candidates at `.agents/skills`, `.claude/skills`, and `.codex/skills`, corresponding respectively to destination values `shared`, `claude`, and `codex`.
- This is an explicit product search convention, not a harness profile or discovery compatibility claim. Do not infer consuming-harness relationships.
- Each success is a JSON object with exactly one key, `occurrences`, holding an array. Every occurrence has exactly `path` (absolute string), `destination` (one of the three values above), `installationScope` (`project`), and `hasSkillFile` (boolean).
- Include every immediate ordinary directory candidate, even without SKILL.md. The marker boolean is true only for an ordinary file with exact filename `SKILL.md`; links and directories at that name count as false. Do not read or parse marker contents. Filename case sensitivity follows the filesystem; do not invent case-insensitive matching.
- Fixed output order: shared destination, Claude-specific destination, Codex-specific destination; then Dart string lexicographic order of candidate basenames within each destination. Do not deduplicate by resource name or content.
- Ignore ordinary files at candidate level. Ignore links/junctions below the selected project boundary, including links at the harness-directory, skills-directory, candidate-directory, or marker positions. Do not recurse into candidate contents for discovery.
- A missing expected destination directory is empty only after listing its parent directory and positively confirming that the expected entry is absent. An ordinary file occupying a required harness-directory or skills-directory position is a user-facing error. Parent lookup/listing and other filesystem access failures fail the whole invocation; never emit a partial success object or incomplete inventory.
- Read-only is an application behavior, not an operating-system sandbox guarantee: create no resources, records, caches, backups, or network clients. No adoption, validation, linting, compatibility certification, or mutation plan is performed.
- Return successful JSON through Mamba; throw user-facing MambaException for domain/filesystem failures. Use intrinsic help and parser rejection rather than implementing another parser.
- Extend contributor documentation with real syntax, JSON fields, scan conventions, exclusions, and explicit non-claims. Existing foundation help tests must now allow the implemented discover command while continuing to reject unimplemented workflow advertising.
- Reuse the command-level executor seam with real temporary project fixtures. Add only a small production process check; do not create a second fake-adapter suite.

## Testing Decisions

Test observable command results and filesystem state, not private methods or traversal implementation. Use the shared executor's fake adapter with fresh temporary projects and complete success/failure result assertions. Group tests according to the Mamba command tree: `agent_resource` → `skill` → `discover`; no root-level discover test path or alias. Existing foundation tests and process helpers are prior art. Initialize all process working, home, and configuration directories before full snapshots; compare names, types, and bytes rather than access timestamps, and do not claim that SDK/filesystem reads cause no physical timestamp updates. The user approved this command-level filesystem seam when selecting the bounded discovery scope.

The following are 15 acceptance checks per feature area, not a demand for 45 separate test functions. Related checks may share one invocation.

### Feature 1: Command and output contract — 15 checks

1. Root help advertises the `skill` group, not a root-level discover alias.
2. `skill --help` lists discover, inspect, and validate; discover help describes project-local skill discovery.
3. Discover help exposes the required project option.
4. Discover help succeeds without providing a project.
5. Omitting the project input is rejected with nonzero status and useful diagnostic.
6. A project option without a value is rejected.
7. An unknown discovery option is rejected.
8. Unexpected positional input is rejected.
9. A nonexistent project is rejected with a project-related diagnostic.
10. An ordinary file selected as project is rejected.
11. An empty project succeeds with an empty occurrences array.
12. Success parses as JSON with exactly the specified top-level key.
13. Every occurrence has exactly the specified fields and value types.
14. A production discover invocation agrees with the fake result after decoding JSON and uses stdout with zero status and empty stderr.
15. A production invalid project invocation fails with nonzero status, stderr diagnostic, and no partial JSON on stdout.

### Feature 2: Enumeration and reporting — 15 checks

1. A shared-destination directory is reported.
2. A Claude-specific directory is reported.
3. A Codex-specific directory is reported.
4. Each occurrence has the correct destination label.
5. Each occurrence reports project installation scope.
6. Each reported path is absolute and points to the candidate directory, not its marker.
7. Candidate paths normalize lexical dot segments in project input.
8. A regular SKILL.md file sets hasSkillFile true.
9. An absent SKILL.md sets hasSkillFile false without removing the candidate.
10. A directory called SKILL.md sets hasSkillFile false.
11. Malformed SKILL.md contents still count as file presence, not validation failure.
12. Ordinary files directly inside a skills directory are ignored.
13. Same-name candidates at multiple destinations remain distinct occurrences.
14. Destination ordering is fixed and candidate basenames are lexicographically sorted, independent of creation order.
15. A candidate containing a nested apparent skill produces no extra nested occurrence.

### Feature 3: Safety, boundaries, and failure isolation — 15 checks

1. Missing all expected scan directories succeeds only after parent listings positively confirm each absence, without creating them.
2. Missing only some destinations is positively confirmed from parent listings and does not hide candidates in existing destinations.
3. An ordinary file at a harness-directory position fails clearly.
4. An ordinary file at a skills-directory position fails clearly.
5. A directory link at a harness-directory position is skipped without scanning its target.
6. A directory link at a skills-directory position is skipped without scanning its target.
7. A directory link at a candidate position is skipped without scanning its target.
8. A linked SKILL.md is not treated as an ordinary marker file.
9. A candidate containing a link cycle does not cause recursion or a hang.
10. Discovery preserves seeded project entry names, types, file bytes, and link targets.
11. Discovery preserves external link-target sentinel contents.
12. A failed invocation preserves the same project sentinels.
13. Repeating discovery through one adapter yields equivalent JSON without accumulating occurrences.
14. A failed project scan followed by a valid scan succeeds without stale failure state.
15. Results contain no validity, management ownership, or consuming-harness compatibility claims.

Link cases must explicitly skip with a reason where OS permissions cannot create links; never silently mark them tested. Do not require privileged permission changes to simulate access failures on Windows. Cover positive parent-listing absence confirmation and filesystem failure translation with reliably reproducible invalid entry layouts; an operational lookup failure must reject rather than produce an incomplete inventory. Inspect catch boundaries for other I/O errors. Compare state rather than access timestamps. Apply finite subprocess timeouts and unconditional fixture cleanup. Run focused tests throughout, static analysis regularly, full suite and formatting at the end, then independent standards/spec reviews before committing.

## Out of Scope

- User-wide installation scope or implicit home-directory scanning.
- Resources other than skills, including agent definitions, prompts, context, plugins, and MCP server configuration.
- Recursive workspace scanning, links as discoverable occurrences, following candidate links, file watching, or manifests.
- Skill content parsing, validation profiles, linting, origin inference, managed installation detection, adoption, and mutation.
- Harness profiles or claims that a native harness actually consumes any listed occurrence, including precedence or runtime visibility claims.
- Output tables, filtering, JSON schema versioning, and interactive project selection.
- Filesystem atomicity or protection against concurrent malicious directory replacement; the scan is observational, not a secured sandbox.

## Further Notes

This follows the CLI foundation milestone. The user explicitly selected read-only discovery and approved the three project-local destinations and temporary-filesystem command seam. JSON and detailed exclusion/error semantics are implementation choices for this small slice, not claims about native harness behavior. The research audit further requires positive parent-listing confirmation for absence and fail-closed operational errors: an unreadable lookup refuses to present a partial inventory. The destination labels remain product conventions (`.agents/skills` is not a universal shared root; `.codex/skills` is a legacy compatibility scan), and the trusted stable-local-root assumption does not provide hostile-race resistance.

Use openai/gpt-5.6-luna for subagents unless a later explicit model choice changes that instruction. Preserve unrelated untracked setup files and commit only intended feature changes to the current branch after verification and review.
