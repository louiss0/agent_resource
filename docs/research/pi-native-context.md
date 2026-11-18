# Native Pi context files: `AGENTS.md` and `CLAUDE.md`

Research for [issue #112](https://github.com/louiss0/agent_resource/issues/112), â€œEstablish native Pi context file conventions.â€ Live web retrieval succeeded for the official Pi documentation and upstream source/issues cited below. The installed package inspected locally is `@earendil-works/pi-coding-agent` **1.5.2**; upstream links reference `main` as retrieved in this research session. **No `pi` process was started and no provider request was captured**, so this is documentation plus static source verification, not empirical runtime certification.

Evidence labels used below:

- **[D]** Official first-party documentation (`docs.pi.dev`, upstream/docs shipped with Pi).
- **[S]** Upstream first-party source or maintainer statement in the Pi repository.
- **[L]** Static inspection of the installed 1.5.2 compiled runtime code.
- **[R]** Empirical runtime verification. **None performed.**

## Answer in brief

Piâ€™s native context files are plain instruction documents, normally named `AGENTS.md` or `CLAUDE.md`. Pi checks the user agent directory and, for a session, the working directory and every ancestor up to the filesystem root; it selects **one** file per directory, with `AGENTS.md` preferred over `CLAUDE.md`. Selected files are concatenated globally first, then from filesystem root down to the working directory, into a tagged `project_context` system-prompt section. [D1][S1][S2][L1][L2]

## 1. Official documentation baseline

| Claim | Official wording / consequence | Source |
| --- | --- | --- |
| User-level context lives in the agent directory. | The agent directory defaults to `~/.pi/agent`; accepted filenames there are `AGENTS.override.md`, `AGENTS.md`, `AGENTS.MD`, `CLAUDE.md`, and `CLAUDE.MD`. | [D1] |
| `PI_CODING_AGENT_DIR` relocates that directory. | â€œSet its location with the `PI_CODING_AGENT_DIR` environment variable or the SDKâ€™s `agentDir` option.â€ | [D1][D3] |
| Project context is ancestor-scoped. | â€œPi loads them from the agent directory, the working directory, and its parent directories. A context file applies whenever Pi runs in its directory or anywhere below it.â€ | [D1] |
| `AGENTS.override.md` is a same-directory replacement. | It â€œreplaces `AGENTS.md` or `CLAUDE.md` only in the same directory. It does not suppress context files from the agent directory or other directories.â€ | [D1] |
| Discovery does not depend on project trust. | â€œContext-file discovery does not require project trustâ€; separate security docs say context files load even when trust is declined, and should be treated as untrusted input. | [D1][D4] |
| Discovery can be disabled. | `-nc` / `--no-context-files` â€œDisables `AGENTS.md` and `CLAUDE.md` discovery.â€ | [D2] |
| Context files feed the system prompt. | â€œPi builds the system prompt from its base instructions and discovered context filesâ€; changes require `/reload` in a running session. | [D7][D6] |
| SDK hosts control admission. | `resourceLoader` supplies context files; use `DefaultResourceLoader` for standard discovery with overrides, or a custom loader for full host control. | [D5][S8] |

The official docs do **not** spell out the exact same-directory priority order between `AGENTS.md` and `CLAUDE.md`, the filesystem-root boundary, the root-to-cwd concatenation order, or a maximum file size. Those details come from primary source code below.

## 2. Discovery and precedence

### Per-directory candidate order

The loader checks these names in order and returns the first readable regular file:

1. `AGENTS.override.md`
2. `AGENTS.md`
3. `AGENTS.MD`
4. `CLAUDE.md`
5. `CLAUDE.MD`

This order is in `loadContextFileFromDir()` in upstream `resource-loader.ts` and the installed 1.5.2 `dist/core/resource-loader.js`; only one candidate per directory is admitted. A directory entry matching a candidate name is skipped, and an unreadable candidate produces a warning and falls through to the next candidate. [S1][L1]

**Therefore, when both `AGENTS.md` and `CLAUDE.md` exist in the same directory, `AGENTS.md` wins and `CLAUDE.md` is ignored for that directory.** This is also explicitly stated by Piâ€™s maintainer: â€œThe system now looks for `AGENTS.md` or `CLAUDE.md` (with `AGENTS.md` preferred)â€ ([issue #10](https://github.com/earendil-works/pi/issues/10); see also [PR #9](https://github.com/earendil-works/pi/pull/9)). `AGENTS.MD` also outranks `CLAUDE.md` in the current candidate list. [S4][S1]

`AGENTS.override.md` is an even higher-priority local replacement, but only for its own directory; it does not remove the agent-directory file or ancestor files. [D1][S5]

### Global location

At load time the agent directory is resolved first: `PI_CODING_AGENT_DIR` wins if set (tilde-normalized), otherwise the default is `<home>/.pi/agent`. In the SDK, an explicit `agentDir` can supply the same role. The loader then applies the same per-directory candidate order inside that directory. [S3][D3][S1][L1][L3]

### Ancestor traversal and `cwd`

The loader starts at the resolved session `cwd` and repeatedly calls `dirname(currentDir)` until `dirname(currentDir) === currentDir`, i.e. the filesystem root. Every directory in that chain contributes at most one selected file. There is no documented or coded stop at the Git repository root. [D1][S1][L1]

Practical consequences:

| Layout / invocation | Native Pi result |
| --- | --- |
| `repo/AGENTS.md`, Pi started in `repo/` | Root file loads. |
| `repo/AGENTS.md`, Pi started in `repo/src/` | Root file still loads; it applies to descendants. |
| `repo/docs/AGENTS.md`, Pi started in `repo/` | **Not loaded** merely because a tool reads a file under `docs/`. |
| Same layout, Pi started in `repo/docs/` | Root file and `docs/AGENTS.md` both load; `docs/` file is closer. |
| Pi started in `repo/src/` with `repo/src/docs/AGENTS.md` | Sibling/child file is not discovered. |
| `repo/AGENTS.md` and `repo/CLAUDE.md` together | Only `AGENTS.md` loads. |
| `repo/AGENTS.md` and `repo/AGENTS.override.md` together | Only the override loads from `repo/`; ancestors and global still load. |
| Agent-dir file is also an ancestor of `cwd` | Exact already-seen paths are deduplicated. [S1][L1] |

A narrower implementation detail: in a linked Git worktree nested under its main checkout, the worktreeâ€™s selected context file suppresses the main checkoutâ€™s same-basename file so the same logical repository scope is not applied twice. This is source-level behavior in 1.5.2, not an official-doc promise. [S1][L1]

## 3. Prompt assembly and constraints

### Concatenation order

The loader returns:

1. the agent-directory file, if any;
2. ancestor files discovered from filesystem root down to `cwd`, each prepended during the upward walk;
3. nothing from directories below `cwd`. [S1][L1]

`AgentSession` passes that list to system-prompt construction as `contextFiles`. The renderer produces a heading and one block per file:

```text
Project-specific instructions and guidelines:

<project_instructions path="/abs/path/AGENTS.md">
...verbatim content...
</project_instructions>

<project_instructions path="/abs/path/subdir/AGENTS.md">
...verbatim content...
</project_instructions>
```

That body becomes the `<project_context>` section, wrapped in its own tags. In the full prompt, the section order is base preamble â†’ tools/rules/docs â†’ appended system instructions â†’ `project_context` â†’ skills â†’ cwd â†’ custom sections, with sections joined by blank lines. A forced SDK system prompt replaces the entire structured prompt and can bypass context injection entirely. [S2][L2][L4][D5]

### Format, size, and special syntax

- **Format:** plain UTF-8 Markdown-style text. The loader reads the whole file as a string and strips a leading BOM; no frontmatter, includes, variables, or per-file directives are parsed for native context files. [S1][L1]
- **Special filename:** only `AGENTS.override.md` has special discovery semantics. The XML tags shown above are generated by Pi; users do not need to write them. [D1][S2]
- **Size limit:** the official docs specify none, and the 1.5.2 loader/renderer performs no truncation or byte/token cap. The practical limit is the provider/model context window and whatever an extension or SDK host does downstream. This is absence of a documented/implemented Pi-side limit, not a guarantee for all future versions. [S1][S2][L1][L2]
- **Escaping caveat (inference):** source interpolation does not escape file content or the `path` attribute before placing them inside XML-like tags. A literal `</project_instructions>` inside a context file could therefore confuse the boundary. Plain Markdown without that literal is safest; this is inferred from the template code, not stated in docs. [S2][L2]
- **Reload behavior:** files are read when resources load, not re-read on every model request. `/reload` after editing, or start a new session. [D6][L1]
- **Override paths:** `--no-context-files`, SDK `agentsFilesOverride`, `ResourceLoader` replacement, and `before_agent_start` prompt mutation can all change what reaches the model; these are separate layers from discovery. [D2][D5][S1]

## 4. Documentation baseline versus verification

| Category | Established here |
| --- | --- |
| **Official baseline [D]** | User agent directory and `PI_CODING_AGENT_DIR`; accepted filenames; ancestor/cwd inheritance; same-directory override semantics; no trust requirement; CLI disable flag; `/reload`; SDK resource-loader boundary; system-prompt role. |
| **Source-level verification [S]/[L]** | Exact candidate order (`AGENTS.md` before `CLAUDE.md`); one file per directory; traversal to filesystem root with no repo-root stop; global-first/root-to-cwd ordering; path dedupe; full-file read with BOM strip and no truncation; XML-tagged rendering and section order; worktree shadowing. Installed 1.5.2 compiled code matches the upstream `main` source snippets retrieved for these points. |
| **Empirical runtime verification [R]** | **Not performed.** No controlled fixture was created, no `pi` invocation was executed, and no provider payload was captured. Previous upstream PRs report real CLI/system-prompt checks for override selection and XML boundaries, but that is their evidence, not this investigationâ€™s. [S5][S6] |

To settle any remaining runtime-only question, create a fixture with conflicting `AGENTS.md`/`CLAUDE.md`, sibling subdirectories, and an agent-dir file, then start Pi at two different `cwd` values and capture the assembled system prompt from a debug/provider trace. An upstream docs clarification would be needed if the `AGENTS.md`-over-`CLAUDE.md` preference must be an official documented rule rather than a source/maintainer rule.

## 5. Consequence for this repository

This repository currently has both root `AGENTS.md` and root `CLAUDE.md`. Under native Pi discovery from the repository root, **`AGENTS.md` is selected and `CLAUDE.md` is not**: the two are not merged. The convention should therefore make `AGENTS.md` the canonical cross-agent instruction file, merge any instructions that must also apply to Pi into it, and treat `CLAUDE.md` as a Claude-Code-only compatibility file containing no Pi-critical rules. Subdirectory rules should only be expected when Pi is started in that subdirectory or below it, unless an extension supplies additional discovery. [S1][S4][D1]

## Sources

- **[D1]** [Official configuration reference â€” Context files and agent directory](https://docs.pi.dev/latest/configuration); mirrored at [upstream `packages/coding-agent/docs/configuration.md`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/configuration.md). Installed copy: `node_modules/@earendil-works/pi-coding-agent/docs/configuration.md`.
- **[D2]** [Upstream CLI reference](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md); installed `docs/cli.md` (`-nc`, `--no-context-files`).
- **[D3]** [Upstream environment variables reference](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/environment-variables.md); installed `docs/environment-variables.md` (`PI_CODING_AGENT_DIR`).
- **[D4]** [Upstream security reference](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/security.md); installed `docs/security.md` (context files load without trust).
- **[D5]** [Upstream SDK reference](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/sdk.md); installed `docs/sdk.md` and `examples/sdk/07-context-files.ts` (`resourceLoader`, `agentsFilesOverride`).
- **[D6]** [Upstream slash commands](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/slash-commands.md); installed `docs/slash-commands.md` (`/reload`).
- **[D7]** [Upstream How Pi Works](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/how-pi-works.md); installed `docs/how-pi-works.md` (system prompt assembly).
- **[S1]** [Upstream `src/core/resource-loader.ts`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/resource-loader.ts) â€” candidate list, traversal, dedupe, worktree shadowing, `noContextFiles`.
- **[S2]** [Upstream `src/core/system-prompt.ts`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/system-prompt.ts) â€” `project_context`, `project_instructions`, ordered sections, forced-prompt bypass.
- **[S3]** [Upstream `src/config.ts`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/config.ts) â€” `getAgentDir()`, `PI_CODING_AGENT_DIR`.
- **[S4]** [Maintainer statement in issue #10](https://github.com/earendil-works/pi/issues/10) and [PR #9](https://github.com/earendil-works/pi/pull/9) â€” `AGENTS.md` preferred over `CLAUDE.md`.
- **[S5]** [Issue #7642](https://github.com/earendil-works/pi/issues/7642) and [PR #7681](https://github.com/earendil-works/pi/pull/7681) â€” override is highest-priority per-directory file and does not suppress other directories.
- **[S6]** [Issue #4319](https://github.com/earendil-works/pi/issues/4319) and [PR #4541](https://github.com/earendil-works/pi/pull/4541) â€” rationale for XML boundaries instead of Markdown headings.
- **[S8]** [Upstream `src/core/sdk.ts`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/sdk.ts) â€” SDK `agentDir` and resource-loader defaults.
- **[L1]** Installed 1.5.2 `dist/core/resource-loader.js`.
- **[L2]** Installed 1.5.2 `dist/core/system-prompt.js`.
- **[L3]** Installed 1.5.2 `dist/config.js`.
- **[L4]** Installed 1.5.2 `dist/core/agent-session.js`.
- **Installed package root inspected:** `C:\Users\bvlou\.local\share\pnpm\store\v11\links\@earendil-works\pi-coding-agent\1.5.2\8e8194805424cada21178689b14494ae559da1790c3a558b01e997d699f911d2\node_modules\@earendil-works\pi-coding-agent`.

---

## Resolution summary for issue #112

Pi natively recognizes one context file per directory, preferring `AGENTS.md` over `CLAUDE.md` and checking the `PI_CODING_AGENT_DIR`-aware agent directory plus `cwd` and its ancestors up to the filesystem root; subdirectory files apply only when Pi starts in or below that subdirectory. Selected files are concatenated global-first and then root-to-cwd into a tagged system-prompt section with no documented size limit or special user syntax. Because this repository has both root files, its convention should make `AGENTS.md` canonical and merge any Pi-relevant rules from `CLAUDE.md`, since Pi will not load both natively.
