# Common Pi Agent definitions across two subagent providers

Research for [Verify common Pi Agent profile across subagent providers](https://github.com/louiss0/agent_resource/issues/21). Retrieved **2026-10-23 UTC**. This is source/document evidence, not runtime certification or a chosen execution engine.

## Scope, provenance and method

The requested `nicopreme` is the npm maintainer of **`pi-subagents`**, authored by Nico Bailon, repository **nicobailon/pi-subagents**. It is not a GitHub repository named nicopreme/pi-subagents. The second package is **`@tintinweb/pi-subagents`**, repository **tintinweb/pi-subagents**, not an unofficial package mirror. [N0][T0]

| Package snapshot | Release source pin |
| --- | --- |
| pi-subagents 0.81.0 | `1bc941363cb62fc23c94c5519364b03dc150be3e` |
| @tintinweb/pi-subagents 0.22.0 | `85a704cb8f35c96c0cabfa665b572bab296942e5` |

Pins are the npm metadata `gitHead` values observed during lookup. Claims below distinguish **D** (provider documentation), **S** (pinned source read, not executed), **I** (bounded consequence), and **U** (unverified). The worker downloaded sources before interruption; the parent recovered and read them. The cached blobs for Nico's `agents.ts` and `frontmatter.ts`, and Tintinweb's `custom-agents.ts` and `agent-runner.ts`, were independently compared with GitHub's contents API at the pins; all four blob IDs matched. No packages/extension code were installed or run, no agents/MCP servers launched, and no actual user configuration or credentials read. No behavior probes or native host certification occurred.

**Human requirements, separate from facts:** one common Pi profile, not a union or two user-facing schemas. After the description discovery below, the human explicitly requires **four inputs: name, description, model, tools**. Model must be qualified `provider/model-id`; tools initially use a nonempty explicit shared-built-in list serialized as comma-separated text. Other fields are eligible only with verified compatible support in both. Runtime execution remains the extensions' responsibility.

## 1. Main result

Both providers consume Markdown with frontmatter and an instruction body. A conservative shared metadata shape exists, but **a three-property file containing only name/model/tools is not loadable in Nico's pinned provider**. Its loader explicitly skips a file when `frontmatter.name` or `frontmatter.description` is falsy. Tintinweb accepts both fields but supplies defaults when absent. Thus description belongs in a compatible emitted file; the human chose to require it rather than synthesize a default. [N1][N3][T1][T2]

A common *declaration* does not imply identical model resolution, tool exposure, prompt inheritance, discovery or sandboxing. In particular, `tools` cannot be described as the same complete effective-tool/security boundary across these providers. [N1][N2][T1][T3]

## 2. Field/type/meaning intersection

| Item | Nico | Tintinweb | Bounded shared conclusion |
| --- | --- | --- | --- |
| Container | D/S: Markdown, custom frontmatter parser, body used as prompt | D/S: Markdown, Pi frontmatter parser, body used as prompt | Common basic structure; not every YAML feature has equivalent parsing. [N1][N3][N4][T1][T2] |
| `name` | S: required nonempty/truthy field; canonical local name, with optional provider package namespaces | S: string trimmed, falls back to filename; colon rejected; declared name defines identity | Explicit nonblank string, no colon and no accidental leading/trailing whitespace is a conservative common form. Namespace/alias/case dispatch is not universal. [N3][T2][T4] |
| `description` | S: missing/empty causes skip | S: string or default name | Accepted by both, REQUIRED for shared output because of Nico. No automatic synthesis selected. [N3][T2] |
| `model` | D/S: optional native default; explicit selection, overrides and settings precedence; qualified provider/id supported | D/S: optional native default; qualified IDs, provider-dependent resolution/fallback and frontmatter authority | Common explicit qualified string; actual availability, override/fallback behavior and final model remain environment/provider dependent. No automatic registry probes. [N2][N3][T1][T2][T3] |
| `tools` | D/S: explicit list parsed from comma/newline scalar forms; strict named-tool selection; `mcp:` special entries | D/S: CSV partition into builtins and `ext:` selectors; omitted means builtin defaults | Nonempty CSV of shared explicit built-in names is the conservative requested subset. Do not copy selectors, wildcard/none/inherit shorthand or all YAML encodings by name. [N1][N3][N4][T1][T2][T3] |
| Instruction body | S: body trimmed by custom parser | S: `body.trim()` | Both consume trimmed Markdown body. Surrounding system/context assembly differs; body preservation is not full runtime equivalence. [N1][N4][T2] |
| `thinking` | D/S: string levels, model suffix interaction, settings/per-run overrides; false opt-out also exists | D/S: string thinking level, frontmatter pin/launch interactions; nonstring input is not the same false opt-out | The ordinary level vocabulary overlaps, but precedence/shortcuts differ. Candidate optional configured-level support needs explicit qualification; boolean false and suffix tricks are not universal. [N2][N3][T1][T2][T3] |
| `skills` | D/S: explicit names select skills independently of separate `inheritSkills` control | D/S: inherit/all/none/list field; explicit list preloads selected skills | Name overlap and explicit list support exist, but inheritance/loading semantics are not a generic shared switch. Do not auto-include all boolean/default variants. [N1][N3][T1][T2] |
| `extensions` | D/S: omission/empty/list have distinct foreground/background loading effects | D/S: true/false/list inherit field, ambient loading and tool selectors | Do not treat `false`, empty and omission as interchangeable across parsers. Not certified as a common extension-disabling field. [N1][N3][N4][T1][T2][T3] |
| `memory` | D: scope/path mapping, separate agent-memory namespace | D/S: scalar user/project/local scope | No common storage/ownership meaning established by shared key alone. [N1][T1][T2] |
| Other controls | camelCase fields such as excludeTools, systemPromptMode, inheritProjectContext, async | snake_case fields such as disallowed_tools, prompt_mode, inherit_context, run_in_background | Provider-specific until an explicit mapping is designed; do not emit a union. [N1][N3][T1][T2] |

The name restrictions above are a conservative *common-format implication*, not a claim both native loaders impose every restriction. There is no evidence for applying Agent Skills' name/file equality or 64-character rule to these definitions. Runtime aliases and case handling differ: Nico resolves canonical names case-sensitively in the inspected resolver; Tintinweb supports case-insensitive type resolution with ambiguity handling. Avoid silently lowercasing identities. [N3][T1][T4]

### Illustrative conservative file

Not executed; model is a placeholder, not a claimed available model:

```markdown
---
name: reviewer
description: Review proposed changes for correctness
model: provider/model-id
tools: read, grep, find, ls
---

Review the supplied changes and report concrete findings.
```

The nonempty requested built-in list is declared selection, **not proof of no additional tools, no side effects, authentication, or read-only enforcement**. Host version/platform determines actual tool availability. Read-only tools are examples, not a complete version-independent tool catalog.

## 3. Parsing is not universally identical YAML

**S:** Nico's parser uses a custom scalar/block parser. It splits an opening frontmatter region, keeps values as strings, strips outer quotes without implementing a complete YAML string decoder, and supports simple block/folded values. `parseFrontmatterList` splits commas/newlines and removes block-list markers; YAML flow-list syntax is not a general native array decoder. For example `tools: [read, grep]` is not established as equivalent to CSV by that code. [N4]

**S:** Tintinweb calls Pi's generic frontmatter parser after removing an optional BOM. Its tools parser uses `String(value).split(',')`; some flat YAML arrays can stringify compatibly, but that does not establish identical handling of every array/quoted item. Missing/null, empty string and the string `none` have distinct defaults/empty behavior. Nico's absent versus present-empty tool list is also significant. A common writer should use the selected simple CSV subset rather than rely on accidental coercion. [T2][N3][N4]

**I:** A valid YAML document is not necessarily a portable provider document. BOM, escapes, scalar styles, inline comments, flow lists and numeric-looking fields need explicit common-subset fixtures. New output should use an agreed tested encoding/delimiter/scalar subset, not a generic YAML dump assumed compatible. Do not copy the providers' permissive parsing bugs into the application's safety contract.

## 4. Model and tool semantics that must stay qualified

**D:** Nico's documented model precedence is per-run override > provider-scoped role override > ordinary agent override > frontmatter > global subagent default > parent. Fully qualified selection stays within its named provider; provider/auth failures are reported rather than automatically switching models. Frontmatter `inherit` is explicitly interpreted. [N2]

**D/S:** Tintinweb documents tolerant model lookup and cross-provider/parent fallback; frontmatter pins may outrank caller values on specific paths. Its runner's direct qualified lookup returns the parent model if the configured selection cannot be resolved there. Other call paths can normalize models before that function. Consequently, identical stored model text does not guarantee identical provider/fallback behavior. Do not present fuzzy names, inherit or thinking suffixes as equally strict portable pins. [T1][T3]

**D/S:** Nico documents strict child tool allowlists, `mcp:` selection, extension loading prerequisites and runtime-injected tools under contracts. Foreground and background extension loading differ. [N1]

**D/S:** Tintinweb separates builtin selection from extension exposure. Plain CSV names choose builtins; `ext:` narrows extension tools and does not load their provider. Without such narrowing, ambient extension tools can still be exposed; runtime nested/structured-output tools can also be injected. Its source uses a static allowlist only when extensions are disabled; otherwise it filters builtins and applies live extension scoping. Therefore `tools: read` does not establish the same complete tool set as Nico's strict declared-tool behavior. [T1][T2][T3]

**I:** The common profile can claim interoperable *configured metadata* with explicit runtime limitations. It cannot honestly guarantee identical effective tools, model choice or a sandbox solely from the four required fields. If stronger enforcement is desired, provider-specific configuration or unsupported-result diagnostics are necessary, not an invented common flag.

## 5. Discovery and scope

| Provider | Verified roots / qualification |
| --- | --- |
| Nico | D/S: builtin/package/user/project tiers; recursive user `<Pi agent dir>/agents/**/*.md` and project config `agents/**/*.md`, normally `.pi/agents`; legacy recursive `.agents` roots and configurable scans also exist. Pinned source additionally reads `~/.agents`; PI_CODING_AGENT_DIR affects preferred write-root selection but does not make every other read root disappear. Project trust gates project contributions. [N1][N3] |
| Tintinweb | D/S: package < global `<Pi agent dir>/agents` < project `.agents/agents` < project `.pi/agents`; local directory scan uses immediate `.md` entries, not Nico's recursive scan. PI_CODING_AGENT_DIR relocates the global agent root. [T1][T2] |

**I:** Direct `.pi/agents/<file>.md` and the usual `~/.pi/agent/agents/<file>.md` are useful common locations under standard context, but directory/trust/override details must be preserved. `.agents/agents` is evidenced for Tintinweb and lies under Nico's legacy recursive project `.agents` scan; that is provider-specific evidence, NOT proof Claude/Codex natively read it or that all Pi versions do. A deep nested file or `~/.agents` layout cannot be advertised as universally discovered by both. No install/default-root policy is selected by this research.

Same-name precedence, package agents, aliases, case-insensitive dispatch, scan exclusions and broken higher-priority files can change what runs. File inventory is not proof of effective runtime dispatch. Own each physical resource once; do not create duplicate ownership simply because both providers can read it.

## 6. APIs versus execution engines

**D/S:** Nico publishes JavaScript/TypeScript subpath exports for agents, preflight, inspectors and other integrations; `src/api/agents.ts` specifically exports runtime registration/event registration interfaces. Those are host/runtime APIs, not a portable Dart file-management API. [N0][N5]

**D/S:** Tintinweb offers Pi event-bus RPC, Agent runtime tools and workflow orchestration; the README documents these as active extension behavior. Managing static definitions need not invoke them. [T1]

Pi core describes subagents as an extension concern, not one built-in universal Agent format. Package installation can execute extension code. Resource management should read/validate/plan native artifacts without installing/loading these engines or importing npm dependencies into Dart merely to parse metadata. [P1]

No conclusion about both packages coexisting safely in one host follows from this pass. Tool/event/command interactions and exact runtime compatibility were not tested.

## 7. Remaining product decisions / evidence limits

- The human has already chosen one common profile and FOUR required inputs, with qualified model references and nonempty CSV shared builtins. These are product choices informed by evidence, not claims every native provider requires all four.
- Decide which optional fields qualify under the intended portability guarantee. Some share configured values but differ in precedence, defaults or inheritance. Do not auto-promote every overlapping key.
- Define safe common serialization/round-trip fixtures; file names, source spans and body preservation; version/profile identifiers and diagnosis of provider-only fields.
- Root ownership, clones/parent changes, managed file writes, capability/dependency analysis and Pi conversion directions remain their dedicated planning decisions.
- Registry availability, credentials, actual effective capabilities, execution/isolation, newer releases, every host/platform and provider coexistence remain unverified. This is source inspection, not a runtime compatibility certificate.

## Primary sources

All pinned provider links correspond to the npm gitHead snapshots above. Only source text was inspected.

[N0]: https://registry.npmjs.org/pi-subagents/latest
[N1]: https://github.com/nicobailon/pi-subagents/blob/1bc941363cb62fc23c94c5519364b03dc150be3e/docs/agents.md
[N2]: https://github.com/nicobailon/pi-subagents/blob/1bc941363cb62fc23c94c5519364b03dc150be3e/docs/models.md
[N3]: https://github.com/nicobailon/pi-subagents/blob/1bc941363cb62fc23c94c5519364b03dc150be3e/src/agents/agents.ts
[N4]: https://github.com/nicobailon/pi-subagents/blob/1bc941363cb62fc23c94c5519364b03dc150be3e/src/agents/frontmatter.ts
[N5]: https://github.com/nicobailon/pi-subagents/blob/1bc941363cb62fc23c94c5519364b03dc150be3e/src/api/agents.ts
[T0]: https://registry.npmjs.org/@tintinweb%2Fpi-subagents/latest
[T1]: https://github.com/tintinweb/pi-subagents/blob/85a704cb8f35c96c0cabfa665b572bab296942e5/README.md
[T2]: https://github.com/tintinweb/pi-subagents/blob/85a704cb8f35c96c0cabfa665b572bab296942e5/src/custom-agents.ts
[T3]: https://github.com/tintinweb/pi-subagents/blob/85a704cb8f35c96c0cabfa665b572bab296942e5/src/agent-runner.ts
[T4]: https://github.com/tintinweb/pi-subagents/blob/85a704cb8f35c96c0cabfa665b572bab296942e5/src/agent-types.ts
[P1]: https://github.com/earendil-works/pi
