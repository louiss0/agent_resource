# Explicit user-wide skill discovery

## Problem Statement

Project-local discovery cannot inventory skills stored in a user's cross-project environment. A developer needs to inspect an explicitly selected home directory without Agent Resource implicitly scanning the running user's actual home or confusing installation scope with destination and harness compatibility.

## Solution

Extend discover with --home as an alternative to --project. Require exactly one selected root. Home-mode discovery reports the same discovery occurrences as project mode, but with installationScope set to user. Preserve read-only behavior, deterministic JSON, bounded traversal, and explicit non-claims.

## User Stories

1. As a developer, I want to explicitly choose a home directory, so that discovery can inspect user-wide skills.
2. As a developer, I want the application to require a selected root, so that it never guesses my home directory.
3. As a developer, I want project and home selection to be mutually exclusive, so that each result has one unambiguous installation scope.
4. As a developer, I want existing project invocations preserved, so that current automation continues to work.
5. As a developer, I want user-wide shared candidates listed, so that cross-project shared storage is visible.
6. As a developer, I want Claude-specific candidates listed separately, so that destination remains independent of scope.
7. As a developer, I want Codex-specific candidates listed separately, so that all agreed destinations are represented.
8. As a script author, I want user installation scope explicitly reported, so that home results are distinguishable from project results.
9. As a script author, I want the existing JSON shape and deterministic ordering preserved, so that the same consumer can handle either scope.
10. As a developer, I want absolute candidate paths, so that identically named occurrences remain distinguishable by location.
11. As a developer, I want incomplete candidates retained, so that discovery is not mistaken for validation.
12. As a developer, I want linked entries excluded without following targets, so that traversal remains bounded beneath the selected root.
13. As a developer, I want missing destination directories treated as empty, so that a new home is valid input.
14. As a developer, I want invalid roots and scan layouts rejected clearly, so that incomplete scans cannot look successful.
15. As a developer, I want discovered contents left unchanged, so that unmanaged resources stay unmanaged and untouched.
16. As a developer, I want environment home variables ignored for selection, so that an explicit home argument is authoritative.
17. As a developer, I want help to explain both modes and their exclusions, so that I do not infer a native harness compatibility guarantee.
18. As a contributor, I want both scopes to share discovery logic, so that their safety and reporting behavior do not drift.

## Implementation Decisions

- Extend the existing discover command rather than adding a parallel root command.
- Require exactly one named option: --project or --home. Supplying neither or both is a parser-level failure with a useful diagnostic. Intrinsic command help succeeds without either. Missing option values, unknown options, and unexpected positionals remain parser failures.
- Use Mamba's declaration relationships for exclusive/required selection, not a second parser. Reject blank selected values at command level before filesystem access.
- There is no implicit current-directory or actual-home selection. Do not read HOME, USERPROFILE, or XDG variables to determine a discovery root. Relative explicitly selected paths resolve against invocation working directory.
- In either mode, normalize the root and returned candidate paths to absolute lexical paths. Explicit root directory links remain permitted; do not canonicalize their returned lexical paths.
- Inspect only immediate actual directory candidates in .agents/skills, .claude/skills, and .codex/skills beneath the selected root, with destination values shared, claude, and codex respectively. These are product search conventions, not a documented or runtime-verified native harness profile.
- Preserve the successful JSON shape: top-level occurrences array, each row containing exactly path, destination, installationScope, and hasSkillFile. Home mode reports installationScope user; project mode continues to report project.
- Preserve ordering: shared, claude, codex; then Dart lexicographic basename order within each destination. Do not deduplicate same-name candidates across destinations.
- Preserve marker semantics: immediate regular SKILL.md file means true; missing marker, directory, or marker link means false. Do not read marker contents, parse frontmatter, or validate resources.
- Preserve exclusions: ordinary candidate-level files ignored; linked harness directories, skills directories, and candidate directories skipped without target traversal; no recursive discovery. Filesystem filename casing follows the host environment.
- Preserve failure semantics: nonexistent or nondirectory selected roots fail with scope-appropriate diagnostics; missing expected destination directories are empty; ordinary files at configured directory positions fail; filesystem access failures fail the whole invocation without partial success JSON.
- Reuse one concrete discovery implementation across scopes, keeping filesystem operations injected through the command composition seam. Do not introduce speculative lifecycle services or management records.
- No filesystem writes or network access. Discovery alone makes no validity, management ownership, origin, or consuming-harness compatibility claim.
- Update help and contributor documentation with both explicit forms, exactly-one selection, user scope value, scan conventions, and exclusions. Keep inspect behavior unchanged.

## Testing Decisions

Use the existing shared executor and real temporary directories as the primary seam. Extend coverage with a separate user-discovery suite rather than duplicating existing project tests. Parameterize parity scenarios where helpful. Keep command groups affiliated with agent_resource and discover only. Use complete Mamba result assertions and small production checks through the existing bounded process helper.

The following are 15 acceptance checks per feature area; combine related assertions into focused tests rather than requiring 45 separate test functions.

### Feature 1: Explicit root selection — 15 checks

1. Root help still advertises discover and inspect.
2. Discover help exposes both root options.
3. Help explains their exactly-one selection contract.
4. Help succeeds without selecting either root.
5. Omitting both roots fails with a selection diagnostic.
6. Supplying project then home fails before running discovery.
7. Supplying home then project fails identically in result category.
8. A home option without a value fails parsing.
9. A blank home value fails at command level.
10. An unknown home-mode option fails parsing.
11. Unexpected home-mode positional input fails parsing.
12. A missing selected home fails with a home-related diagnostic.
13. An ordinary file selected as home fails with a home-related diagnostic.
14. A valid empty home succeeds with an empty occurrences array.
15. Existing explicit project selection continues to succeed and report project scope.

### Feature 2: User occurrences and scope parity — 15 checks

1. Shared candidates beneath the selected home are reported.
2. Claude-specific candidates beneath the selected home are reported.
3. Codex-specific candidates beneath the selected home are reported.
4. Every home occurrence reports installationScope user.
5. Every occurrence retains its correct destination label.
6. Successful JSON has the unchanged exact top-level shape.
7. Each occurrence has exactly the unchanged four fields and expected types.
8. Returned paths are absolute and refer to candidate directories.
9. Relative and dot-segment home inputs produce normalized lexical paths.
10. Regular marker presence reports true without reading contents.
11. Missing/directory markers report false without hiding candidates.
12. Ordinary candidate-level files are ignored.
13. Same-name candidates across destinations remain distinct.
14. Destination and basename ordering is deterministic regardless of fixture creation order.
15. Equivalent project/home fixtures differ only in selected root paths and installation scope, not enumeration or marker semantics.

### Feature 3: Isolation, safety, and delivery — 15 checks

1. An explicit selected home is authoritative even when process HOME/USERPROFILE point elsewhere.
2. A missing root selection never inventories environment-derived home contents.
3. Missing expected destination directories do not get created.
4. A file at a harness-directory position fails without partial output.
5. A file at a skills-directory position fails without partial output.
6. A linked harness directory is skipped without following its target.
7. A linked skills directory is skipped without following its target.
8. A linked candidate directory is skipped without following its target.
9. A linked marker reports false without target decoding.
10. Nested skill-looking directories do not create recursive occurrences.
11. Successful discovery preserves entry names, types, file bytes, and link targets in selected and external sentinel directories.
12. Failed home discovery and rejected dual-root selection preserve sentinels.
13. Reused-adapter home/project/home invocations preserve their correct scope without stale results.
14. Production home discovery returns equivalent decoded JSON on stdout, empty stderr, and zero status.
15. Production invalid selection fails on stderr with nonzero status and empty stdout.

Link-dependent checks explicitly skip with reasons where permissions prevent link creation. Use no privileged permission changes and never inspect the developer's actual home. Production tests redirect home/config variables to disposable fixtures. Compare entries and bytes rather than access timestamps. Preserve bounded subprocess deadlines and unconditional fixture cleanup. Run focused tests during development, analysis regularly, then full tests, formatting, and separate standards/spec review before committing.

## Out of Scope

- Automatic actual-home detection, merging project and home inventories, recursive workspace searches, or scanning multiple supplied homes.
- Alternate custom CLAUDE_CONFIG_DIR/CODEX_HOME conventions or environment-derived roots.
- Harness profiles, official compatibility certification, validation, linting, origin inference, and management ownership detection.
- New resource types, installations, adoption, mutation plans, backups, removal, or other writes.
- Changing inspect output, changing discovery JSON keys, human-oriented tables, and output-schema versioning.
- Securing the scan against concurrent malicious filesystem replacement; this remains an observation-based read-only scan.

## Further Notes

The user selected user-wide discovery after project-local discovery and skill inspection were completed. Explicit --home selection and reuse of the three existing destination conventions keep the slice bounded and avoid implicitly reading the real user environment. Continue with the established command-level temporary-filesystem seam, preserve unrelated concurrent work, and commit intended changes to the current branch. Use openai/gpt-5.6-luna for subagents unless explicitly changed.
