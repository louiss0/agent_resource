# Agent Skills compliance baseline — primary-source research

Research for [ticket 2: Establish the Agent Skills compliance baseline](https://github.com/louiss0/agent_resource/issues/2).

- **Retrieved:** 2026-10-22 UTC. This retrieval date applies to every source in the register below.
- **Project base:** `15e5c5370207db9963d21cbe553548184c43277b`.
- **Upstream snapshot:** Agent Skills repository commit [69ef37e9424c0a7ea9dd2293b559e43ec8176379](https://github.com/agentskills/agentskills/commit/69ef37e9424c0a7ea9dd2293b559e43ec8176379), whose committer date is 2026-08-09. Retrieval date is not publication date. Website pages are rolling documentation; repository links below pin the inspected specification source and implementation.
- **Scope:** evidence about discovery, validation, and local-directory installation boundaries; **not** product policy, application code, a security certification, or a decision record.
- **Method/limitations:** read the ticket with `gh --repo louiss0/agent_resource`; retrieved official pages using PowerShell HTTPS and repository information through GitHub's API; inspected source/tests without executing them. No `web_enable` tool is exposed in this worker session and no executable of that name was found. No skill scripts, reference-library code, or dependency installers were run. This single research file is published from an isolated worktree at the exact project base above.

## Executive findings

1. **Format requirements are small and explicit:** a skill directory, `SKILL.md`, YAML frontmatter followed by Markdown, required `name` and `description`, and constraints on documented fields. Optional directories are organizing conventions, not a closed directory schema. [S]
2. **Compliance and client acceptance differ.** The integration guide deliberately recommends loading through some name violations, while acknowledging that the specification is stricter. Compatibility advice does not repeal format constraints. [I]
3. **The delegated validator is not a complete normative oracle.** `skills-ref` calls itself demonstration-only and not intended for production. It rejects unknown top-level fields, accepts lowercase `skill.md`, normalizes Unicode names, and omits some prose-level checks. [R], [P], [V], [TP], [TV]
4. **Unresolved:** exact Unicode/character-count profile, full YAML/frontmatter parsing profile and limits, unknown top-level fields, and installation trust/containment/update semantics. [S], [P], [V], [I]
5. **Static compliance is not safety.** Instructions can inject behavior without scripts; scripts can acquire dependencies and execute commands. Filesystem links and mutation between checking and copying create separate security boundaries. [I], [U], [W], [C22], [C367]

## Classification key

- **Required:** explicit specification “must,” required field, or declared field shape. The page does not publish an RFC 2119/8174 conformance framework; this classification describes its language, not an invented formal standard. [S]
- **Advisory:** “should,” “recommended,” examples, organizational guidance, or integration advice. Imperatives in progressive-disclosure/reference guidance are recorded as authoring guidance, not silently promoted into machine-invalidating structural rules. [S], [I]
- **Implementation observation:** behavior visible in the pinned first-party reference library, not necessarily a requirement for every client. [R], [P], [V]
- **Heuristic:** a possible quality/risk signal that the sources do not make a format error.
- **Unknown/ambiguity:** official sources do not settle the point, or differ. Absence of a prohibition is not a guarantee every client accepts the input.

## 1. Required format and metadata

| Topic | Official finding | Classification and implication |
| --- | --- | --- |
| Container | A skill is a directory containing, at minimum, `SKILL.md`, which must contain YAML frontmatter followed by Markdown. [S] (Directory structure / SKILL.md format) | **Required.** The integration guide searches for exactly `SKILL.md`; reference code also accepts `skill.md`. Case-insensitive filesystems complicate observing the distinction. [I], [P], [TP] |
| Required keys | `name` and `description` are required. [S] (Frontmatter) | **Required.** Optional fields do not replace either. |
| Name length | Must be 1–64 characters. [S] (name field) | **Required**, but the character-count/normalization unit is not fully specified. |
| Name characters | Detailed wording: “unicode lowercase alphanumeric characters (`a-z`, `0-9`) and hyphens (`-`)”; summary table: lowercase letters, numbers, and hyphens. [S] | **Required restriction, ambiguous exact repertoire.** ASCII-only is not the unambiguous official rule. |
| Name shape | No initial/final hyphen, no consecutive `--`, and must match the parent directory name. [S] | **Required.** Parent means the containing skill directory, not a repository name or installation scope. Normalized versus literal matching remains unresolved in prose. |
| Description | Must be 1–1024 characters and non-empty. Describing what the skill does, when to use it, and specific keywords are detailed-section **should** guidance. [S] | **Required length/non-empty; advisory quality.** Generic wording is not automatically a format error. |
| License | Optional license name or reference to a bundled license file; short values recommended. Example: `Proprietary. LICENSE.txt has complete terms`. [S] | **Declared optional field shape; brevity advisory.** No SPDX-only rule, mandatory LICENSE file, or license-compatibility algorithm is specified. |
| Compatibility | Optional; **must be 1–500 characters if provided**. Indicates environment requirements; inclusion only when needed is a **should**. [S] | **Required bound when present; inclusion advisory.** Descriptive requirements do not prove dependencies are installed. |
| Metadata | Optional **map from string keys to string values**; additional client properties belong here. Reasonably unique key names recommended. [S] | **Declared map/string shape; naming advice.** No mandatory author, version, URL, tags, or namespace prefix. |
| Allowed tools | Optional **space-separated string** of pre-approved tools; experimental and implementation support varies. Example: `Bash(git:*) Bash(jq:*) Read`. [S] | **Declared optional field shape; experimental semantics.** The example is not a universal permission grammar or authority for this installer to execute anything. |
| Body | Markdown instructions; “There are no format restrictions.” Recommended sections include steps, examples, and edge cases. Minimal example has no visible body. [S] | Markdown-after-frontmatter is the stated structure; **no explicit non-empty-body length, heading, section, or language requirement** is supplied. Empty-body usability can be heuristic, not a confidently sourced MUST violation. |

### Name and length ambiguities

The reference validator strips name whitespace, applies **NFKC** to the name and directory basename, counts Python string length after name normalization, checks `name == name.lower()`, and permits each character if `isalnum()` or `-`. Tests explicitly accept Chinese, lowercase Russian, and a decomposed/composed `café` match. This demonstrates intentional Unicode support in this implementation, not a specification-wide Unicode version, grapheme rule, NFKC mandate, case-folding rule, or filesystem-collision policy. [V], [TV]

Description length is checked on the original parsed string; whitespace-only descriptions are rejected. `read_properties()` trims returned names/descriptions. Thus no uniform “trim, normalize, then count every field” rule follows. The spec says “characters,” without choosing bytes, Unicode scalars, UTF-16 code units, or graphemes. [S], [P], [V]

## 2. Layout, resources, and references

| Topic | Evidence and classification |
| --- | --- |
| Extra contents | **Any additional files/directories** beyond `SKILL.md` are permitted. `scripts/`, `references/`, and `assets/` are **recommendations** for executable code, documentation, and static resources. Their absence and alternative resource organization are not format errors. [S] (Optional directories) |
| Scripts | Scripts should document dependencies or be self-contained, offer useful errors, and handle edge cases. Supported languages depend on the client; Python/Bash/JavaScript are examples, not an exclusive list. The script guide covers commands without bundled scripts and dependency-resolving runners. **Advisory/runtime-specific**, not a requirement to contain code. [S], [U] |
| Interactivity | The script guide calls avoiding interactive prompts a “hard requirement of the agent execution environment.” This is scoped to its non-interactive execution environment, not a universal frontmatter/directory-schema rule. Static prompt detection would be heuristic/incomplete. [U] (Designing scripts for agentic use) |
| References/assets | Reference documents load on demand; assets include templates, images, and data. Names such as `REFERENCE.md` and `FORMS.md` are examples. No mandatory extension, exhaustive manifest, dependency list, or asset-size cap is specified. [S] |
| Path base | Authors are directed to use paths relative to the **skill root**. The integration guide resolves relative paths against the parent of `SKILL.md`; the script guide says script-execution paths in support-file code blocks are also skill-root-relative. **Official authoring/integration guidance**, not a redefinition of every Markdown renderer's link rules. [S], [I], [U] |
| Reference depth | “Keep file references one level deep from SKILL.md”; avoid deeply nested reference chains. This concerns reference chains, not a categorical ban on nested directories: arbitrary extra directories are expressly allowed. **Guidance**, not an unambiguous structural rejection rule. [S] |
| Disclosure budgets | Approximately 100 metadata tokens; under 5,000 instruction tokens **recommended**; resources on demand. The spec says keep `SKILL.md` under 500 lines; best practices explicitly describes both line/token targets as recommendations. Over-budget warnings are **advisory/heuristic**. No universal tokenizer is named. [S], [B] |
| Link validation | Reference validation parses frontmatter and ignores the body. It does not walk resources, check Markdown links/fragments, follow URLs, resolve shell-generated paths, or inspect license contents. **Implementation limit**, not proof those resources work. [V], [P] |

**External-reference limits — analysis, not new requirements:** a local existence check establishes availability of a particular resolved path at check time. It cannot prove discovery of every resource in arbitrary Markdown, code blocks, dynamic commands, or transitive documents; future URL availability; script correctness; or safety. A checking scope must distinguish examples, web hyperlinks, bundled links, reference-style Markdown, fragments, and computed paths. No prescribed body-reference grammar or dependency manifest exists here, and the reference validator does not attempt this. Broken-link, missing-script, deep-chain, and unused-resource lint need separate heuristic/product labels. Network checks create outbound effects, not a specification requirement to fetch or execute content. [S], [V], [U]

## 3. Extension fields and reference-library differences

### Unknown top-level fields

The specification enumerates six frontmatter keys and offers `metadata` for additional properties. It does **not** expressly require all clients to reject, ignore, preserve, or interpret every unknown **top-level** key. [S]

The pinned validator allowlists exactly `name`, `description`, `license`, `compatibility`, `metadata`, and `allowed-tools`; other top-level fields produce an error, with a dedicated test. Conversely, `read_properties()` selects known fields without full allowlist validation. The integration guide mentions filtering via a `disable-model-invocation` flag without making it a standard field. [V], [TV], [P], [I] (Filtering)

Therefore `metadata` is the documented extension point; unknown top-level keys are **reference-validator errors**, not a confidently universal prose-level MUST-reject rule. Client-specific keys do not become standard merely by appearing in an integration guide. Extension preservation/rejection remains an explicit compatibility decision. [S], [V], [I]

### Observed differences/gaps

| Pinned first-party behavior | Implication |
| --- | --- |
| `find_skill_md()` prefers `SKILL.md`, falls back to `skill.md`. [P], [TP] | Broader than exact-filename discovery advice; not a change to canonical spelling. |
| Unicode NFKC / lowercase / `isalnum()` checks and Unicode tests. [V], [TV] | Evidence against assuming ASCII-only; exact profile still unresolved in prose. |
| Checks required name/description, their types/nonblank status and limits, naming, directory match, compatibility type/maximum, and top-level allowlist. [V] | Useful partial checklist, not all prose requirements. |
| Compatibility validator lacks the prose's minimum-length check. [V], [S] | Empty-string compatibility can pass that function despite the specification's 1–500 rule. |
| Validator does not enforce `license`/`allowed-tools` string shape or metadata's string-map shape; parser stringifies immediate metadata entries when metadata is a mapping. [P], [V] | Nested values can become string representations; nonmapping metadata is not rejected by `validate_metadata()`. Type annotations do not enforce runtime shape. |
| `read_properties()` explicitly does not perform full validation; it requires nonblank name/description but does not call `validate()`. [P] | Reading properties and validating compliance are distinct. |
| Library README: “intended for demonstration purposes only,” “not meant to be used in production.” [R] | Not a production security boundary or exhaustive conformance suite. |

These are **static source observations**, not executed tests or measured runtime results. [P], [V], [TP], [TV]

## 4. Frontmatter parsing and resource limits

### Specified versus demonstrated

The spec says YAML frontmatter followed by Markdown. The integration guide describes opening `---` at file start, closing `---`, YAML extraction, and a trimmed body. Neither defines a complete parsing profile or explicitly selects a YAML version/schema. [S], [I] (Frontmatter extraction)

Reference extraction checks `content.startswith("---")`, then `content.split("---", 2)`, parses the middle part using `strictyaml.load()`, requires a mapping, and trims the body. It reads the whole file using `Path.read_text()` without an explicit encoding argument. **Delimiters need not occupy complete lines in this implementation.** Literal `---` in a quoted value or multiline scalar can therefore be mistaken for the closing delimiter. Leading whitespace or a decoded BOM before the prefix fails that test. These are algorithm consequences, not a recommendation to reproduce them. [P]

The package declares `strictyaml>=1.7.3`. StrictYAML's own documentation says schema-less parsing avoids implicit scalar typing and rejects duplicate keys, explicit tags/object representations, anchors/references, and flow collections. Standard YAML supports more constructs. Thus “valid YAML” and “accepted by this reference parser” differ. `metadata: {author: example}` is flow syntax, not a guaranteed cross-client representation. The parser test expects numeric-looking `version: 1.0` to become string `"1.0"`; other loaders' implicit typing may differ. [PK], [H], [Y], [P], [TP]

YAML 1.2.2 requires mapping-key uniqueness, so duplicate-key rejection has a primary YAML basis. This does **not** establish that Agent Skills selected YAML 1.2.2, mandated StrictYAML's subset, or defined duplicate-recovery semantics. [Y] (3.2.1 / 3.2.1.3), [S], [H]

### Unspecified limits/profile details

The inspected spec has **field character limits**, but no hard file/frontmatter-byte limit, nesting/alias/CPU/memory budget, Markdown-body cap, resource-count/total-byte budget, timeout, or encoding/BOM policy. The line/token targets and integration guide's example scan bounds (depth 4–6; 2,000 directories) are not hard format limits. Resource-exhaustion protections would be implementation/security controls, not an official numerical baseline. [S], [I], [P]

Other unsettled details: YAML 1.1 versus 1.2 scalar resolution; tags/aliases outside StrictYAML clients; multiple documents; null/boolean/numeric-looking values; complex keys; delimiter whitespace; line endings; and strict shape versus coercion. Reading metadata does not require constructing arbitrary language objects. StrictYAML's removal of object representations is relevant security evidence, not an Agent Skills-wide parser mandate. [S], [Y], [H], [P]

The integration guide suggests repairing malformed colon-containing values and recommends lenient loading for directory mismatch/overlong names. It recommends skipping missing/empty descriptions and completely unparseable YAML. These are **compatibility recommendations**, not valid-YAML definitions or universal diagnostic severities. A repaired/loaded file can remain nonconforming. [I] (Handling malformed YAML / Lenient validation)

## 5. Versions and source authority

- The inspected specification publishes no specification-version identifier, required `spec-version`, negotiated schema, or conformance-level mechanism. Example `metadata.version: "1.0"` is arbitrary skill metadata, **not** a declared format version. [S]
- The Python package's `version = "0.1.0"` identifies that project, not the Agent Skills format. [PK]
- Upstream GitHub tags/releases endpoints each returned empty arrays at retrieval. This is time-bound evidence, not proof no versions exist elsewhere or will ever be released. [G]
- `allowed-tools` remains explicitly experimental; no universal enforcement grammar follows from its example. [S]
- Strict specification versus deliberately lenient integration advice answer different questions: **conformance** versus **acceptance of imperfect skills**. Their differences and implementation gaps are recorded, not silently resolved. [S], [I], [R]
- No universal installer command, archive format, lockfile, signing chain, update protocol, registry contract, or mandatory test runner was established by these sources. Directory-format compliance is not a standardized package-manager lifecycle. [S], [I], [R]

## 6. Local discovery and installation security boundaries

These are **security implications/open boundaries**, not additional Agent Skills format MUSTs.

| Boundary | Primary-source evidence | Local discovery / validation / installation implication |
| --- | --- | --- |
| Discovery | Specification does not mandate where skills live. Integration guide presents project/user scopes, `.agents/skills/` convention, client-specific locations, ancestors, XDG, and configured paths; bounded traversal and deterministic collisions are advice. [I] | No universal scan roots, ignore behavior, depth, duplicate policy, or installation destination follows. Installing into a discoverable location changes what clients can load. |
| Repository trust | Guide warns that project skills can be untrusted and suggests project-trust gating to prevent silent instruction injection. [I] (Trust considerations) | Metadata disclosure/instruction activation are trust transitions even without executable code. Local location does not establish provenance/trust. |
| Permissions | `allowed-tools` is experimental. Resource allowlisting advice concerns reading bundled resources in permission-gated agents. [S], [I] | Resource-read convenience does not authorize execution, networking, elevated privileges, or installation. Skill-authored metadata is not independent permission evidence. |
| Execution/dependencies | Script guide demonstrates shell commands and runtime dependency downloads, even without bundled scripts. [U] | Static validation need not execute scripts, `--help`, tests, installers, or Markdown commands. Execution/network acquisition need separate authorization; this worker did neither. |
| Traversal | CWE-22 explains how controlled paths escape a restricted directory and affect reads/writes. [C22] | `..`, absolute paths, alternate separators, drive/UNC forms, and normalization affect containment. Name-format validity alone does not establish source/destination containment. |
| Filesystem links | Microsoft documents reparse points on files/directories implementing NTFS links/mounted folders and affecting open behavior. [W] | A lexical descendant need not identify storage inside the intended tree. Source links, destination junctions/links, cycles, and copy/follow behavior need explicit handling. |
| Mutation | CWE-367 covers changed resource identity/state between check and use, including symbolic-link substitution. [C367] | Validation-before-copy does not prove installed bytes equal validated bytes. Source mutation, destination races, snapshots/handles, and atomic publication are distinct design questions. |
| Exhaustion/special entries | Guide recommends bounded scans; reference code uses ordinary path operations and whole-file reads without explicit resource budgets. [I], [P], [V] | Huge trees/files, cycles, inaccessible entries, non-regular files, and link errors need bounded I/O/diagnostic decisions; no official numerical security budget was found. |
| Destination mutation | Spec defines contents, not merge/overwrite/rollback. Guide collision advice concerns discovery precedence, not installer authorization. [S], [I] | Valid content does not authorize overwriting an existing skill, merging unrelated files, changing other scopes, or trusting an existing destination link. Consent/preview/atomicity/cleanup are product decisions. |
| Remote references | Reference validator does not fetch/execute references; resources load on demand. [S], [I], [V] | Markdown URLs do not require automatic network requests. Static local checks cannot certify transitive/remote content. |

These security authorities describe failure mechanisms, not this product's exact API, link policy, threat model, or mitigations. This report is evidence for a later security design, not that design. [C22], [C367], [W]

## 7. Precise decisions still needed — no choices made here

1. **Acceptance contract:** distinguish strict specification diagnostics, reference-library compatibility, client-tolerant loading, and optional lint? Which violations block installation versus warn?
2. **Name profile:** Unicode as demonstrated by `skills-ref`, ASCII-only as a deliberately narrower product rule, or another profile? Which normalization/character-count unit and filesystem collision handling?
3. **Parser contract:** YAML version/subset; duplicate/alias/tag policy; coercions; delimiter-line grammar; encoding/BOM; explicit resource budgets? Reject or repair malformed YAML, and preserve original-invalidity diagnostics?
4. **Extensions:** reject, warn/preserve, or ignore unknown top-level keys? Enforce metadata's string-map shape without silently adopting reference-parser coercions?
5. **File/resources:** canonical `SKILL.md` only or lowercase fallback? Optional empty-body/line/token/link/script lint? Which local references checked; network checks only with explicit opt-in?
6. **Trust/containment:** authorized roots/scopes, permitted file/link/reparse-point types, escape/cycle/special-file behavior, permissions, mutable-source races? Is installation copy-only with no script execution or fetching?
7. **Destination lifecycle:** existing destinations, collisions, name matching after relocation, overwrite consent, atomic publication, rollback, concurrent changes? Discovery precedence is not overwrite permission.
8. **Baseline versioning:** which pinned source snapshot do diagnostics identify, and how are upstream changes reviewed without treating arbitrary `metadata.version` as format version?

These belong to subsequent product/security decisions. Closing the research ticket records completed evidence, not answers to them.

## Source register

**Every entry retrieved 2026-10-22 UTC.** Official first-party documentation/source/tests/APIs; MITRE CWE defines the cited weakness classes. Section names accompany relevant citations above.

- **S:** [Agent Skills specification][S]; [commit-pinned specification source](https://github.com/agentskills/agentskills/blob/69ef37e9424c0a7ea9dd2293b559e43ec8176379/docs/specification.mdx). Discovery began at the [official documentation index](https://agentskills.io/llms.txt) and [overview](https://agentskills.io/home.md).
- **I:** [How to add skills support to your agent][I].
- **B:** [Best practices for skill creators][B].
- **U:** [Using scripts in skills][U].
- **R:** [Reference-library README, pinned][R].
- **P:** [Reference parser, pinned][P].
- **V:** [Reference validator, pinned][V].
- **TP:** [Parser tests, pinned][TP].
- **TV:** [Validator tests, pinned][TV].
- **PK:** [Reference package metadata, pinned][PK].
- **G:** [Official upstream tags API][G]; [releases API](https://api.github.com/repos/agentskills/agentskills/releases); [snapshot commit API](https://api.github.com/repos/agentskills/agentskills/commits/69ef37e9424c0a7ea9dd2293b559e43ec8176379).
- **Y:** [YAML 1.2.2 specification][Y], especially [3.2.1 Representation Graph](https://yaml.org/spec/1.2.2/#321-representation-graph), [3.2.1.3 Node Comparison](https://yaml.org/spec/1.2.2/#3213-node-comparison), [3.2.2.2 Anchors and Aliases](https://yaml.org/spec/1.2.2/#3222-anchors-and-aliases). YAML facts, not a version selected by Agent Skills.
- **H:** [StrictYAML author's documentation: removed YAML features][H].
- **W:** [Microsoft Learn: Reparse points][W]. Restrictions are a section here; a separately guessed `/reparse-point-restrictions` URL returned 404 and is not evidence.
- **C22:** [MITRE CWE-22: Improper Limitation of a Pathname to a Restricted Directory][C22].
- **C367:** [MITRE CWE-367: Time-of-check Time-of-use Race Condition][C367].

[S]: https://agentskills.io/specification.md
[I]: https://agentskills.io/client-implementation/adding-skills-support.md
[B]: https://agentskills.io/skill-creation/best-practices.md
[U]: https://agentskills.io/skill-creation/using-scripts.md
[R]: https://github.com/agentskills/agentskills/blob/69ef37e9424c0a7ea9dd2293b559e43ec8176379/skills-ref/README.md
[P]: https://github.com/agentskills/agentskills/blob/69ef37e9424c0a7ea9dd2293b559e43ec8176379/skills-ref/src/skills_ref/parser.py
[V]: https://github.com/agentskills/agentskills/blob/69ef37e9424c0a7ea9dd2293b559e43ec8176379/skills-ref/src/skills_ref/validator.py
[TP]: https://github.com/agentskills/agentskills/blob/69ef37e9424c0a7ea9dd2293b559e43ec8176379/skills-ref/tests/test_parser.py
[TV]: https://github.com/agentskills/agentskills/blob/69ef37e9424c0a7ea9dd2293b559e43ec8176379/skills-ref/tests/test_validator.py
[PK]: https://github.com/agentskills/agentskills/blob/69ef37e9424c0a7ea9dd2293b559e43ec8176379/skills-ref/pyproject.toml
[G]: https://api.github.com/repos/agentskills/agentskills/tags
[Y]: https://yaml.org/spec/1.2.2/
[H]: https://hitchdev.com/strictyaml/features-removed/
[W]: https://learn.microsoft.com/en-us/windows/win32/fileio/reparse-points
[C22]: https://cwe.mitre.org/data/definitions/22.html
[C367]: https://cwe.mitre.org/data/definitions/367.html
