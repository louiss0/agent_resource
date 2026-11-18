# Codex context file conventions

Research for [Establish Codex context file conventions](https://github.com/louiss0/agent_resource/issues/111). **Retrieved:** live web search during this research pass. **Scope:** Codex's own `AGENTS.md` discovery, precedence, root detection and byte budget; cross-ecosystem `AGENTS.md` website context is included only where it clarifies (or conflicts with) Codex behavior. No Codex process was run.

## Evidence labels

- **D â€” official documentation:** first-party OpenAI documentation as retrieved; current prose, not an immutable release contract.
- **S â€” first-party source:** `openai/codex` source at current `main` as retrieved, or at an explicitly pinned SHA where noted. Read, not executed; not proof of an installed release.
- **I â€” inference / reconciliation:** my reasoning where sources conflict or are silent, identified as such.
- **U â€” unknown / not runtime-verified:** not established by a live Codex run in this pass.

Primary sources are listed at the end with full URLs.

## Executive summary

| Concern | Baseline | Evidence |
| --- | --- | --- |
| Context filenames | `AGENTS.md`; `AGENTS.override.md`; optional `project_doc_fallback_filenames` entries | D1, D2, D3, D4, S1 |
| User-global location | `$CODEX_HOME/AGENTS.override.md`, else `$CODEX_HOME/AGENTS.md`; default `~/.codex` | D1, S2 |
| Project walk | Project root â†’ current working directory, inclusive; at most one file per directory | D1, S1 |
| Project root | Nearest ancestor with a `project_root_markers` entry, default `[".git"]`; no marker â†’ cwd only | D1, D2, S1 |
| Merge order | Global file first, then project files root-first; later files win on conflict | D1, S1, S5 |
| Below cwd | Not preloaded at startup; model is instructed to check applicable nested `AGENTS.md` when working there | D1, S1, S4 |
| Byte limit | Default 32,768 bytes; implementation uses one shared, cumulative budget across the project chain | D1, D3, S1, S3 |
| Empty files | Empty/whitespace-only files contribute nothing; a project override still occupies its directory slot | D1, S1, I1 |

## 1. Locations and filenames

### 1.1 Cross-ecosystem convention

**D:** The cross-ecosystem [AGENTS.md](https://agents.md/) site recommends `AGENTS.md` at the repository root and nested files for subprojects, with the closest file taking precedence for the file being edited. It states that AGENTS.md is standard Markdown with no required fields and is now stewarded by the Agentic AI Foundation under the Linux Foundation. [D6]

**I:** That site describes a general convention, not Codex's exact chain construction. Its â€œclosest file winsâ€ phrasing is not the same as Codex's documented concatenation of root-to-cwd files; for Codex-specific behavior, the Codex documentation and source are authoritative. Codex's own base instructions say nested `AGENTS.md` files can exist anywhere in the repository, that the closest one takes precedence for conflicting instructions in its scope, and that explicit system/developer/user instructions outrank them. [S4]

### 1.2 User-global file

**D:** Codex first checks the Codex home directory, which defaults to `~/.codex` unless `CODEX_HOME` is set. It reads `AGENTS.override.md` if present; otherwise it reads `AGENTS.md`, using only the first non-empty file at this level. The documentation recommends `AGENTS.override.md` as a temporary global override without deleting the base file. [D1]

**S:** The global provider uses exactly two constants, `AGENTS.override.md` and `AGENTS.md`, tried in that order. It skips non-files and missing files, reads the first file whose trimmed text is non-empty, trims that text, and decodes lossily. Unlike project directories, an empty global override does fall through to global `AGENTS.md`. Fallback filenames do **not** apply at the global level. [S2]

### 1.3 Project file names and fallbacks

**D:** In each project directory Codex checks `AGENTS.override.md`, then `AGENTS.md`, then fallback names listed in `project_doc_fallback_filenames`; at most one file per directory is included. The fallback list defaults to `[]` and is a top-level `config.toml` key. [D1][D2][D3][D4]

**S:** The constants are `DEFAULT_AGENTS_MD_FILENAME = "AGENTS.md"` and `LOCAL_AGENTS_MD_FILENAME = "AGENTS.override.md"`; `candidate_filenames()` pushes those two first, then the configured fallbacks in order. Empty, duplicate, `.`/`..` and path-containing fallback entries are ignored (on Windows, `\` and `:` are also rejected), so a configured fallback name must be a bare filename. [S1][S3]

**I:** Because `project_doc_fallback_filenames` is top-level, putting it under `[project]` does not work. A first-party Codex issue records exactly that misconfiguration and confirms the fix was moving the key to the top level. [I1: #22454]

### 1.4 Project root detection

**D:** Codex walks upward from the working directory until it reaches a project root. By default a directory containing `.git` is the root. `project_root_markers` in `config.toml` customizes the marker list, e.g. `[".git", ".hg", ".sl"]`; `project_root_markers = []` skips parent traversal and treats cwd as the root. If no marker is found, only the current directory is checked. The same root detection governs project config layers and `AGENTS.md`. [D1][D2][D3][D4]

**S:** Discovery builds the marker list from non-project config layers only, then finds the nearest ancestor containing any marker; invalid marker configuration falls back to the default list. When no root is found, the search directory list is just cwd; when a root is found, the list is cwdâ†’root reversed into rootâ†’cwd. Project-root markers are not overridden by a project's own `.codex/config.toml`. The module comment states explicitly: â€œWe do **not** walk past the project root.â€ [S1]

**I:** For this repository, `.git` exists at the repository root, so a Codex session launched in a subdirectory would normally load files only from the repository root down to that subdirectory, not from parent directories outside the repository. [S1; local repository layout]

### 1.5 Directory walk and files below cwd

**D:** Project discovery starts at the project root, typically the Git root, and walks down to cwd. Codex â€œstops searching once it reaches your current directory.â€ [D1]

**S:** `agents_md_paths()` collects every candidate file from project root to cwd, inclusive, returning paths in that order; symlinks to files are allowed. [S1]

**D/S:** Files in sibling directories or deeper subdirectories below cwd are **not** part of the startup chain. For example, with cwd `packages/foo`, neither `packages/bar/AGENTS.md` nor `packages/foo/deep/AGENTS.md` is preloaded at startup. Codex's base instructions tell the model to check for applicable `AGENTS.md` files when working in a subdirectory of cwd or outside cwd, so a deeper file may be read later because the model chose to read it, not because startup discovery found it. A first-party feature request tracks making nested loading dynamic and more observable. [D1][S1][S4][I1: #12115]

## 2. Discovery and precedence

### 2.1 Concatenation order

**D:** Codex builds the instruction chain once per run, or once per launched TUI session:

1. **Global scope:** `$CODEX_HOME/AGENTS.override.md` if it exists, otherwise `$CODEX_HOME/AGENTS.md`; first non-empty file only.
2. **Project scope:** from project root down to cwd, at most one file per directory, checked in the order override â†’ `AGENTS.md` â†’ fallbacks.
3. **Merge order:** files are concatenated from root down, joined with blank lines; files closer to cwd appear later and therefore override earlier guidance. [D1]

[S] The implementation keeps global instructions separate from project entries, then assembles them with a `\n\n--- project-doc ---\n\n` separator. Source tests assert that global instructions precede project instructions and that project entries appear in creation-time source order. [S1][S5]

### 2.2 Per-directory priority

**D:** `AGENTS.override.md` takes priority over `AGENTS.md` in the same directory; if a fallback file is also present, the override still wins. The documented example shows a nested `AGENTS.md` ignored because `AGENTS.override.md` exists beside it. [D1]

**S:** Candidate selection tests existence/metadata before reading content, so the first existing candidate claims the directory slot. Tests confirm `AGENTS.override.md` is preferred and that a missing override falls through to `AGENTS.md`. [S1][S5]

**I/S:** A subtle source-level consequence: an empty or whitespace-only project `AGENTS.override.md` claims its directory slot, and that directory's `AGENTS.md` is then not read. The official prose only says â€œCodex skips empty files,â€ which can be read as implying fallback. A first-party issue documents this exact discrepancy and reports it still present in `rust-v0.163.0`. [S1][I1: #54755]

### 2.3 Precedence limits

**S:** Project instructions are skipped when the active project is untrusted, when `project_doc_max_bytes` is zero, or when no non-empty project document is found. Higher-priority system/developer/user instructions outrank AGENTS.md content. [S1][S4]

**D:** Project-scoped `.codex/config.toml` files load only for trusted projects; configuration reference also lists keys project-local config cannot override. [D4]

## 3. Constraints

### 3.1 Byte budget

**D:** The agents-md guide says Codex skips empty files and stops adding files once the combined size reaches `project_doc_max_bytes`, default 32 KiB (32,768 bytes); the config sample also records the default as 32768. [D1][D3]

**D â€” conflict:** The advanced configuration page describes `project_doc_max_bytes` as â€œhow much to read from each `AGENTS.md` file.â€ A first-party issue reports that this wording contradicts the agents-md guide and the implementation. [D2][I1: #36371]

**S:** The implementation resolves the conflict in favor of a **single shared budget**: `DEFAULT_PROJECT_DOC_MAX_BYTES = 32 * 1024`; `load_project_instructions()` seeds one `remaining` counter, shared across turn environments, and `read_agents_md()` subtracts each entry's kept byte length. If a file exceeds `remaining`, its raw bytes are truncated to `remaining`; subsequent files are skipped once the budget is exhausted. Warnings are emitted for truncation and exhaustion, with `tracing::warn!` alongside the runtime warning. A zero limit disables project docs. [S1][S3]

**I:** Treat the 32 KiB value as cumulative across the startup project chain, not per file. A large root file can crowd out or entirely suppress a nested file. The official â€œsplit instructions across nested directoriesâ€ advice only helps if the total stays under the shared budget. [S1; D1]

### 3.2 Truncation mechanics

**S:** Truncation is by raw byte offset (`Vec::truncate`), followed by lenient UTF-8 decoding, so a cut inside a multibyte character yields a replacement character. The budget is charged for the kept bytes. Separators are not charged to the budget. [S1]

**S:** The global `$CODEX_HOME` file is loaded by a separate provider with no length check and is outside `project_doc_max_bytes`; only project files consume the budget. A first-party issue independently documents this exemption and the shared, root-first budget. [S2][I1: #37956]

### 3.3 Empty files

**D:** Empty files are skipped. [D1]

**S/I:** Empty/whitespace-only project files add no instructions and consume no budget, but the directory slot is chosen by file existence before content is read. Thus an empty project override suppresses its sibling `AGENTS.md`; an empty global override instead falls through to global `AGENTS.md`. [S1][S2][I1: #54755]

## 4. Official baseline vs source/runtime verification

- **Official documentation baseline (D):** the current OpenAI pages establish the intended convention: global-first chaining, root-to-cwd project walk, one file per directory, override-before-`AGENTS.md`-before-fallbacks, blank-line joining, empty-file skipping and the 32 KiB default. They are the right citation for product convention, but the pages disagree on whether the byte limit is per-file or cumulative. [D1][D2][D3][D4]
- **First-party source verification (S):** upstream `openai/codex` source and tests at retrieved `main` establish the implementation details: shared cumulative budget, raw-byte truncation, separators, zero-limit behavior, untrusted-project skip, marker configuration source, fallback-name sanitization and the empty-override slot nuance. This is source-level verification, not a claim about any installed Codex release. [S1][S2][S3][S5]
- **Runtime verification (U):** no Codex process, TUI session or `codex exec` run was performed in this pass, so no live prompt or log was inspected. The official guide's proposed audit methods are `codex --ask-for-approval never "Summarize the current instructions."`, `codex --cd subdir ...`, a TUI `log_dir` log, or session JSONL files. A first-party request asks for a `codex debug agents-md` subcommand, which should not be assumed available. [D1][I1: #30788]
- **Local environment observation, not behavior proof:** this machine's `C:\Users\bvlou\.codex` contains `AGENTS.md` and no `AGENTS.override.md`, and its `config.toml` has no explicit `project_doc_*` or `project_root_markers` keys as inspected in this pass. This says nothing about how a given Codex release applies discovery. [Local read-only inspection]

**What would settle the open questions:** run the targeted Codex release in a temporary Git repository with distinct strings in global/root/nested files, then inspect the TUI log or session JSONL to confirm loaded sources and ordering. Repeat with an empty override and with oversized files to distinguish documented behavior from the source-level nuances above. [D1][S1][I1: #54755]

## Primary sources

- **D1** â€” [Custom instructions with AGENTS.md](https://developers.openai.com/codex/agent-configuration/agents-md) (also mirrored at `/codex/guides/agents-md` and `learn.chatgpt.com/docs/agent-configuration/agents-md`; the developer URL redirected in related retrievals).
- **D2** â€” [Advanced Configuration](https://developers.openai.com/codex/config-advanced) (Project root detection; Project instructions discovery; also `/codex/config-file/config-advanced`).
- **D3** â€” [Sample Configuration](https://developers.openai.com/codex/config-file/config-sample).
- **D4** â€” [Configuration Reference](https://developers.openai.com/codex/config-reference).
- **D5** â€” [Customization](https://developers.openai.com/codex/concepts/customization).
- **D6** â€” [AGENTS.md cross-ecosystem site](https://agents.md/).
- **S1** â€” [openai/codex: `codex-rs/core/src/agents_md.rs`](https://github.com/openai/codex/blob/main/codex-rs/core/src/agents_md.rs).
- **S2** â€” [openai/codex: `codex-rs/codex-home/src/instructions/mod.rs`](https://github.com/openai/codex/blob/main/codex-rs/codex-home/src/instructions/mod.rs).
- **S3** â€” [openai/codex: `codex-rs/config/src/config_toml.rs`](https://github.com/openai/codex/blob/main/codex-rs/config/src/config_toml.rs).
- **S4** â€” [openai/codex: `codex-rs/protocol/src/prompts/base_instructions/default.md`](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/prompts/base_instructions/default.md).
- **S5** â€” [openai/codex: `codex-rs/core/tests/suite/agents_md.rs` at `31519549`](https://github.com/openai/codex/blob/31519549/codex-rs/core/tests/suite/agents_md.rs); older [`project_doc_tests.rs` at `d807d44a`](https://github.com/openai/codex/blob/d807d44a/codex-rs/core/src/project_doc_tests.rs).
- **S6** â€” [openai/codex: `docs/agents_md.md`](https://github.com/openai/codex/blob/main/docs/agents_md.md) (repository stub pointing to the official guide; the repo does not host a separate normative spec).
- **I1** â€” first-party issue reports used only as corroboration of discrepancies: [#36371](https://github.com/openai/codex/issues/36371) (byte-budget wording), [#54755](https://github.com/openai/codex/issues/54755) (empty override), [#37956](https://github.com/openai/codex/issues/37956) (budget semantics/global exemption), [#12115](https://github.com/openai/codex/issues/12115) (nested loading), [#30788](https://github.com/openai/codex/issues/30788) (debug command request), [#22454](https://github.com/openai/codex/issues/22454) (fallback key placement).

## Resolution summary for issue #111

Codex's documented convention is a chained context: load `$CODEX_HOME/AGENTS.override.md` else `AGENTS.md` first, then at most one instruction file per directory from the project root (normally the `.git` root, configurable via `project_root_markers`) down to the current working directory, preferring `AGENTS.override.md` over `AGENTS.md` and then configured `project_doc_fallback_filenames`. Directories below the working directory are not preloaded; the project chain is concatenated root-first with blank lines, empty files are skipped, and `project_doc_max_bytes` (default 32,768) is a shared cumulative budget in the implementation despite one official page describing it per file. Upstream source also shows that an empty project override still occupies its directory's slot and that the global file is outside the byte budget; no live Codex run was performed here, so those last details are source-level verification rather than observed runtime behavior.
