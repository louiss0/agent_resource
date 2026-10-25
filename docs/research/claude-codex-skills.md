# Claude Code and Codex skill integration: primary-source findings

Research for [Verify Claude Code and Codex skill integration](https://github.com/louiss0/agent_resource/issues/3).

**Retrieved:** 2026-10-22–23 UTC; individual source dates are in the [source ledger](#source-ledger). **Scope:** native local skill discovery in Claude Code and OpenAI Codex, with distribution/surface caveats. This is evidence, not a product-policy decision or an implementation.

## Evidence boundaries

- **D — documented:** behavior explicitly stated in current first-party documentation or the Agent Skills specification. This means a documented contract, not independently tested behavior on every release/platform.
- **S — source observation:** behavior read from an identified official source snapshot. Codex observations below use release **`rust-v0.163.0`**, commit **`83086188ae0614bd882818ff1aa23f3194962012`**; the release API reports publication on 2026-10-15. Do not extrapolate them to older clients, cloud hosts, or future versions. [O5]
- **I — inference:** a bounded conclusion from a documented procedure, explicitly identified below.
- **U — unknown:** not established by the sources inspected; not evidence that a feature is unsupported.

The requested `web_enable` tool was not present in this worker's toolset or executable path. Official pages and source were retrieved over HTTPS using shell HTTP clients instead. No downloaded skill, installer, validator, script, or harness skill invocation was executed; source was inspected as text. No runtime compatibility matrix was tested.

## Answer in brief

1. **D:** Both products use a skill directory containing `SKILL.md`, with YAML frontmatter and Markdown instructions, and explicitly reference the Agent Skills standard. Optional bundled resources are supported. A common file format does **not** imply identical paths, invocation, permissions, or collision behavior. [A1] [C1] [O1]
2. **D:** Current local destinations differ: Claude Code uses project `.claude/skills/<name>/SKILL.md` and personal `~/.claude/skills/<name>/SKILL.md`; Codex documents repository `.agents/skills/<name>/SKILL.md` and user `$HOME/.agents/skills/<name>/SKILL.md`. [C1] [O1]
3. **D:** Collision semantics differ materially: Claude documents **enterprise > personal > project** for a shared directory/file name, with separate nested/plugin rules; Codex says same-name skills are **not merged and both can appear in selectors**. A universal “project overrides global” rule would misdescribe both. [C1] [O1]
4. **D / I:** Both document manually creating a skill in a discovery location. For an ordinary local standalone skill, their documented creation procedures require **no registration command, manifest, or native-config edit**. This is an inference from those procedures, not a promise to bypass disabled sources, administrator policy, visibility controls, trust settings, or missing dependencies. Plugin distribution and account synchronization are different installation paths. [C1] [C4] [O1] [O3]
5. **D / S:** Both document following symlinked skill folders. Claude explicitly documents loading a shared symlink target once. Codex release source canonicalizes skill identities and deduplicates by path; it does not deduplicate distinct files merely because names match. Plugin symlink restrictions are narrower than standalone-folder support. [C1] [C5] [O1] [S2] [S3]
6. **S:** Codex still reads deprecated `$CODEX_HOME/skills`, and its bundled installer script still defaults there, despite the current docs listing `$HOME/.agents/skills`. Treat that as backward-compatibility evidence, not a reason to rewrite the current documented destination. [S1] [S7]

## 1. Shared format versus host extensions

### Agent Skills baseline

| Item | Established contract |
| --- | --- |
| Layout | **D:** A directory with required `SKILL.md`; `scripts/`, `references/`, `assets/`, and other files/directories are optional. YAML frontmatter precedes Markdown instructions. [A1] |
| Required metadata | **D:** `name` and `description`. Name is 1–64 characters, lowercase alphanumeric/hyphen, no leading/trailing or consecutive hyphens, and must match the parent directory. Description is non-empty, at most 1,024 characters. The spec's prose mentions Unicode lowercase alphanumerics while its summary uses `a-z`/`0-9`; this note does not resolve that wording ambiguity into a broader Unicode guarantee. [A1] |
| Optional standard fields | **D:** `license`; `compatibility` (1–500 characters if supplied); `metadata` (string-to-string mapping); experimental `allowed-tools` (space-separated string). Tool-field support may vary by implementation. [A1] |
| Loading model | **D:** Progressive disclosure: metadata initially, full instructions on activation, supporting resources as needed. Under 500 lines for the main file is guidance, not a mandatory file-size limit. References should be relative to the skill root. [A1] |
| What the spec does not settle | **U:** The format specification does not supply a universal project/global installation directory, duplicate-name precedence algorithm, symlink-installation contract, slash/dollar invocation syntax, or host-specific permission model. Use the host evidence below, not a standard-format assumption. [A1] |

A portable example of the common structural subset is:

```text
review-change/
  SKILL.md
  references/checklist.md       # optional
  scripts/check.sh             # optional; runtime prerequisites still apply
```

```markdown
---
name: review-change
description: Review a proposed change for correctness; use when asked to review a diff.
---
Follow the checklist in references/checklist.md when needed.
```

This illustrates format only; it does not assert that a particular shell script, tool name, model, or permission grant is portable. [A1] [C1] [O1]

### Claude Code's acceptance and extensions

- **D:** Claude Code makes **all frontmatter fields optional**: `name` defaults to the directory; `description` is recommended and otherwise falls back to the first non-empty body line. This is more permissive than the standard's required `name`/`description`. Frontmatter must start on the first line; invalid YAML still allows the skill to load with no fields set; unrecognized field names are ignored. [C1] (§ Frontmatter reference)
- **D:** In personal/project skill directories, frontmatter `name` can differ from the folder name and supplies the advertised invocation name if not already taken; the directory name also invokes it. This differs from the standard's directory-name equality requirement. Legacy `.claude/commands/*.md` files derive their invocation name from the file/subdirectory path and do not support `name` or `paths`. [C1] (§ How a skill gets its command name)
- **D:** Documented non-standard controls include `when_to_use`, `argument-hint`, `arguments`, `disable-model-invocation`, `user-invocable`, `disallowed-tools`, `model`, `effort`, `context`, `agent`, `background`, `hooks`, `paths`, and `shell`. `metadata`, `license`, and `compatibility` are accepted standard fields; Claude Code does not act on their contents as environment enforcement. [C1] (§ Frontmatter reference)
- **D:** `allowed-tools` grants per-turn pre-approval; it is **not a tool allowlist that removes every other tool**. Permission settings still govern unlisted tools; managed policy can withhold the grant. Skill instructions persist beyond that grant's lifetime. [C1] (§ Pre-approve tools for a skill)
- **D:** Host-specific body processing includes `$ARGUMENTS`, indexed/named arguments, `${CLAUDE_SKILL_DIR}` and other Claude placeholders, shell-output injection with `!` backticks or fenced shell blocks, and `context: fork` subagent execution. Those are not Agent Skills format guarantees or Codex equivalents. [C1] (§ Available string substitutions; Inject dynamic context; Run skills in a subagent)
- **D:** Claude Code distinguishes its local skill format from claude.ai uploads/Skills API packaging: the latter allow only the standard six fields listed above and can reject Claude-only fields. Uploading a local skill is not necessarily a lossless way to preserve its Claude Code semantics; Claude-only dynamic context processing does not work in claude.ai chat/API. [C1] (§ Using skill frontmatter outside Claude Code)

### Codex's acceptance and extensions

- **D:** Current authoring docs require `name` and `description` in `SKILL.md`, with optional scripts/references/assets. They add an optional **`agents/openai.yaml`** sidecar for presentation, invocation policy, and tool dependencies. A sidecar is not required for a plain instruction-only skill. [O1]
- **D:** Documented sidecar fields include `interface.display_name`, `short_description`, icons, `brand_color`, `default_prompt`; `policy.allow_implicit_invocation`; and `dependencies.tools` entries, including the documented MCP example. `allow_implicit_invocation` defaults to true; setting false still permits explicit `$skill` invocation. Declaring dependencies is not evidence that every external package, credential, or service will be provisioned automatically. [O1]
- **S:** The pinned parser reads `name`, `description`, and `metadata.short-description`. It requires frontmatter and non-empty description, but falls back to a caller-supplied directory-derived name if `name` is absent/blank. It validates the name's 64-character maximum, not the spec's complete naming grammar, directory-name equality, or description's 1,024-character maximum. This is **release-specific permissiveness**, not the published authoring contract. [S4] [S2] (`default_skill_name`)
- **S:** The inspected frontmatter parser does not interpret Claude's invocation/model/hook controls, or the standard `allowed-tools`, `license`, and `compatibility` fields as operational settings. It does not deny unknown fields in that structure. This establishes only the inspected parser's behavior, not a system-wide guarantee that any arbitrary metadata is always ignored safely. [S4]
- **S:** The sidecar loader returns default metadata if it cannot read/parse the optional file: malformed sidecar metadata does not block `SKILL.md` loading at this layer. Thus a malformed policy sidecar must not be assumed to fail closed and disable implicit invocation. It also parses product restrictions beyond the current skills page's example. [S6]
- **U:** No inspected Codex document promises Claude-style `$ARGUMENTS` substitution, shell-injection syntax, `context: fork`, or Claude tool-permission semantics. Do not translate those fields by name or assume textual portability means behavioral equivalence. [O1] [S4] [S6]

## 2. Locations, discovery, and boundaries

| Scope / behavior | Claude Code | Codex |
| --- | --- | --- |
| Project | **D:** `.claude/skills/<name>/SKILL.md`. Searches launch directory and parents up to repository root. [C1] | **D:** `.agents/skills/<name>/SKILL.md` in every directory from launch CWD up to repository root. [O1] |
| User/global | **D:** `~/.claude/skills/<name>/SKILL.md`, across the user's local projects. Windows `~/.claude` is `%USERPROFILE%\.claude`; `CLAUDE_CONFIG_DIR` relocates the global paths on the directory-reference page. [C1] [C6] | **D:** `$HOME/.agents/skills/<name>/SKILL.md`. This is not documented as `$CODEX_HOME/.agents/skills`. [O1] |
| Enterprise/admin | **D:** `.claude/skills/<name>/SKILL.md` **inside the managed settings directory**. Managed base directories: macOS `/Library/Application Support/ClaudeCode`, Linux/WSL `/etc/claude-code`, Windows `C:\Program Files\ClaudeCode`. Thus the enterprise skill subtree includes the additional `.claude/skills/` component, not just `skills/`. [C1] [C2] | **D:** `/etc/codex/skills` is the documented ADMIN location; SYSTEM skills are bundled by OpenAI. The skills page does not specify a native-Windows replacement for `/etc/codex/skills`. [O1] |
| Nested project directories | **D:** Skills below the startup directory load when Claude first reads/edits a file there, then remain available. They are not initially invocable by name. `/add-dir <subdir>` can load them earlier on v2.1.257+. [C1] | **D:** Parent-chain discovery is documented, not Claude's lazy descendant activation. **U:** Do not assume arbitrary descendant `.agents/skills` directories are discovered without changing the working context. [O1] |
| Additional directory | **D:** `--add-dir`/`/add-dir` loads that directory's `.claude/skills`, commands, and agents; `permissions.additionalDirectories` alone grants access but does not load them. SDK additional-directory options map to the CLI mechanism. [C1] | **S:** The inspected resolver accepts extra skill roots. **U:** That internal argument alone is not a stable public installation/configuration interface for users. [S1] |
| Outside Git | **U:** This note does not establish Claude's complete traversal boundary outside a repository. [C1] | **S:** The inspected root finder falls back to CWD when no configured project marker is found; this is not permission to scan all the way to filesystem root for `.agents/skills`. Custom project-root markers can change boundaries. [S1] |
| Linked worktrees | **D:** Parent search stops at the worktree root. On v2.1.277+, when its root has no `.claude/skills` directory, Claude loads the main checkout's project skills instead. Therefore a fresh worktree can still inherit main-checkout skills. [C1] | **U:** No equivalent main-checkout fallback was established for Codex in the inspected skills docs/resolver. Do not infer it from Claude's behavior. [O1] [S1] |
| Legacy locations | **D:** `.claude/commands/<name>.md` remains supported; commands and skills are merged behaviorally, but skills add resource directories and controls. [C1] | **S:** Resolver still loads user `$CODEX_HOME/skills` (explicitly deprecated in a source comment) and `skills` under eligible project config folders, i.e. legacy `.codex/skills`. These are additional observed paths, not current docs' recommended authoring destinations. [S1] |

**D / U:** Claude's inspected native skills location table does not document `.agents/skills` as an automatically scanned alternative; Codex's current native skills table does not document `.claude/skills` as one. This does not establish an absolute prohibition on interoperability through symlinks, plugins, host integrations, or future releases. [C1] [O1]

**D / U:** Codex configuration precedence is a separate subject: personal config is `~/.codex/config.toml`; project `.codex/` layers require trust. Do **not** use “closest config wins” as proof that same-name skills shadow each other, or assume that project-config trust exactly describes `.agents/skills` discovery. The inspected skills page does not resolve the full untrusted-project skill behavior. [O2] [O1]

## 3. Precedence, duplicate names, and symlinks

### Claude Code

| Situation | Established behavior |
| --- | --- |
| Same directory/file name across enterprise, personal, project | **D:** Enterprise wins over personal; personal wins over project. `/deploy` therefore runs the personal skill when both personal/project directories are named `deploy`. Frontmatter-name aliases have their own collision rules, so do not reduce every alias collision to that table. [C1] (§ Resolve skills that share a name) |
| Skill versus legacy command file | **D:** The skill wins. [C1] |
| Root versus nested same folder name | **D:** Both load. `/deploy` runs the root skill; `/apps/web:deploy` addresses the nested example. Claude also receives directory-qualified variants. [C1] |
| Plugin versus local name | **D:** Both can load because plugins are namespaced `/plugin-name:skill-name`; frontmatter can set the final segment. [C1] |
| Local skill versus bundled/built-in command | **D:** In local terminal sessions, the local skill replaces the named command, not its other aliases. A local `code-review` replaces `/code-review`, not bundled alias `/review`. [C1] |
| Synced claude.ai skill versus existing short name | **D:** The other command keeps the short name; the synced skill remains invocable as `/anthropic-skills:<name>`. The documented Unicode/case normalization checks for synced-name collisions must not be generalized to every local-filesystem collision. [C1] |
| Multiple links to one skill directory | **D:** Enterprise/personal/project skill entries may symlink elsewhere; `SKILL.md` is read from the target and the skill loads once even if multiple locations target it. This is not the same as two distinct folders with equal names. [C1] |
| Reserved names | **D:** Author-created `synced` directories (case-insensitive) are skipped in enterprise/personal/project; `anthropic-skills` and its namespace are reserved outside plugins. Refused/control/invisible characters can prevent loading or name aliases. [C1] |

**D:** Plugin installation has different symlink handling: links inside the plugin are preserved relatively; links elsewhere in the same marketplace are dereferenced/copied; links outside the marketplace are skipped. For local-path/copy-mode plugin installs, only links within the plugin are preserved. A standalone external-target symlink is not a guarantee of a working plugin package. The marketplace docs explicitly note Windows symlink creation may require an elevated `mklink /D` command or Developer Mode. [C5]

### Codex

- **D:** Same-name skills are not merged; both can appear in skill selectors. The current docs do not promise a single winning REPO/USER/ADMIN/SYSTEM definition for a duplicate name. [O1]
- **S:** Host merging deduplicates **skill paths**, then sorts by scope rank **Repo, User, System, Admin**, then name and native path. That order is presentation/loading order, **not evidence of name-based override semantics**. The scope belonging to a repeated canonical path comes from the retained occurrence. [S3]
- **S:** Explicit selection resolves structured selections by canonical or discovery path. Raw plain-name `$name` matching is accepted only when the enabled skill name is unambiguous and does not collide with a connector slug. Therefore the observed release does **not** implement “first scope wins” for an ambiguous raw name; path-bearing selector selections are materially different. This is source behavior, not a promise of identical UX in every client. [S5]
- **D / S:** Symlinked skill folders are documented as supported. The host loader follows directory symlinks for Repo/User/Admin, but not System; it canonicalizes roots and discovered skill paths. Host merging then removes repeated skill paths. [O1] [S2] [S3]
- **S:** Discovery looks for exact `SKILL.md`, skips hidden descendant directories under ordinary host roots, uses a six-level maximum scan depth and 2,000-directory / 20,000-entry per-root traversal caps. Ordinary roots use recursive discovery; direct-child plugin mode additionally rejects skill paths resolving outside the plugin root. These are implementation limits, not Agent Skills standards. [S2] [S8] [S8b]
- **U:** Folder-symlink support does not establish complete Windows junction/reparse-point behavior, standalone `SKILL.md` file-link behavior, cycle/error UX, or live reload after editing an external symlink target on every platform. No such runtime matrix was tested here. [O1] [S2]

## 4. Invocation, discovery metadata, and installation state

| Concern | Claude Code | Codex |
| --- | --- | --- |
| Explicit invocation | **D:** `/skill-name`, ordinarily at the start of a message. A slash name after plain text grants permission for that message but is not direct expansion. [C1] | **D:** `/skills` or `$` mentions in CLI/IDE; the current page distinguishes ChatGPT's `@` selection. Do not advertise `/name` as Codex's documented native syntax. [O1] |
| Automatic activation | **D:** Description-based; `disable-model-invocation: true` makes the skill manual-only; `user-invocable: false` hides/disallows direct user invocation while allowing Claude to invoke it. [C1] | **D:** Description-based; `agents/openai.yaml` `policy.allow_implicit_invocation: false` disables implicit selection but allows explicit use. [O1] |
| Initial context | **D:** Names/descriptions listed, full body on invocation; large catalogs can lose descriptions under a budget, not necessarily names. This affects relevance matching independently of installation. [C1] (§ Skill descriptions are cut short) | **D:** Initial name/description/path list; current docs describe a default 2%-of-context budget, 8,000 characters if unknown. Descriptions can shorten and some skills can be omitted with a warning. `skills.max_context_tokens` can change the budget up to 10,000 tokens. [O1] |
| Manual local installation | **D / I:** Create the folder and `SKILL.md` at a documented location. No registration/config edit appears in the ordinary creation procedure. A plugin manifest is not a plain-skill prerequisite. [C1] | **D / I:** Same filesystem-based procedure at Codex's documented locations. `$skill-installer` is an optional curated/repository installation helper, not required for a manually authored skill. [O1] |
| Reload | **D:** Personal/project/additional-directory skill changes are watched except in bare mode. If the top-level skills directory did not exist at startup, use `/reload-skills`; live detection covers `SKILL.md`, not all embedded plugin components. [C1] | **D:** Detects skill changes/new installations automatically; restart if changes do not appear. Restart after changing `~/.codex/config.toml`. [O1] |
| Disable without deleting | **D:** `skillOverrides` can turn a standalone skill off or make it user-only without editing it. Plugin skills are managed through `/plugin` instead. [C1] | **D:** `[[skills.config]]` with `path = "/path/to/skill/SKILL.md"` and `enabled = false` in `~/.codex/config.toml`; config edits require restart. This entry is an optional disabling control, **not required registration for every skill**. [O1] |
| Distribution as plugin | **D:** Enabled plugins contribute namespaced skills; plugin install/trust/policy requirements are separate from creating a plain skill directory. A `.claude-plugin/plugin.json` inside a skills directory can activate plugin components, subject to trust/policy. [C1] | **D:** Current docs prefer plugins for reusable distribution beyond one repo; this is distinct from direct local discovery. Plugin docs specify a manifest, packaging and install/configuration flow; a standalone skill is not automatically a registered plugin. [O1] [O3] |

**S — installer/documentation divergence:** The release's bundled `install-skill-from-github.py` describes installation into `$CODEX_HOME/skills`; `_codex_home()` defaults to `~/.codex`, and `_default_dest()` appends `skills`. This agrees with the resolver's backward-compatible path but not with the current user-location table's `$HOME/.agents/skills`. No migration date, removal deadline, or earliest `.agents/skills` version is established here. Do not infer that `CODEX_HOME` relocates the separate home `.agents/skills` root. [S7] [S1] [O1]

**D / U — dependencies and permissions:** A discovered skill is not proof that it can run. Claude's `compatibility` is descriptive, `allowed-tools` has host-specific permission behavior, and Codex's sidecar declares tool dependencies rather than defining Claude permissions. Neither the shared format nor the inspected creation procedures promise installation of arbitrary executables, secrets, accounts, network access, or platform tools. [A1] [C1] [O1]

## 5. Platform, version, and surface caveats

### Claude Code

- **D:** Current setup docs support native Windows and WSL, macOS and Linux. Native Windows no longer requires Git Bash: without Git for Windows the shell tool is PowerShell; with it Bash is available. A shell-dependent skill still needs its own compatible commands and prerequisites. Current Windows minimum is Windows 10 1809+/Server 2019+; native Windows sandboxing is not supported, while WSL2 supports it. [C3]
- **D:** Changelog `2.0.20` introduced Claude Skills; `2.1.0` added skill hot reload and forked contexts. These are historical feature entries, **not a claim that the entire current behavior table works on 2.0.20 or 2.1.0**. [C7]
- **D:** Current skill docs give later version gates: `/cd` adds new-directory project skills on v2.1.246+; `/add-dir` can load a subdirectory's skills on v2.1.257+; main-checkout worktree fallback on v2.1.277+; account skill sync in terminal sessions on v2.1.273+. [C1]
- **D:** Managed `strictPluginOnlyCustomization.skills` blocks user/project skill sources; safe mode and bare mode restrict customization/discovery. File presence alone cannot guarantee availability under these modes/policies. [C1] [C4]
- **D:** Cowork/cloud sessions do not read the developer machine's `~/.claude/skills`. Account-enabled skills and repository skills have surface-specific rules; repository skills are not available in cloud project threads. Terminal account sync requires eligible account authentication/feature flags and is not the API-key/third-party-provider path. Synced skill bodies also differ from locally authored skills, including restrictions on local shell injection. [C1] (§ Use skills in Cowork and cloud sessions; Skills synced from claude.ai)
- **U:** This research did not inspect a complete public Claude Code loader implementation. Its precedence/symlink claims above are documented behavior, not independently reverse-engineered guarantees about binaries. The official public changelog is pinned separately from mutable web docs. [C7]

### Codex

- **D:** The current skills page covers standalone skills in the desktop app, CLI, and IDE, and plugin skills across additional ChatGPT surfaces. It does not establish that all local filesystem roots are mounted into remote/cloud sessions. Do not conflate standalone local discovery with account/plugin distribution. [O1]
- **D:** Current Windows docs explicitly support native PowerShell workflows and skills; WSL remains an alternative for Linux-native tooling. Windows 11 is recommended; fully updated Windows 10 is best effort. Sandbox implementation/setup and managed requirements can affect script/network execution independently of discovery. This is not an obsolete blanket “Windows is unsupported” claim. [O4]
- **S / U:** Source observations are pinned to released `0.163.0`, not an unspecified “latest” binary. The current skills page does not state the earliest release supporting each current path, duplicate selector behavior, symlink discovery, or sidecar policy. Backward compatibility must be established per targeted version rather than inferred from the release inspected here. [O5] [O1] [S1]–[S8]
- **U:** The skills page gives no native Windows ADMIN-path mapping, no comprehensive junction/file-link support matrix, and no full guarantees for external symlink target watching. These remain compatibility probes, not facts to fill in by analogy with Unix or Claude. [O1] [O4] [S2]

## 6. Newly sharp questions — intentionally not decided

1. **Version/surface contract:** Which exact Claude Code and Codex releases, local clients and remote surfaces must the product support? “Both support Agent Skills” does not resolve the later feature gates or remote filesystem visibility. [C1] [O1] [O5]
2. **Destination versus backward compatibility:** Should Codex installation target only the current documented `.agents/skills` locations, or also manage deprecated `.codex/skills` installations? If both exist, how will ownership and duplicate entries be presented without falsely promising an override? [O1] [S1] [S7]
3. **Collision contract:** What should the product do when another skill already owns a name, when a folder name differs from frontmatter `name`, or when a global Claude skill shadows a project one? Codex's ambiguous `$name` selection and Claude's reserved names make “overwrite by display name” particularly underspecified. [C1] [S4] [S5]
4. **Copy/link support boundary:** Are real directories, directory symlinks, Windows junctions, and plugin caches all intended installation targets? What is the approved fallback when Windows cannot create a symlink? Documented folder-link support does not establish all those operations. [C1] [C5] [O1] [S2]
5. **Preservation versus translation:** Is the product promising to preserve host-specific semantics (`allowed-tools`, hooks, arguments, sidecar policy), merely copy bytes, or reject incompatible behavior? Claude metadata and Codex sidecars are not interchangeable permission contracts; malformed Codex sidecar policy can fail open at the inspected loader. [C1] [O1] [S4] [S6]
6. **Installation success definition:** Does “installed” mean files written, visible in a selector, explicitly invocable, or implicitly discoverable? Disabled configuration, policy restrictions, startup/reload timing, context budgets, trust and symlink identities can separate these states. [C1] [C4] [O1] [O2] [S2] [S3]
7. **Isolation semantics:** Should a Claude worktree intentionally inherit main-checkout skills, and should a user/global operation honor an alternate `CLAUDE_CONFIG_DIR`? These are observable scope choices, not generic filesystem conventions. [C1] [C6]
8. **Required follow-up probes:** Which Windows/link types, oldest supported versions, duplicate-selector cases, disabled-skill paths, untrusted projects and cloud contexts warrant controlled tests with harmless authored fixtures? No such test results are implied by this research. [C1] [O1] [O2] [S2] [S5]

## Source ledger

Citation IDs carry the retrieval date listed here. Documentation is mutable; source links are commit-pinned. Section titles attached to citations identify the relevant passage where a page covers multiple topics.

### Specification and Claude Code

- **A1 — [Agent Skills specification][A1].** Retrieved **2026-10-22 UTC**. Canonical format, constraints, optional fields and progressive disclosure.
- **C1 — [Claude Code: Extend Claude with skills][C1].** Retrieved **2026-10-22 UTC**. Native paths, precedence, nested/worktree discovery, symlinks, invocation, frontmatter, reload, sync and surface caveats.
- **C2 — [Claude Code: Deploy managed settings][C2].** Retrieved **2026-10-22 UTC**. Managed settings base directories per OS.
- **C3 — [Claude Code: Advanced setup][C3].** Retrieved **2026-10-22 UTC**. Current platform/shell requirements and native Windows/WSL distinctions.
- **C4 — [Claude Code: Settings reference][C4].** Retrieved **2026-10-23 UTC**, especially `strictPluginOnlyCustomization.skills` and `skillOverrides`.
- **C5 — [Claude Code: Host a marketplace — symlinks][C5].** Retrieved **2026-10-23 UTC**. Plugin cache link restrictions and Windows link-creation note.
- **C6 — [Claude Code: The .claude directory][C6].** Retrieved **2026-10-23 UTC**. Windows home mapping and `CLAUDE_CONFIG_DIR` relocation, including global skills paths.
- **C7 — [Official Claude Code changelog, commit 65823ec][C7].** Retrieved **2026-10-22 UTC**. Sections `2.0.20` and `2.1.0`; snapshot's top version is `2.1.309`. This is changelog evidence, not a loader source audit.

### OpenAI documentation and release identity

- **O1 — [OpenAI: Build skills][O1].** Retrieved **2026-10-22 UTC** at the official Codex skills Markdown endpoint. The page currently covers ChatGPT and Codex together; product-specific statements above are attributed accordingly.
- **O2 — [OpenAI: Config basics][O2].** Retrieved **2026-10-23 UTC**. `developers.openai.com/codex/config-basic.md` redirects to this official `learn.chatgpt.com` destination. Configuration layers/trust, not skill-name override policy.
- **O3 — [OpenAI: Build plugins][O3].** Retrieved **2026-10-23 UTC**. Standalone skill versus manifest-based plugin distribution/installation.
- **O4 — [OpenAI: Windows sandbox][O4].** Retrieved **2026-10-22 UTC**. Official destination of `developers.openai.com/codex/windows.md`; current native Windows support and constraints.
- **O5 — [Codex release rust-v0.163.0][O5].** Release metadata retrieved **2026-10-22 UTC** via GitHub's official API; published `2026-10-15T21:30:38Z`. Annotated tag object `129b8ec7ee6f4511557a4856279f529025c25af4` resolves to commit `83086188ae0614bd882818ff1aa23f3194962012` using the official [tag object API](https://api.github.com/repos/openai/codex/git/tags/129b8ec7ee6f4511557a4856279f529025c25af4).

### Codex official source — all at release commit 8308618

All source files below were retrieved **2026-10-23 UTC**; they were read, not executed.

- **S1 — [Host skill roots resolver][S1].** `resolve_skill_roots_with_home_dir`, `roots_from_layer_stack`, `repo_agents_skill_roots`, `find_project_root`.
- **S2 — [Host skill loader][S2].** `load_skills_under_root`, `parse_skill_file`, `default_skill_name`, `canonicalize_for_skill_identity`; symlinks, canonical paths and plugin containment.
- **S3 — [Host root merge][S3].** `merge_host_skill_root_snapshots`, `scope_rank`; path deduplication and ordering.
- **S4 — [SKILL.md frontmatter parser][S4].** `parse_skill_frontmatter_metadata`, `SkillFrontmatter`; actual accepted/validated metadata.
- **S5 — [Explicit skill selection][S5].** `collect_explicit_skill_mentions`, `select_skills_from_mentions`; path selection and ambiguous raw names.
- **S6 — [Optional metadata loader][S6].** `load_host_skill_metadata`, `resolve_policy`; optional sidecar failure behavior and parsed policy.
- **S7 — [Bundled skill installer source][S7].** `_codex_home`, `_default_dest`; historical user destination. No installer code was run.
- **S8 — [Discovery walker][S8] and [loader constants][S8b].** Exact filename matching, hidden-directory handling, traversal limits.

[A1]: https://agentskills.io/specification
[C1]: https://code.claude.com/docs/en/skills
[C2]: https://code.claude.com/docs/en/managed-settings
[C3]: https://code.claude.com/docs/en/setup
[C4]: https://code.claude.com/docs/en/settings-reference#strictpluginonlycustomization-skills
[C5]: https://code.claude.com/docs/en/plugins/host-marketplace#share-files-within-a-marketplace-with-symlinks
[C6]: https://code.claude.com/docs/en/claude-directory
[C7]: https://github.com/anthropics/claude-code/blob/65823ec0034ed0aa0266bc43903fefd3ff94a327/CHANGELOG.md
[O1]: https://developers.openai.com/codex/skills.md
[O2]: https://learn.chatgpt.com/docs/config-file/config-basic
[O3]: https://developers.openai.com/plugins/build/plugins
[O4]: https://learn.chatgpt.com/docs/windows/windows-sandbox
[O5]: https://github.com/openai/codex/releases/tag/rust-v0.163.0
[S1]: https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/ext/skills/src/host_roots.rs
[S2]: https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/ext/skills/src/loader/host.rs
[S3]: https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/ext/skills/src/loader/host_merge.rs
[S4]: https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/skills/src/parser.rs
[S5]: https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/skills/src/selection.rs
[S6]: https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/ext/skills/src/loader/metadata.rs
[S7]: https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/skills/src/assets/samples/skill-installer/scripts/install-skill-from-github.py
[S8]: https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/ext/skills/src/loader/discovery.rs
[S8b]: https://github.com/openai/codex/blob/83086188ae0614bd882818ff1aa23f3194962012/codex-rs/ext/skills/src/loader/mod.rs
