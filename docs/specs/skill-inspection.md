# Read-only skill inspection

> **Research-audit amendment — current command tree and scope.** This amendment supersedes the earlier root-level action-command hierarchy and stale direct invocation examples in this specification. Production exposes `skill` and `agent` groups under `agent_resource`. The `skill` group has `discover`, `inspect`, and `validate` children and no root-level aliases. Invoke this feature as `agent_resource skill inspect --skill ...`; root help lists both groups, while `agent_resource skill --help` lists the child commands. Existing tests stay in `test/` and assert the command path `agent_resource` → `skill` → `inspect`; process-isolation snapshots initialize all working, home, configuration, and temporary directories before comparison. Compare names, types, and bytes, not access timestamps: read-only behavior does not claim that SDK/filesystem reads cause no physical access-time updates.
>
> Inspection reports observations only. The product destination conventions are not native harness guarantees: `.agents/skills` is not universal shared discovery, and `.codex/skills` is retained as a legacy compatibility scan rather than the current documented universal Codex root. Inspection does not claim native precedence or runtime visibility. The supported assumption is a trusted, stable local root; observation-based reads do not resist hostile concurrent replacement.

## Problem Statement

Discovery lists project-local skill candidates but does not let a user inspect one candidate's instructions through Agent Resource. Users need to select a directory and obtain its marker text without modifying it or confusing file presence with validity, management ownership, or harness compatibility.

## Solution

Add `skill inspect --skill <directory>`. Return deterministic JSON describing the explicitly selected directory, whether its immediate SKILL.md is a regular file, and its decoded UTF-8 text when present. Inspection remains read-only and makes no validation claims.

## User Stories

1. As a developer, I want to explicitly select a skill directory, so that inspection never silently targets my current project or home directory.
2. As a developer, I want its normalized absolute path returned, so that I can identify exactly which directory was inspected.
3. As a developer, I want regular SKILL.md presence reported, so that an incomplete candidate can be distinguished from one with instructions.
4. As a developer, I want absent markers represented successfully, so that incomplete candidates can still be inspected.
5. As a developer, I want the marker's text returned without semantic interpretation, so that I can inspect arbitrary native instructions.
6. As a developer, I want empty instruction files preserved as empty strings, so that empty contents are distinct from an absent marker.
7. As a developer, I want Unicode and line endings preserved, so that instruction contents are not silently rewritten.
8. As a developer, I want malformed frontmatter returned as text, so that inspection does not masquerade as validation.
9. As a script author, I want stable JSON fields, so that inspection is easy to automate.
10. As a developer, I want missing or invalid directory selections rejected, so that input mistakes are visible.
11. As a developer, I want malformed UTF-8 rejected clearly, so that returned text is not silently corrupted.
12. As a developer, I want instruction reads bounded in bytes, so that an accidentally huge file cannot cause an unbounded allocation.
13. As a developer, I want linked marker files left unread, so that inspection does not unexpectedly follow a target outside the selected directory.
14. As a developer, I want nested markers ignored, so that inspection has a predictable single-directory boundary.
15. As a developer, I want success and failure to leave files unchanged, so that inspecting unmanaged resources is safe.
16. As a script author, I want failures on stderr with nonzero status and no partial JSON, so that incomplete results cannot look successful.
17. As a developer, I want repeated inspections independent of previous results, so that scripts can reuse one application executor safely.
18. As a developer, I want help to explain limits and non-claims, so that file inspection is not mistaken for validation or adoption.

## Implementation Decisions

- Add `inspect` as a child of the `skill` group through the existing shared executor. Use the project's Mamba command generator and intrinsic parser/help behavior; do not add a root-level inspect alias.
- Require named --skill input; no implicit current-directory selection. Reject blank values, nonexistent selected directories, and ordinary files selected as directories with useful diagnostics.
- Normalize the selected directory to an absolute lexical path. Relative input resolves against the invocation working directory. An explicitly selected root may itself be a directory link; do not canonicalize its returned path.
- Successful JSON has exactly path (string), hasSkillFile (boolean), and content (string or null). No installation scope or destination is inferred from a selected path.
- Check only the immediate exact marker name SKILL.md. Ordinary file means true with decoded text; absence, directory, or link means false with null. Because `typeSync` can report `notFound` for lookup errors, report absence only after a successful parent listing positively confirms the marker is absent. Lookup or parent-listing failures are operational errors, not an absent-marker result. Filesystem case matching follows the host filesystem. Do not recurse or read other entries.
- Decode strict UTF-8 using standard Dart decoding, including its standard leading UTF-8 BOM handling. Preserve text, newlines, trailing whitespace, and lack of final newline; do not trim or parse it.
- Limit reads to 1,048,576 marker bytes. Exactly that many bytes is permitted. Reject larger files with a user-facing diagnostic naming the limit. Bound the actual read to limit plus one bytes rather than relying solely on a size observation, and close the file on all paths.
- Convert filesystem access and decoding failures into user-facing MambaException failures. Emit no partial JSON on failure. Concurrent malicious replacement is not prevented by an observation-based check; do not claim filesystem sandboxing or atomicity.
- Inject the filesystem inspection operation through a focused command callback and wire the concrete operation at composition time. Do not introduce speculative storage frameworks or a service hierarchy.
- No writes, network calls, management records, resource adoption, validation, linting, origin inference, or harness compatibility claims.
- Document real syntax, fields, marker semantics, UTF-8 behavior, byte cap, and link policy. Preserve existing discovery and foundation behavior.

## Testing Decisions

Use the approved command-level filesystem seam: fresh temporary directories exercised through the shared fake executor with complete result assertions. Add small production-process success and failure checks using the existing bounded subprocess helper. Do not duplicate fake suites or test private traversal methods. Test groups mirror actual executor and command names.

These are 15 acceptance checks per feature area; combine related assertions into focused tests rather than manufacturing 45 separate test functions.

### Feature 1: Command and JSON contract — 15 checks

1. Root help advertises the `skill` group, not root-level inspect/discover aliases.
2. `skill --help` lists discover, inspect, and validate; inspect help explains skill inspection.
3. Inspect help exposes the required skill option.
4. Inspect help succeeds without a skill value.
5. Missing skill input is rejected with a useful diagnostic and nonzero status.
6. A skill option without a value is rejected.
7. An unknown inspect option is rejected.
8. Unexpected positional input is rejected.
9. Blank skill input is rejected at command level.
10. A nonexistent selected directory is rejected.
11. An ordinary file selected as the root is rejected.
12. Success has exactly the three JSON keys with specified value types.
13. The selected path is normalized and absolute, including relative and dot-segment input.
14. Production success emits equivalent decoded JSON on stdout, empty stderr, and status zero.
15. Production failure emits a diagnostic on stderr, no partial JSON on stdout, and nonzero status.

### Feature 2: Marker text and bounded reads — 15 checks

1. An ordinary marker file reports true and its contents.
2. An absent marker reports false and null.
3. A directory named SKILL.md reports false and null.
4. An empty regular marker reports true and an empty string, not null.
5. Multiline instruction text is preserved.
6. CRLF line endings are preserved.
7. Trailing whitespace is preserved.
8. Absence of a final newline is preserved.
9. Non-ASCII Unicode text is decoded faithfully.
10. Leading UTF-8 BOM behavior follows the standard decoder.
11. Malformed frontmatter is returned verbatim, not rejected as invalid skill semantics.
12. Malformed UTF-8 is rejected rather than replaced silently.
13. Exactly 1,048,576 marker bytes are accepted.
14. 1,048,577 marker bytes are rejected with a limit diagnostic and no output.
15. The limit applies to bytes, not decoded character count; a multibyte fixture crossing the limit is rejected.

### Feature 3: Read-only boundary and reuse — 15 checks

1. A linked marker is excluded without reading its target.
2. An explicitly selected directory link can be inspected while retaining its lexical selected path.
3. A nested marker is not mistaken for the immediate marker.
4. A nested directory/link cycle does not trigger traversal.
5. An unrelated ordinary file does not change marker presence or returned text.
6. A successful inspection preserves selected-directory entry names, types, and bytes.
7. An invalid-encoding failure preserves selected-directory sentinels.
8. An over-limit failure preserves the oversized file and other sentinels.
9. Link targets and external sentinel contents remain unchanged.
10. Repeated inspection through one adapter returns equivalent content without accumulation.
11. Inspection of a second directory does not retain the first directory's content.
12. An invalid selection followed by a valid selection succeeds cleanly.
13. A valid inspection followed by a missing-marker inspection returns null, not stale text.
14. Help and parser rejection do not modify filesystem sentinels.
15. Results contain no validity, management ownership, consuming-harness compatibility, destination, or installation-scope claims.

Explicitly skip link-dependent checks with a reason if the environment cannot create links. Do not require privileged permission changes. Assert failure variant, status, surfaced diagnostic, absent output, execution phase, and command path. Compare filesystem entries and bytes, not access timestamps. Clean all temporary fixtures unconditionally. Run focused tests during development, analysis regularly, then full tests and formatting, independent standards/spec reviews, and commit intended changes only.

## Out of Scope

- Parsing frontmatter, validating skill specifications, linting content, or selecting a harness documentation baseline.
- Automatically discovering a skill when no path is selected or inspecting multiple directories at once.
- Reading linked marker contents, recursive inspection, attachments, scripts, or referenced files.
- Raw-text output modes, truncation, streaming output, adjustable size limits, or output schema versioning.
- Mutation, installation, adoption, replacement, removal, backups, and management metadata.
- Protection against concurrent malicious replacement of filesystem entries or claims of sandboxed access.

## Further Notes

The user selected skill inspection as the next milestone after project-local discovery. The bounded JSON contract and 1 MiB cap are conservative implementation choices for this slice. The research audit keeps inspection observational: a trusted stable local root is assumed, but no hostile concurrent-race resistance, native precedence, or runtime-visibility claim is made. Continue using the existing command-level temporary-filesystem testing seam. Preserve unrelated untracked files and do not rewrite concurrent commits. Use openai/gpt-5.6-luna for subagents unless explicitly changed.
