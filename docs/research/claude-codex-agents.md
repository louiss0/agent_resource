# Native Claude Code and Codex Agent definition contracts

Research for [Verify Claude Code and Codex native Agent contracts](https://github.com/louiss0/agent_resource/issues/13), under [Chart Agent Resource: first-release Skills and native Agents](https://github.com/louiss0/agent_resource/issues/1).

**Retrieved:** 2026-10-23 UTC. **Scope:** native local custom-agent resource authoring, discovery, inspection, cloning and lifecycle implications; not a new spawning/orchestration runtime. Both native Agents and Skills are first-release scope, but their schemas, roots, identity and defaults are independent. This note supplies evidence to the product decisions, not a product policy or implementation.

## Executive comparison

| Concern | Claude Code | Codex local clients |
| --- | --- | --- |
| Native standalone definition | Markdown `.md`, YAML frontmatter, Markdown system-prompt body | TOML `.toml`, including a `developer_instructions` string |
| Required authoring fields | `name`, `description` | `name`, `description`, `developer_instructions` |
| Project / personal roots | `.claude/agents/`, `~/.claude/agents/` | `.codex/agents/`, `~/.codex/agents/` |
| Personal-root override | `CLAUDE_CONFIG_DIR` relocates the personal `.claude` tree | `CODEX_HOME` relocates Codex home; source discovers `agents/` beside applicable file-backed config layers |
| Identity | `name`, not filename or local subdirectory | `name`, not filename; legacy config declarations can supply a fallback name |
| Native restrictions | Tool allow/deny lists, conditional permission mode, skills preloading, additional/scoped MCP servers, hooks and other fields | Bounded model/instruction overrides and supported **false-only** feature/skill controls; parent permissions, provider and MCP servers remain authoritative |
| Safe inference from “Do not edit” prose | Behavioral instruction, not filesystem enforcement | Behavioral instruction, explicitly **not** a separate read-only sandbox |

These are **official documentation** claims except the qualified Codex config-layer discovery observation, which is **pinned source**. Detailed evidence and qualifications follow. [C1][C2][O1][O2][O3][S2][S4]

**Do not conflate:** `AGENTS.md` / `CLAUDE.md` are instruction/context files, not custom-agent definitions. Nothing in the reviewed Agent contracts establishes `.agents/agents/` as a shared native root. Agent Skills fields (such as `allowed-tools`, `license`, `compatibility`, or `SKILL.md` layout) and its naming rules do not become Agent requirements. In particular Claude uses `disallowedTools`, not a Skill's `disallowed-tools`. [C1: Frontmatter reference][C2: Frontmatter fields by file][O1: Custom agents][O4]

## Evidence, method and version boundary

Evidence labels used below:

- **D — official docs:** first-party authoring/configuration documentation as retrieved, not an immutable release specification.
- **S — pinned source:** a specific first-party source revision, without running it. Source observations are not proof of the installed/released clients' behavior.
- **I — inference:** consequences for inert resource management derived from cited facts, not a chosen product contract.
- **U — unknown:** not established in this bounded pass; do not fill the gap with universal defaults.

The original worker had no browser/search web tool. Retrieval used direct HTTPS (`curl` / PowerShell) and GitHub API (`gh`); files were read, not executed. The worker saved this report before a usage-limit interruption prevented publication. During recovery, the parent reviewed the report and rechecked the two primary subagent documents and pinned Codex role parser through direct web retrieval. No packages were installed, no Claude/Codex process or resource was run, and no runtime/OS/security certification is claimed. Examples below are **inert authoring illustrations**, not tests.

The requested starting URLs were retrieved independently. `https://developers.openai.com/codex/subagents.md` and the old `multi-agent.md` both redirected to `https://learn.chatgpt.com/docs/agent-configuration/subagents.md`. Citations use the current official target. The Claude page remained `https://code.claude.com/docs/en/sub-agents.md`. Exact retrieved UTF-8 response-byte SHA-256 digests:

| Primary document | SHA-256 |
| --- | --- |
| Claude sub-agents Markdown | `84b2646c513754ef5f33c6f5a0d7f59960021a65b5a09c35b9158fa116a73d5a` |
| Codex subagents Markdown | `e7469d41c5a18a4ee66ee40ca4a9a2617a697e42554a0198ac4481e1e597357f` |

**S:** Codex source reviewed at [`8531184b49bcb160175a84e140b659a83a426df7`](https://github.com/openai/codex/commit/8531184b49bcb160175a84e140b659a83a426df7), main HEAD returned by GitHub during retrieval, commit timestamp `2026-10-23T02:21:49Z`. It is **not** claimed to be a release pin. GitHub's latest non-prerelease endpoints returned Claude [`v2.1.309`](https://github.com/anthropics/claude-code/releases/tag/v2.1.309) (published 2026-10-22) and Codex [`rust-v0.163.0`](https://github.com/openai/codex/releases/tag/rust-v0.163.0) (published 2026-10-15). Claude's tag resolved to `65823ec0034ed0aa0266bc43903fefd3ff94a327`; its [pinned changelog](https://github.com/anthropics/claude-code/blob/65823ec0034ed0aa0266bc43903fefd3ff94a327/CHANGELOG.md) was also consulted for version context. These are provenance observations, not a claim that those releases implement every live-doc field. **U:** minimum Codex release for the full current standalone schema was not established.

## 1. Claude Code native definitions

### 1.1 Roots, discovery, precedence and collisions

**D:** Native project and user definitions are Markdown files in `.claude/agents/` and `~/.claude/agents/`. Both are scanned **recursively**; subdirectories do not alter identity, which comes from `name`. Project discovery walks from the working directory to the repository root and scans each `.claude/agents/` on that route. Where nested project directories define the same name, the definition nearest the working directory wins. Additional directories supplied through `--add-dir` / `/add-dir` also contribute `.claude/agents/`. [C1: Choose the subagent scope]

**D:** Cross-scope same-name priority is: **managed definitions > `--agents` session JSON > project > user > plugins**. Within a single scope tree, duplicate names load only one definition, selected by filesystem read order, **not a documented deterministic tie-break policy**. The docs describe `/doctor` reporting same-directory name duplicates. Plugin folders are recursive too, but a plugin subfolder changes its scoped identifier: `agents/review/security.md` in `my-plugin` registers as `my-plugin:review:security`. That is not how local project/user subfolders behave. [C1: Choose the subagent scope]

**D:** On Windows `~/.claude` means `%USERPROFILE%\.claude`. Setting `CLAUDE_CONFIG_DIR` relocates **every personal `~/.claude` path** on the directory-reference page, so personal agents live under `<CLAUDE_CONFIG_DIR>/agents/`; this is not evidence that project `.claude/agents/` is renamed. The environment reference allows the override in shell, user or managed settings, not project/local settings; settings-file paths must be absolute, with no shell expansion. [C2: introductory location rules][C3: CLAUDE_CONFIG_DIR; Set environment variables]

**D:** Other definition sources exist but are not ordinary install roots: managed Markdown under the managed settings directory's `.claude/agents/`, plugin `agents/`, and session-only `--agents` JSON. In JSON, keys supply names and `prompt` replaces the Markdown body; `color` and `experimental` are ignored there. JSON-file input to `--agents` is documented for non-interactive mode only from v2.1.281. Plugin agents ignore `hooks`, `mcpServers`, `permissionMode`, and `initialPrompt`, so copying a plugin definition to project/user scope can activate previously ignored declarations. [C1: Choose the subagent scope; Frontmatter reference]

**D:** Built-ins include Explore, Plan, general-purpose and helper types; user/project `name: Explore` can override the built-in Explore. Built-ins are not local files that a resource manager owns. Their availability also depends on CLI/environment/session configuration. [C1: Built-in subagents]

### 1.2 Authoring schema and instruction sources

**D:** A file starts with YAML frontmatter between `---` markers; Markdown after the closing marker becomes the system prompt. Only `name` and `description` are required. Filename need not match the name. The current name contract is **at most 256 characters, no colon, no leading hyphen**; the first two constraints are in the field table and the leading-hyphen rejection in the skipped-files section. The docs do **not** prescribe an Agent Skills lowercase-ASCII/hyphen-only regex or a Skill-style 64-character maximum. They do not fully specify empty/non-string field coercions or character-count units. [C1: Write subagent files; Frontmatter reference; Subagent files Claude Code skips]

**D — complete current frontmatter inventory:** [C1: Frontmatter reference]

| Field(s) | Required? | Declared meaning / values |
| --- | --- | --- |
| `name`, `description` | Yes | Identity and delegation guidance respectively; name constraints above |
| `tools`, `disallowedTools` | No | Comma-separated string or YAML list; tool allowlist / denylist, including MCP patterns |
| `model` | No | `sonnet`, `opus`, `haiku`, `fable`, full model ID, or `inherit`; not a fixed portable model catalog |
| `permissionMode` | No | `default`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`, `plan`; `manual` aliases `default`; conditional at runtime |
| `maxTurns` | No | Maximum agentic turns; limit output can be partial and resumed; full numeric/coercion contract not specified here |
| `autoCompactWindow` | No | Token count `100000` through `1000000`; lower window only; v2.1.296+ |
| `skills` | No | Names of Skills to preload, full contents, first 32 distinct names; not an access allowlist |
| `mcpServers` | No | List of configured-server names and/or inline name-to-server-config maps; inline types `stdio`, `http`, `sse`, `ws` |
| `hooks` | No | Subagent-scoped lifecycle hook configuration, using the hook schema; may reference executable commands |
| `memory` | No | `user`, `project`, `local`; persistent Agent memory, conditional on auto memory being enabled |
| `background` | No | `true` keeps the agent in background; current default spawned-agent behavior is already background |
| `omitClaudeMd` | No | `true` omits user/project/local CLAUDE.md from initial subagent context, with managed-policy qualifications; ignored for main-session agent; v2.1.271+ |
| `effort` | No | `low`, `medium`, `high`, `xhigh`, `max`, subject to selected model support |
| `isolation` | No | `worktree`; temporary git worktree, not a standalone sandbox policy |
| `color` | No | `red`, `blue`, `green`, `yellow`, `purple`, `orange`, `pink`, `cyan` |
| `initialPrompt` | No | Initial user turn for main-session `--agent` / `agent` setting; commands/Skills processed; prepended to user prompt |
| `experimental` | No | Map; currently `cacheTtl: 5m` or `1h`, with subscription/precedence qualifications; other values ignored; v2.1.248+ |

**D:** A normal, non-fork subagent starts with its own prompt plus environment details, the parent-authored delegation message, ordinarily applicable CLAUDE.md instruction hierarchy and git status, and declared preloaded Skills. It does not receive the ordinary Claude Code system prompt or the parent's conversation/previously invoked Skills. `omitClaudeMd` has managed-policy exceptions; lazy-loaded subdirectory instruction files can still load later. Main-session `--agent` and forks have different instruction semantics. `CLAUDE.md`/`AGENTS.md` are therefore dependencies/context, not alternate custom-agent formats. [C1: What loads at startup; Invoke subagents explicitly; Fork the current conversation]

**D:** `model` resolution is per-invocation override > agent field > `CLAUDE_CODE_SUBAGENT_MODEL` default > parent, subject to managed model allowlists/substitution and `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`. Before v2.1.251 the environment default took first priority; FORCE behavior is documented from v2.1.257. `effort` can be overridden per invocation (v2.1.292+) and by `CLAUDE_CODE_EFFORT_LEVEL`. Extended thinking inherits the parent from v2.1.198; the docs say there is no per-subagent thinking setting. Aliases, account/provider availability, fallback models and policy can change the actual model. [C1: Choose a model; Run every subagent on one model; Choose an effort level]

### 1.3 Declared versus effective tools, permission, sandbox, Skills and MCP

**D:** Omitting `tools` inherits the **available-to-subagents** pool, not necessarily every parent tool. `disallowedTools` removes from that pool, then `tools` resolves against the remainder; deny wins. Some built-ins are filtered regardless of declarations, and the foreground/background pools differ. A list resolving to zero tools usually prevents launch. Tool names can be absent, misspelled or dynamically unavailable; listing them is not proof that they can be used. [C1: Available tools; Restrict which tools a subagent can use]

**D:** MCP patterns support entries such as `mcp__github__*`, deny `mcp__github` / `mcp__github__*`, or deny all `mcp__*`. A `disallowedTools` specifier like `Bash(git push *)` removes the **entire Bash tool**, not just those commands; command-specific deny rules belong in session permissions. `Agent(worker, researcher)` allowlist syntax is restricted to main-session `--agent` use; a subagent's parenthesized type list is ignored. [C1: Restrict which tools a subagent can use; Restrict which subagents can be spawned]

**D:** A subagent inherits the parent's permission rules. Its `permissionMode` is not unconditional authority: parent `bypassPermissions`, `acceptEdits`, or `auto` overrides the field; parent `plan` normally keeps it in plan mode; under parent `default`/`dontAsk`, the field generally applies, but it cannot independently enter bypass and unavailable auto falls back. Bypass prevention is documented from v2.1.267. There is no separate native `sandbox` field in the Agent table. `isolation: worktree` isolates a checkout, with documented command/location checks and OS qualifications, not a general no-write security guarantee. [C1: Permission modes; Write subagent files]

**I:** “Read-only” prose or removing Edit/Write while keeping a shell/MCP tool does not prove no writable side effects through the remaining tools. Report a declared tool surface and permission mode, not a certified read-only runtime. This follows from the independent tool, permission and hook controls, and from the docs' separate conditional hook example for restricting operations inside Bash. [C1: Restrict which tools a subagent can use; Conditional rules with hooks]

**D:** `skills` is a **preload list**, not a restriction to those Skills. Subagents can discover and invoke other project/user/plugin Skills through `Skill`. Missing/disabled preloads are skipped with a debug warning; `disable-model-invocation: true` Skills cannot be preloaded. Removing the Skill tool prevents invoking Skills through that tool, but does not erase already-injected prompt text. Memory also affects tools: enabling `memory` automatically enables Read/Write/Edit for memory management, and auto-memory-off makes that field ineffective. [C1: Preload skills into subagents; Enable persistent memory]

**D:** Parent MCP tools are inherited unless tool filtering removes them. `mcpServers` can reference a configured server using the parent's connection or define inline servers connected for the Agent's lifetime (also applicable when used as main-session agent). Merely listing `mcpServers` is not documented as an exclusive server allowlist. Inline declarations can start processes or make network connections **when the harness runs**; inspecting the YAML must not connect them. Project/additional-directory inline servers require trust for the folder containing the definition (v2.1.238+); parent-folder trust is insufficient. User/session/managed declarations and references have different trust rules. Strict/bare/managed MCP policies may skip servers with warnings. [C1: Scope MCP servers to a subagent; Trust required for inline MCP servers]

**D:** Hooks in Agent frontmatter are scoped lifecycle declarations; settings/managed/plugin hooks also apply inside subagents. Project frontmatter hooks require trust for the file's folder (v2.1.218+), unlike some settings-hook cases; user/session hooks do not require that project grant. `Stop` is converted to `SubagentStop` when invoked as a subagent. **I:** a hook reference is an execution-bearing dependency, not an inert instruction paragraph, even though an offline definition manager need not execute it. [C1: Define hooks for subagents]

### 1.4 Malformed, unknown and reload behavior

**D:** Unknown/misspelled frontmatter fields are ignored without a session error; camelCase must match. From v2.1.296, debug logs can name up to five unrecognized top-level fields and suggest close matches. Missing `name` or an opening `---` not on the first line is treated as documentation; missing `description`, invalid name constraints, or unparseable YAML skips the file, with documented debug logging for the latter cases. Plugin missing-name/invalid-YAML fallback differs: it may still load under filename. This means “exists on disk”, “parses”, “loads”, and “has its intended effects” are separate states. [C1: Frontmatter reference; Subagent files Claude Code skips]

**D:** `claude plugin validate <agents-directory>` is documented from v2.1.233 for YAML parse checks, but does not flag parseable files without `name`; it is **not** a complete native-agent schema validator. We did not run it. Invalid `autoCompactWindow` can leave the agent loaded while the field is ignored (the docs warn that `200k` reads as 200). **U:** the docs do not specify every optional-field type/range/coercion failure or duplicate-YAML-key behavior; no full parser audit was performed. [C1: Check an agents directory before a session; Set the auto-compact window for one subagent]

**D:** Existing project/user agent directories are watched; additions/edits update subsequent delegation after seconds. Restart is needed for a newly created first `agents/` directory, changes inside `--add-dir` agent directories, or sessions disabling slash commands (no watcher). `/agents` now prints editing guidance; v2.1.197 and earlier had a management wizard. These current-doc lifecycle distinctions matter more than stale wizard screenshots. [C1: Quickstart; Write subagent files]

## 2. Codex native definitions

### 2.1 Roots, config overrides, discovery and name collisions

**D:** Local Codex clients support one custom Agent per standalone TOML file, under personal `~/.codex/agents/` or project `.codex/agents/`. Identity is the `name` field; matching the filename is a convention, not a requirement. Custom same-name definitions override built-ins (`default`, `worker`, `explorer`). Current docs say subagent workflows are on by default, while `[agents].enabled` can disable tools; that is session configuration, not a requirement to execute a managed resource. [O1: Custom agents; Global settings]

**D + S:** `CODEX_HOME` defaults to `~/.codex`. General config precedence is CLI > trusted project layers (closest working directory wins) > selected profile file > user config > cloud-managed defaults > system config > built-ins, with enforced requirements separate. Project-root discovery is configurable through `project_root_markers`. **Pinned source** discovers `agents/` beside each enabled config layer that has a `config_folder()`; user/profile file parents, project `.codex/` folders and system-file parents qualify, whereas session flags/MDM/cloud-only sources do not have such a folder. Thus `<CODEX_HOME>/agents/` follows the user-config location; there is more source-observed layering than the two authoring roots alone. Do not present arbitrary system locations as a new recommended install destination. [O2: Configuration precedence][O3: Config and state locations; Project root detection][S2: load_agent_roles][S4: config_folder, layers_low_to_high]

**S:** At the pin, discovery recursively collects files whose extension is exactly `toml`, sorts their paths, and parses them. In one directory tree, the first sorted valid same-name definition is retained and later duplicates generate warnings. Within a config layer, explicit `[agents.<name>]` declarations are processed before auto-discovered files; an explicitly referenced file is not rediscovered. Other same-layer name collisions warn and retain the first. Across low-to-high enabled layers, higher-layer role metadata wins with missing `description`, `config_file`, or `nickname_candidates` filled from the lower-layer declaration. This is **metadata fallback**, not proof of merging every setting from two different role files. [S1][S2: load_agent_roles; merge_missing_role_fields; discover_agent_roles_in_dir]

**S:** The loader iterates enabled layers, excluding disabled ones. Combined with documented project trust gating, a visible project Agent file is not sufficient proof of runtime discovery. **U:** canonical/symlink/casefold equivalence and portable same-name behavior across filesystems are not established by this source excerpt; lexical sort order is not a product identity or collision policy. [O2: Configuration precedence][S4: layers_low_to_high][S2]

**D + S — coexistence with config-declared roles:** The config reference still documents `[agents.<name>].description` and `.config_file`, with relative paths resolved against the declaring config file. The pin additionally supports `nickname_candidates` metadata. A referenced role file can supply/override name and description; a legacy name hint permits missing name and missing `developer_instructions` in a referenced layer, unlike auto-discovered standalone files. The current standalone authoring requirement remains all three fields. Do not reject every existing legacy config role merely because it is not a self-contained new standalone file, or use legacy leniency to omit required fields in a new standalone definition. [O5: agents.<name> entries][S2: read_declared_role][S3: parse_agent_role_file_contents; validate_agent_role_file_developer_instructions][S5: AgentsToml, AgentRoleToml]

### 2.2 Schema, accepted values and instruction files

**D:** Every standalone custom-agent file must define string `name`, `description`, `developer_instructions`. `description` explains when to use the Agent; `developer_instructions` contains its behavioral instructions. There is no Markdown-body convention or documented required companion instruction file. Model knobs are `model`, `model_reasoning_effort`, `model_reasoning_summary`, `model_verbosity`. [O1: Custom agent file schema]

| Declaration | Documented values / effect | Evidence |
| --- | --- | --- |
| `model` | String model identifier; availability depends on client/account/provider. No closed static model catalog is established by this schema | D [O1][O5] |
| `model_reasoning_effort` | Supported by selected model/client; reference gives examples `low`, `medium`, `high`, `xhigh`, `max`, `ultra`, **not an exhaustive universal enum** | D [O1: Choosing models and reasoning][O5: model_reasoning_effort] |
| `model_reasoning_summary` | `auto`, `concise`, `detailed`, `none` | D [O5] |
| `model_verbosity` | `low`, `medium`, `high` | D [O5] |
| `[features]` supported keys set to `false` | `shell_tool`, `apps`, `plugins`, `memories`, `request_permissions_tool`; reductions only | D [O1] |
| `[[skills.config]]` | Per-skill `path`, `enabled = false`; path-bearing reference, not Skill content | D [O1][O5] |
| `[skills.bundled] enabled = false` | Disable bundled Skills | D [O1] |
| `[skills] include_instructions = false` | Omit automatic Skill instruction block; not a sandbox rule | D [O1] |

**S:** The parser trims `name`, rejects a missing/blank standalone name, rejects a provided blank description and requires a nonblank standalone `developer_instructions`. A missing description is rejected after layer fallback in the loader. No lowercase-ASCII regex, Skill-style max length, or requirement that name match filename is visible in the reviewed role-name parsing. Optional **`nickname_candidates`** has its own separate source validation: nonempty list of nonblank unique trimmed names using ASCII letters/digits/spaces/hyphens/underscores. That nickname restriction is **not** the Agent `name` contract and is not in the current standalone field table. [S3][S2: validate_required_agent_role_description]

**D:** Resolve model and effort first from explicit spawn values > `[agents]` defaults > parent; selecting a new model with no explicit/default effort uses that model's default. Then the custom Agent file's explicit model/effort wins. A file setting only `model` preserves the previously resolved effort, so a model change can require an explicit compatible effort too. These are session-resolution rules, not values an offline manager should silently materialize into every definition. [O1: Choosing models and reasoning; Custom agents]

**D:** AGENTS.md guidance is a separate global/project chain: Codex home `AGENTS.override.md` or `AGENTS.md`; project root to working directory with per-directory override/fallback names, bounded by configuration. It does not declare a named role. **S:** role application replaces the `developer_instructions` setting when provided, but does not replace base instructions; the role override projection does not include the general config's `model_instructions_file`. **U:** this pass does not reconstruct every instruction message ordering/fork/resume variant. Do not claim standalone `developer_instructions` is the entirety of effective instructions or that an arbitrary external instruction-file key works as a native Agent prompt. [O4: How Codex discovers guidance][S6: apply_role_to_config_inner; role_overrides::build_next_config][S5: ConfigToml.model_instructions_file]

### 2.3 Restrictions, inheritance and runtime authority

**D:** Custom Agents inherit the parent's **permissions, sandbox/approval settings, provider and MCP servers**. The current subagent docs expressly say `sandbox_mode`, `approval_policy`, `model_provider`, `mcp_servers` placed in a custom Agent file cannot override the parent. Configure MCP and permission boundaries on the parent session. “Do not edit files” in the prompt is not a separate read-only sandbox. The docs' `docs_researcher` example refers to a server configured in project `config.toml`, not a per-Agent exclusive MCP grant. [O1: Approvals and sandbox controls; Custom agents; Custom agent file schema]

**D + S:** Reductions use the supported false-only feature keys and Skill settings above. At the pin the projection accepts only `false` for the enumerated capabilities, retains only disabling Skill entries, drops Skill context-budget overrides, and does not grant new servers or permissions. Setting supported keys to `true` is not a mechanism for adding capabilities the parent lacks. Managed requirements still apply. There is no documented Claude-like arbitrary `tools: Read, Bash` per-Agent allowlist, nor per-Agent MCP server declaration, in the current standalone authoring contract. [O1: Custom agent file schema][S6: apply_role_to_config_inner]

**I:** Disabling shell tools reduces a surface; it does not certify all side effects read-only while inherited MCP/apps/other tools remain. Similarly `skills.include_instructions = false` is an instruction-block change, not proof all Skill-related knowledge/capabilities are inaccessible. Report the actual declaration and inheritance boundary instead of translating either into a universal “read-only Agent” flag. [O1][S6]

**S versus D discrepancy:** The current docs say service tier follows the root session. The pinned role projection nevertheless contains `personality` and `service_tier` overrides, and its unit-test source asserts an explicit service-tier override. This is evidence of a narrower documentation versus evolving source boundary, **not** a basis to promise per-Agent service tier in a released client. Other call paths may further affect it. Keep these as source-only observations/unresolved release behavior, not additions to the documented portable schema. No tests were executed. [O1: Custom agent file schema][S6: AgentRoleOverrides; role_overrides::build_next_config][S7: apply_role_reports_explicit_service_tier]

### 2.4 Malformed/unknown handling and lifecycle limits

**S:** The pinned role parser reports invalid TOML/deserialization errors, blank required values and invalid nickname metadata. The layered loader collects `Ignoring malformed agent role definition: ...` startup warnings and skips invalid files/declarations/duplicate names; directory-read errors can propagate instead. Its no-layer fallback uses error returns, so “every invalid Agent is silently ignored” is wrong. Role application can also fail after discovery: unknown role reports `unknown agent_type ...`; load/apply failures map to `agent type is currently not available` with tracing detail. [S3][S2: push_agent_role_warning; load_agent_roles_without_layers; discover_agent_roles_in_dir][S6: apply_role_to_config]

**S + U:** `RawAgentRoleFileToml` declares Serde `deny_unknown_fields` while flattening the broad `ConfigToml`. That shows intended top-level unknown-field rejection at this pin, but is **not** a complete stable public specification of every flattened/nested unknown-field edge case. Many known session keys can parse as `ConfigToml` and nevertheless be dropped by bounded role application. Thus “valid TOML”, “recognized config field”, and “effective per-Agent override” are three different claims. The live authoring docs do not exhaustively specify unknown-field/error behavior, and this pass did not execute parser probes or audit all nested deserializers. [S3: RawAgentRoleFileToml][S5: ConfigToml][S6: apply_role_to_config_inner][O1]

**D:** `[agents]` global settings currently document `enabled`, `max_concurrent_threads_per_session` (legacy alias `max_threads`), `default_subagent_model`, `default_subagent_reasoning_effort`, and `interrupt_message`. They are not per-file authoring requirements or a resource manager's lifecycle defaults. **U:** a stable standalone-file hot-reload/deletion/in-flight-agent contract and exact minimum version for the new standalone discovery format were not established. Do not project Claude's watcher semantics onto Codex. [O1: Global settings]

## 3. Definition-management implications (not product decisions)

The following are **I**, grounded in the native contracts above. They inform the confirmed [first-release native Agent workflow scope](https://github.com/louiss0/agent_resource/issues/14): native management, composition/dependency/capability inspection, and bidirectional portability/conversion are all required. These implications do not select the remaining native model, ownership, composition or conversion policies.

| Operation | Evidence-backed boundary / implication |
| --- | --- |
| Create | Native local files can be authored without launching a harness: Claude requires YAML `name`/`description` with Markdown prompt; Codex standalone requires all three strings. Any convenience defaults for tools, model, sandbox-related prose, scope or name generation must be an explicit Agent policy, not inherited Skill policy. [C1][O1] |
| Clone | A byte-preserving **definition copy** is possible, but preserving behavior is not guaranteed: same `name` may shadow an Agent/builtin, trust/scope changes can activate hooks/MCP, and references/relative paths may change meaning. Rename and identity changes require explicit intent. [C1: Choose the subagent scope; Define hooks for subagents][S2][S3] |
| Discover | Distinguish raw candidate files, parseable definitions, effective name winners/shadowed duplicates, unavailable/ignored definitions, and external managed/plugin/config-declared sources. Native recursive scope differs from any previous direct-child Skill adoption rule. Effective resolution needs working directory, native home override, config layers, trust and profile—not just a recursive file glob. [C1][O2][S1][S2][S4] |
| Inspect | Can statically report source/path, scope, name, format, declared fields, native schema evidence version, references and known unsupported/ignored declarations. Cannot certify available tools/models, current MCP connectivity, policy grants or actual sandbox enforcement without runtime/environment evidence. Explicit inherited/unknown states are more accurate than invented effective defaults. [C1: Available tools; Choose a model][O1] |
| Validate | Separate syntax, documented authoring correctness, source-observed leniency/rejection, reference existence and optional heuristic instruction review. Unknown-field lint matters especially where Claude ignores typos and Codex recognizes-but-drops session settings. A valid file is not proof of loadability or enforcement in every version. [C1: Frontmatter reference; Subagent files Claude Code skips][S3][S6] |
| Edit/update/remove | File writes affect definitions, not automatically running instances, transcripts, memory, MCP state or worktrees. Claude's watchers have explicit exceptions; Codex reload remains unknown. Definition deletion can expose a lower-priority same-name definition/builtin. Backup/rollback ownership and reference rewriting require product rules. [C1: Write subagent files; Resume subagents; Enable persistent memory][S2][S6: resolve_role_config] |
| Composition | Neither native schema establishes a universal Agent `extends`/merge/dependency-install engine. Claude preloaded Skills, hooks/MCP references and optional nested-agent tool use differ from Codex Skill disables and parent MCP inheritance. Do not confuse runtime delegation with resource-definition composition. [C1][O1] |

### Copy closure and lifecycle hazards

**I:** A single-file clone can retain its text but omit its behavioral closure: Claude Skill names, MCP names/inline command paths/environment references, hook scripts, memory directories, provider-specific model IDs; Codex Skill paths, legacy `config_file`, parent config/MCP/provider/policies and AGENTS.md context. Claude memory lives separately at `~/.claude/agent-memory/<name>/`, `.claude/agent-memory/<name>/`, or `.claude/agent-memory-local/<name>/`; transcripts have their own retention. Copying/removing memory or transcripts is not implied by copying/removing a definition. Global/home overrides and scope moves can alter the reference base. [C1: Enable persistent memory; Scope MCP servers to a subagent; Define hooks for subagents; Resume subagents][O1][O4][O5: agents.<name>.config_file][S3][S6]

**I:** Definition management can stay inert: read/parse/copy/report declarations without invoking hooks, connecting MCP, loading external code, spawning agents or calling harness-native validation. Runtime-capability inspection would be a separately authorized feature with different trust, process and network boundaries. This is compatible with first-release native Agent management; native support does not itself demand a runtime. [C1: Define hooks for subagents; Scope MCP servers to a subagent][O1]

## 4. Portability: what conversion cannot preserve automatically

All entries below are **I**, not a proposed conversion policy:

- **Prompt authority/shape:** Claude Markdown is an Agent system prompt; Codex `developer_instructions` is a bounded developer-instruction override alongside inherited session/base/project instructions. Moving prose is possible; claiming identical instruction hierarchy is not. [C1: What loads at startup][O1][O4][S6]
- **Models/reasoning:** Claude aliases/`inherit`/`effort` and Codex model IDs/`model_reasoning_effort`/summary/verbosity have different values, defaults and override order. No name-only mapping ensures access, behavior, cost or compatible effort. [C1: Choose a model; Choose an effort level][O1][O5]
- **Tool and permission constraints:** Claude arbitrary tool allow/deny lists and conditional permission mode cannot be represented by Codex's limited feature disables. Codex cannot acquire a per-Agent sandbox by copying Claude `permissionMode: plan`, nor does a prose “read-only” conversion retain enforcement. [C1: Control subagent capabilities][O1]
- **MCP/Skills:** Claude inline scoped MCP, hook policies and Skill **preloading** do not map to Codex parent MCP inheritance and Skill **disabling**. Even same-name Skills/servers may refer to different content/configuration. [C1: Scope MCP servers to a subagent; Preload skills into subagents][O1]
- **Lifecycle:** Claude `memory`, hooks, `isolation`, `maxTurns`, `autoCompactWindow`, color/background/initialPrompt/experimental fields lack corresponding documented Codex standalone authoring controls here. Converting a definition does not migrate active threads, historical transcripts, memory, installed dependencies or worktree state. [C1: Frontmatter reference][O1]
- **Discovery/identity:** Different scope precedence, legacy config fallback, plugin namespaces, builtin overrides, home-root configuration and collision behavior prevent a universal native Agent identity/destination rule. `.agents/agents/` cannot be offered as native shared discovery on this evidence. [C1: Choose the subagent scope][O1][S2][S4]

## 5. Sharp open decisions and bounded unknowns

### Product decisions (not answered by research)

1. **Workflow breadth — resolved separately:** The human confirmed native management, composition/dependency/capability inspection, and Claude↔Codex portability/conversion in the first release. Definition management remains inert; no new spawning runtime or hidden probes. Detailed models, policies and interfaces remain for their decision tickets, not this research.
2. **Native profiles/version policy:** Track current-doc standalone authoring only, support legacy Codex config roles too, or offer explicit profile versions? How should source-only observations and known ignored session keys appear in diagnostics?
3. **Identity and collision policy:** How are file identity, native `name`, installed ownership and shadowing represented? What happens for duplicates, builtin names, nested project scopes, Codex trimmed names, and case-sensitive names on case-insensitive filesystems? No automatic carryover of Skill uniqueness/naming rules.
4. **Scope/discovery boundary:** Will management write only normal project/user roots while reporting managed/plugin/system/config-declared definitions read-only? Which home/config override, current directory, trust/profile context is explicit, and how are unavailable inputs distinguished from absent resources?
5. **Clone/update/remove closure:** Definition only or referenced dependencies/memory too? Are paths rewritten, names changed, identity retained, lower-priority definitions exposed, and execution-bearing declarations preserved inertly? What requires confirmation and backup?
6. **Correctness versus lint:** Should unknown fields, native ignored fields, version gates and questionable “read-only” prose be errors, warnings or advisory lint? Research establishes facts, not that policy. Preserve original bytes/unknown fields or canonicalize only by explicit operation?
7. **Portability/loss:** Conversion is confirmed first-release scope, including real representable cases in both directions. Decide rejection versus explicitly consented lossy drafts and field-by-field diagnostics in the conversion ticket. A universal capability schema cannot erase parent/session dependence.

### Residual evidence unknowns (do not block the bounded evidence pass)

- Exact released Codex minimum versions for standalone directories, required-field transitions, bounded override behavior and hot reload; current docs are not a release matrix.
- Full malformed optional YAML value/coercion/duplicate-key behavior in Claude; full flattened/nested unknown TOML behavior in Codex; no executable parser probes were run.
- Precise filesystem case/Unicode normalization, symlink/hardlink/cycle and hostile-race handling across harness/platform versions; not an OS audit.
- End-to-end service-tier behavior where current Codex docs and pinned projection/test source differ; source-only `personality`/nickname metadata are not automatically public authoring promises.
- Full effective runtime capability set under account/model/provider, managed policy, trust, plugin, session flags, foreground/background/fork/resume state and live MCP connections. That requires exact-environment runtime evidence and remains outside this definition-management research.

## Sources

Every source below was retrieved 2026-10-23 UTC. Named sections beside citations locate the owning claim. Source links are commit-pinned where marked S; documentation URLs are live and hashes above identify the two primary responses.

### Official documentation (D)

- **[C1]** Anthropic, [Create custom subagents](https://code.claude.com/docs/en/sub-agents.md): scope/discovery, file schema, models, tools, permissions, MCP, Skills, hooks, reload, instructions and lifecycle. The page's `supported-frontmatter-fields` anchor is referenced by its own links although its current heading is “Frontmatter reference”.
- **[C2]** Anthropic, [Explore the .claude directory](https://code.claude.com/docs/en/claude-directory.md): personal-root relocation, file-category distinction, Agent frontmatter inventory and separate application state.
- **[C3]** Anthropic, [Environment variables](https://code.claude.com/docs/en/env-vars.md): `CLAUDE_CONFIG_DIR` and variable-setting/path rules.
- **[O1]** OpenAI, [Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents.md), official redirect target of both requested Codex URLs: local-client custom agents, schema, model/effort precedence, inheritance and supported reductions. Hosted ChatGPT Work portions are not treated as local Codex contracts.
- **[O2]** OpenAI, [Config basics](https://learn.chatgpt.com/docs/config-file/config-basic.md): config roots, trust, precedence, enforced requirements versus defaults.
- **[O3]** OpenAI, [Advanced config](https://learn.chatgpt.com/docs/config-file/config-advanced.md): `CODEX_HOME`, project-root markers and Agent-role pointers.
- **[O4]** OpenAI, [Custom instructions with AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md.md): guidance-file discovery versus named custom Agents.
- **[O5]** OpenAI, [Configuration Reference](https://learn.chatgpt.com/docs/config-file/config-reference.md): role config references, model knobs and Skill-path settings. Its `skills.config.path` description says folder containing SKILL.md while O1's example uses a SKILL.md path; this note does not settle that path-form discrepancy as a universal validator rule.

### Pinned first-party source (S)

All Codex links below refer to **`8531184b49bcb160175a84e140b659a83a426df7`**, not a release-certified adapter:

- **[S1]** [`agent-roles/src/discovery.rs`, lines 7–43](https://github.com/openai/codex/blob/8531184b49bcb160175a84e140b659a83a426df7/codex-rs/agent-roles/src/discovery.rs#L7-L43): recursive TOML collection and sorting.
- **[S2]** [`agent-roles/src/loader.rs`](https://github.com/openai/codex/blob/8531184b49bcb160175a84e140b659a83a426df7/codex-rs/agent-roles/src/loader.rs): `load_agent_roles`, `read_declared_role`, metadata fallback, malformed/duplicate warnings and discovery.
- **[S3]** [`agent-roles/src/agent_role_config.rs`](https://github.com/openai/codex/blob/8531184b49bcb160175a84e140b659a83a426df7/codex-rs/agent-roles/src/agent_role_config.rs): standalone versus hinted-role parsing, required values, name trimming, unknown-field annotation and nickname validation.
- **[S4]** [`config/src/state.rs`, config_folder lines 218–232](https://github.com/openai/codex/blob/8531184b49bcb160175a84e140b659a83a426df7/codex-rs/config/src/state.rs#L218-L232), [enabled layers lines 669–689](https://github.com/openai/codex/blob/8531184b49bcb160175a84e140b659a83a426df7/codex-rs/config/src/state.rs#L669-L689): discovery bases and disabled-layer filtering.
- **[S5]** [`config/src/config_toml.rs`](https://github.com/openai/codex/blob/8531184b49bcb160175a84e140b659a83a426df7/codex-rs/config/src/config_toml.rs), especially [AgentsToml and AgentRoleToml lines 760–810](https://github.com/openai/codex/blob/8531184b49bcb160175a84e140b659a83a426df7/codex-rs/config/src/config_toml.rs#L760-L810): broader config schema versus standalone metadata and legacy declarations.
- **[S6]** [`core/src/agent/role.rs`](https://github.com/openai/codex/blob/8531184b49bcb160175a84e140b659a83a426df7/codex-rs/core/src/agent/role.rs), especially [bounded overrides lines 36–127](https://github.com/openai/codex/blob/8531184b49bcb160175a84e140b659a83a426df7/codex-rs/core/src/agent/role.rs#L36-L127): projection, application, custom-before-builtin resolution and source-only service-tier/personality handling.
- **[S7]** [`core/src/agent/role_tests.rs`, lines 329–387](https://github.com/openai/codex/blob/8531184b49bcb160175a84e140b659a83a426df7/codex-rs/core/src/agent/role_tests.rs#L329-L387): assertions about explicit/inherited service tier; test source read, **not executed**.
