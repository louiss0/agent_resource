> **Historical design record** — this document may not describe
> current behavior. See [README.md](../README.md) and
> [docs/guides/](guides/) for current guidance.

﻿# Claude Code context file conventions

Research for [issue #110](https://github.com/louiss0/agent_resource/issues/110), â€œEstablish Claude Code context file conventions.â€ **Retrieved** during this research pass; the first-party docs map reports a last update of `2026-11-18 14:57:55 UTC` [MAP]. No Claude Code process, CLI command, hook, or network-connected tool was executed. This is a documentation baseline, not a tested runtime contract. The public web search did not expose the issue body, so this note addresses the title and the requested questions.

Evidence labels: **D** = official first-party documentation as retrieved; **S** = first-party source-repository issue or comment, not documentation and not a test performed here; **I** = my inference from cited facts; **U** = not established in this pass.

## 1. Summary of the official baseline

| Concern | Official answer |
| --- | --- |
| What is a context file? | Plain Markdown giving Claude persistent instructions. Claude Code treats the content as context, not enforced configuration; use hooks or permissions for hard enforcement. [M: CLAUDE.md files; CLAUDE.md vs auto memory] |
| Project-shared locations | `./CLAUDE.md` **or** `./.claude/CLAUDE.md`. [M: Choose where to put CLAUDE.md files] |
| Personal per-project location | `./CLAUDE.local.md`; docs recommend adding it to `.gitignore`. [M: Choose where to put CLAUDE.md files; Import additional files] |
| Personal cross-project location | `~/.claude/CLAUDE.md`; loaded in every project on the machine. [M: Choose where to put CLAUDE.md files; CD] |
| Organization-managed location | Platform-specific `CLAUDE.md` in the managed system directory, or managed `claudeMd` content in `managed-settings.json`; individual exclusions cannot remove it. [M: Deploy organization-wide CLAUDE.md] |
| Combination model | Files are **concatenated**, not overridden by scope. Ordering rules are documented, but conflicting instructions are reconciled by Claudeâ€™s judgment with no compliance guarantee. [M: How CLAUDE.md files load; M: Claude isnâ€™t following my CLAUDE.md] |
| Subdirectories | `CLAUDE.md` / `CLAUDE.local.md` below the launch directory are discovered but load on demand when Claude accesses another file in that subdirectory. [M: How CLAUDE.md files load] |
| Imports | `@path/to/file`; relative to the importing file; nested up to four hops. [M: Import additional files] |
| Authoring target | Under 200 lines per file; launch files load whole up to 4 MiB, and larger ones are skipped. On-demand files have a separate, smaller character limit. [M: Write effective instructions; M: My CLAUDE.md is too large; M: Claude ignores the end of my subdirectory CLAUDE.md] |

## 2. Locations and filenames

### 2.1 Scope table as documented

**D:** The memory documentation lists these locations in load order, from broadest scope to most specific [M: Choose where to put CLAUDE.md files]:

| Scope | Location | Sharing | Documented purpose |
| --- | --- | --- | --- |
| Managed policy | macOS: `/Library/Application Support/ClaudeCode/CLAUDE.md`; Linux and WSL: `/etc/claude-code/CLAUDE.md`; Windows: `C:\Program Files\ClaudeCode\CLAUDE.md` | All users managed by the organization | Coding standards, security policy, compliance requirements |
| User | `~/.claude/CLAUDE.md` | Only that user, all projects | Personal preferences and tooling shortcuts |
| Project | `./CLAUDE.md` or `./.claude/CLAUDE.md` | Team members through source control | Architecture, standards, workflows |
| Local | `./CLAUDE.local.md` | Only that user in that project | Sandbox URLs, preferred test data; add to `.gitignore` |

The directory reference independently describes `CLAUDE.md` as a project/global file loaded at session start and `~/.claude/CLAUDE.md` as the global counterpart loaded alongside project instructions [CD]. The help-center article gives the same high-level placement guidance [SUP].

**D:** An alternative to deploying a managed file is the `claudeMd` key inside `managed-settings.json`. It is honored only in managed/policy settings, applies to every machine session and repository, and has the same precedence as a managed `CLAUDE.md` file â€” loading before user and project instructions. Setting `claudeMd` in user, project, or local settings has no effect. [M: Deploy organization-wide CLAUDE.md; SR]

### 2.2 Enterprise/managed delivery locations

**D:** Managed settings â€” the policy layer, distinct from the managed `CLAUDE.md` text â€” can be delivered by server-managed settings, macOS configuration profile (`com.anthropic.claudecode`), Windows HKLM registry (`HKLM\SOFTWARE\Policies\ClaudeCode`), file-based policy, or HKCU registry. The file-based system directories are the same macOS, Linux/WSL, and Windows directories listed above and contain `managed-settings.json`, an optional `managed-settings.d/`, and `managed-mcp.json`. The docs explicitly say the legacy Windows `C:\ProgramData\ClaudeCode\managed-settings.json` is not read. [MS: Deploy a managed settings file; Where each mechanism stores the policy]

**D:** Managed-policy `CLAUDE.md` files cannot be excluded with `claudeMdExcludes`. However, if a developer turns off CLAUDE.md loading altogether, managed content is not loaded in that session. [M: Deploy organization-wide CLAUDE.md; Manage CLAUDE.md for large teams]

### 2.3 Related but distinct files

Do not treat these as synonyms for a project context file:

- `.claude/rules/*.md`: topic files, optionally path-scoped with YAML `paths:` frontmatter. Rules without `paths:` load at launch with the same priority as `.claude/CLAUDE.md`; path-scoped rules load when matching files are accessed. [M: Organize rules with `.claude/rules/`]
- `~/.claude/rules/`: the user-level equivalent, applied across projects. [CD; M: Organize rules with `.claude/rules/`]
- `~/.claude/projects/<project>/memory/MEMORY.md` and topic files: **auto memory**, written by Claude rather than by the team. `MEMORY.md` loads only its first 200 lines or 25 KB, whichever comes first; topic files are read on demand. This limit is explicitly *not* the CLAUDE.md limit. [M: Auto memory]
- `AGENTS.md`: an alternative project instruction format that Claude Code can read in place of CLAUDE.md under documented conditions (Â§5). [M: AGENTS.md]
- `.claude/settings.json`, `.claude/settings.local.json`, and `~/.claude/settings.json`: settings, not instruction files. [SET]

## 3. Discovery and precedence

### 3.1 Ancestor walk at launch

**D:** Claude Code checks the current working directory and every directory above it for both `CLAUDE.md` and `CLAUDE.local.md`. Launching in `foo/bar/` therefore loads instructions from `foo/bar/CLAUDE.md`, `foo/CLAUDE.md`, and any `CLAUDE.local.md` files alongside them. Content is concatenated, ordered from the filesystem root down toward the working directory. Within one directory, `CLAUDE.local.md` is appended after `CLAUDE.md`. Thus instructions nearer the launch directory are read later, and personal local notes come after the shared file at that level. [M: How CLAUDE.md files load; CD]

**D:** The documented scope order, broadest to most specific, is managed policy, user, project, then local. [M: Choose where to put CLAUDE.md files] The docs do **not** provide one explicit flattened total order that resolves every interaction between scope level and directory depth (for example, an ancestor local file versus a deeper project file); the two stated ordering rules should be quoted rather than extended. **I:** An implementation should preserve the documented per-directory and per-scope ordering and avoid claiming a stronger tie-break rule.

**D:** CLAUDE.md content is delivered as a user message after the system prompt, not as part of the system prompt. Claude tries to follow it, but strict compliance is not guaranteed, especially for vague or contradictory text. Use `/context all` to see loaded Memory files and `/memory` to open or create them. [M: Claude isnâ€™t following my CLAUDE.md; View and edit with `/memory`]

**S / U:** An older first-party issue reports an `strace` probe in which `/etc/claude-code/CLAUDE.md`, `~/.claude/CLAUDE.md`, and workspace files were probed but `/CLAUDE.md` was not loaded; an Anthropic participant said the runtime recurses toward `/` but does not read the root directory itself [GH2274]. Current docs say â€œevery directory above itâ€ but do not explicitly restate the root-file exclusion. Treat this as a runtime observation from a first-party issue, not as current documentation and not as a test performed here.

### 3.2 Subdirectory files and on-demand loading

**D:** Claude Code also discovers `CLAUDE.md` and `CLAUDE.local.md` files in subdirectories under the launch directory. They are not loaded at launch. Each is loaded when Claude reads, writes, or edits another file in that subdirectory. A Bash command that counts as a read of a single file, such as `cat` or `head`, also triggers loading. [M: How CLAUDE.md files load]

**D:** A newly created subdirectory CLAUDE.md will not appear under launch-time Memory files. When it loads, a `Loaded` line with its path appears in the terminal. The docs suggest creating the file from a shell and then asking Claude to read a file in that subdirectory as a test. [M: Claude isnâ€™t following my CLAUDE.md]

**D:** The on-demand mechanism also applies to a subdirectoryâ€™s `AGENTS.md`, when that subdirectory has no CLAUDE.md-family file of its own, and to path-scoped rules when a matching file is accessed. [M: AGENTS.md; M: Organize rules with `.claude/rules/`]

### 3.3 Additional directories, exclusions, and settings interactions

**D:** `--add-dir` grants file access but does not load memory files from the added directory by default. Setting `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` loads that directoryâ€™s `CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md`, and `.claude/rules/*.md`, except rules with a `paths` field. `CLAUDE.local.md` is skipped if `local` is excluded from `--setting-sources`. [M: Load from additional directories]

**D:** `claudeMdExcludes` skips files by absolute-path glob; it can be set at user, project, local, or managed scope and arrays merge across scopes. It is intended for monorepos where unrelated teamsâ€™ instructions would otherwise be discovered. Managed CLAUDE.md files cannot be excluded. Current documentation also says a symlink can be excluded by a pattern matching either its rules path or its link target; before v2.1.239 only the target path worked. [M: Exclude specific CLAUDE.md files; LC]

**D:** Settings precedence is managed settings, command-line `--settings JSON`, project-local `.claude/settings.local.json`, shared project `.claude/settings.json`, then user `~/.claude/settings.json`. This is settings-key precedence, not an override rule that deletes lower-level CLAUDE.md content. [SET: Settings precedence] The documentation also describes a Project instructions setting with `claude-md-or-agents-md` (default), `claude-md-and-agents-md`, `claude-md`, and `managed-only`; `managed-only` omits project/local/user CLAUDE.md files and rules at launch while leaving on-demand subdirectory files and path-scoped rules available. [M: Choose which instruction files load]

## 4. Syntax and constraints

### 4.1 Markdown and injection behavior

**D:** CLAUDE.md files are Markdown files written in plain text; the docs do not prescribe a required frontmatter block for them. Use headers and bullets, group related material, and keep instructions concrete and verifiable. Contradictory instructions across files may be resolved arbitrarily, so review root, nested, and rules files together. [M: CLAUDE.md files; Write effective instructions]

**D:** Block-level HTML comments in CLAUDE.md are stripped before content is injected into context; comments inside code blocks are preserved, and opening the file directly with Read still shows them. [M: How CLAUDE.md files load]

**D:** Imports are skipped inside Markdown code spans and fenced code blocks. Wrapping a path in backticks keeps it literal. [M: Import additional files]

### 4.2 `@path` imports

**D:** A CLAUDE.md file can import another file with `@path/to/import` anywhere in its text. Both relative and absolute paths are allowed. Relative paths resolve against the **importing file**, not the working directory. Tilde paths such as `@~/.claude/my-project-instructions.md` point at the home directory and are documented as a way to share personal instructions across git worktrees. [M: Import additional files]

**D:** Paths containing spaces need a backslash before each space, for example `@Design\ Docs/api-conventions.md`. A quoted path is not imported. Imports may nest, with a **maximum depth of four hops**. [M: Import additional files]

**I:** The documented four-hop limit permits a chain such as `CLAUDE.md â†’ A â†’ B â†’ C â†’ D`; a fifth imported file is not expanded under that reading. This example is my interpretation of the documented limit, not a runtime test.

**D:** A project fileâ€™s import is â€œexternalâ€ when it resolves outside the working directory. Claude Code shows an approval dialog the first time it encounters such imports for a project; declining leaves them disabled without repeating the dialog. User-scope memory files are trusted for imports in ordinary sessions, with specific Cowork-session restrictions documented separately. [M: Import additional files]

**D:** Imports do **not** reduce context cost: imported files load together with the importing CLAUDE.md. [M: Write effective instructions]

### 4.3 Size and line guidance

| File class | Official constraint |
| --- | --- |
| Any CLAUDE.md authoring target | Target under 200 lines; longer files consume more context and can reduce adherence. A warning appears at startup and `/status` when an instruction file exceeds the recommended length, and when files individually within it exceed a combined session-start limit. [M: Write effective instructions; My CLAUDE.md is too large] |
| CLAUDE.md loading at launch | Loaded in full up to 4 MiB; over 4 MiB, Claude Code skips the file and loads none of it. [M: Auto memory note; My CLAUDE.md is too large] |
| Auto-memory `MEMORY.md` | First 200 lines or 25 KB, whichever comes first. This is a separate mechanism. [M: Auto memory] |
| On-demand subdirectory `CLAUDE.md` / `CLAUDE.local.md` and their imports; rules in a subdirectoryâ€™s `.claude/rules/`; path-scoped rules in project or user `.claude/rules/` | Since v2.1.309, an oversized file receives only its start plus a note telling Claude to read the rest with Read. Limits: 40,000 characters for a 200K context window; 200,000 characters on Opus 4.6 and Sonnet 4.6 with a 1M window, or 150,000 on later models. The docs suggest `wc -m`. [M: Claude ignores the end of my subdirectory CLAUDE.md] |
| `.claude/rules/` path globs | The whole `paths` list shares a budget of 1,000 expanded patterns and 4 MiB; patterns without braces do not count. [M: Organize rules with `.claude/rules/`] |

**I:** For repository conventions, the practical split is: globally applicable, always-needed rules in the project CLAUDE.md; detailed topic files reached through imports only when they are genuinely part of the same always-loaded context; and file-type/subtree-specific guidance in `.claude/rules/` files with `paths:` frontmatter, because those load only when matching files are accessed. Skills are the documented choice for task-specific material that need not be in context continuously. [M: Organize rules with `.claude/rules/`]

### 4.4 `.claude/rules/` relationship

**D:** Rules are Markdown files discovered recursively under `.claude/rules/`, normally one topic per descriptive filename. A rule without `paths:` frontmatter loads at launch with the same priority as `.claude/CLAUDE.md`. A rule with `paths:` frontmatter loads when Claude uses Read, Write, or Edit on a matching file, or views it through a Bash command that counts as a read. Patterns are relative to the ruleâ€™s base directory: the directory containing the ruleâ€™s `.claude` for project rules, or the sessionâ€™s primary working directory for user rules. [M: Organize rules with `.claude/rules/`]

**D:** Rules are guidance, not enforcement, just like CLAUDE.md. For guaranteed behavior the docs point to hooks and permissions. [CD; M: CLAUDE.md vs auto memory]

## 5. AGENTS.md interaction

**D:** By default Claude Code reads `AGENTS.md` only when there is no `CLAUDE.md` or `CLAUDE.local.md` in the working directory or any directory above it. Files that count for that check are `CLAUDE.md`, `.claude/CLAUDE.md`, and `CLAUDE.local.md`; `~/.claude/CLAUDE.md`, managed CLAUDE.md, and `.claude/rules/` do not count. [M: AGENTS.md]

**D:** When none count, Claude reads `AGENTS.md` and `.claude/AGENTS.md` in the working directory and ancestors at session start, plus a subdirectoryâ€™s `AGENTS.md` on demand when a file there is opened and the subdirectory has no CLAUDE.md-family file. `AGENTS.local.md`, `AGENTS.override.md`, and files under `.agents/` are not read. Direct `AGENTS.md` reading requires v2.1.277 or later; the docs list version/plugin/session cases where only CLAUDE.md is read. [M: AGENTS.md]

**D:** Project instructions can be set to `claude-md-or-agents-md` (default), `claude-md-and-agents-md`, `claude-md`, or `managed-only`. With both-file mode, each directoryâ€™s CLAUDE.md files come before its AGENTS.md files, and an AGENTS.md already loaded through import or symlink is not duplicated. The setting lives under `pluginConfigs` for the built-in Agents.md plugin and is read from user, `--settings`, or managed settings, not project/local settings; v2.1.285 changed the plugin ID. [M: Choose which instruction files load]

**I:** This repository currently contains a root `AGENTS.md` and a root `CLAUDE.md`. Under the documented default, the presence of the project `CLAUDE.md` means Claude Code reads the CLAUDE.md chain rather than the root `AGENTS.md` directly. If the team wants AGENTS.md to remain authoritative, it should configure both-file mode or import `@AGENTS.md` from CLAUDE.md; keeping equivalent unimported prose in both files is a conflict risk.

## 6. Documentation baseline versus runtime verification

**D â€” baseline established here:** All placement, ordering, import, rules, size, AGENTS.md, and managed-policy statements above come from official Anthropic documentation retrieved from `code.claude.com` and `support.claude.com`. The settings repository issues encountered during search were used only as leads, not as the baseline.

**Not performed:** No `claude` process was started; no fixture directories were created; no `/context all`, `/memory`, `/status`, or `/doctor` output was inspected; no version-specific behavior was measured; no managed settings file was read or deployed. Version notes quoted from official docs are part of the docs, not independent verification.

**S â€” first-party but not documentation:** GitHub issues in `anthropics/claude-code` confirm that users and sometimes Anthropic staff discuss runtime details such as root-directory probing and `strace` observations. These are useful clues but cannot replace a versioned runtime test.

### Open questions and what would settle them

1. **U:** If both `./CLAUDE.md` and `./.claude/CLAUDE.md` exist in the same directory, the retrieved docs call both valid project locations but do not state a deterministic simultaneous-load or precedence rule. A fixture session using `/context all` would settle this for a specific Claude Code version.
2. **U:** The current prose does not explicitly say whether a filesystem-root `CLAUDE.md` is read. The older first-party issue says it is not. A fixture at a controlled root path would settle it.
3. **U:** Managed `claudeMd` content and a deployed managed `CLAUDE.md` are both documented as having managed precedence; their combined ordering when both are present was not established.
4. **U:** No runtime check confirmed the four-hop import cap, the on-demand trigger set, or the 40,000/150,000/200,000-character on-demand caps for the installed client.
5. **U:** Issue #110â€™s body was not available through public web search; this note answers the stated title rather than any unstated acceptance criteria.

## 7. Resolution summary for issue #110

**Resolution:** Adopt the official four-scope convention â€” managed platform-directory `CLAUDE.md`, user `~/.claude/CLAUDE.md`, shared project `./CLAUDE.md` or `./.claude/CLAUDE.md`, and gitignored `./CLAUDE.local.md` â€” and document that all discovered files are additive, ordered broad-to-specific and root-down-to-cwd, with subdirectory files loading only on access. Keep this repositoryâ€™s shared conventions in the existing root `CLAUDE.md`, split with `@path` imports where needed (maximum four hops, target under 200 lines), and use `.claude/rules/` with `paths:` frontmatter for file-type- or subtree-specific guidance; do not leave duplicate unimported guidance in both root `AGENTS.md` and `CLAUDE.md`, because the documented default reads AGENTS.md only when no project/local CLAUDE.md exists. This closes the documentation-baseline question; it is not a claim of runtime verification.

## Sources

- **[M]** [How Claude remembers your project â€” Claude Code Docs](https://code.claude.com/docs/en/memory) â€” primary page for scope table, load order, imports, rules, AGENTS.md, auto memory, exclusions, and size limits.
- **[MD]** [CLAUDE.md â€” Claude Code Docs](https://code.claude.com/docs/en/claude-md) â€” parallel first-party page returned for the same memory material during retrieval.
- **[CD]** [Explore the `.claude` directory â€” Claude Code Docs](https://code.claude.com/docs/en/claude-directory) â€” file roles and launch/on-demand timing.
- **[MS]** [Deploy managed settings â€” Claude Code Docs](https://code.claude.com/docs/en/managed-settings) â€” managed delivery mechanisms and platform paths.
- **[SET]** [Claude Code settings](https://code.claude.com/docs/en/settings.md) â€” settings-file scopes and precedence.
- **[SR]** [All settings â€” Claude Code Docs](https://code.claude.com/docs/en/settings-reference) â€” `claudeMd` and `claudeMdExcludes` key scope.
- **[FO]** [Extend Claude Code â€” Claude Code Docs](https://code.claude.com/docs/en/features-overview.md) â€” additive layering and session-start context cost.
- **[LC]** [Set up Claude Code in a monorepo or large codebase](https://code.claude.com/docs/en/large-codebases) â€” practical `claudeMdExcludes` guidance.
- **[SUP]** [Give Claude context: CLAUDE.md and better prompts â€” Claude Help Center](https://support.claude.com/en/articles/14553240-give-claude-context-claude-md-and-better-prompts) â€” official introductory placement guidance.
- **[MAP]** [Claude Code docs map](https://code.claude.com/docs/en/claude_code_docs_map) â€” retrieved-page freshness note.
- **[GH2274]** [anthropics/claude-code issue #2274, â€œDocumentation about CLAUDE.md locations, seems not quite accurateâ€](https://github.com/anthropics/claude-code/issues/2274) â€” first-party runtime observation about root-directory probing; not documentation and not independently reproduced here.
