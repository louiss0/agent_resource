> **Historical design record** — this document may not describe
> current behavior. See [README.md](../README.md) and
> [docs/guides/](guides/) for current guidance.

# First-class MCP server configuration support

## Problem Statement

A user who drives Claude Code, Codex, and native Pi from the same project or
machine has MCP server registrations scattered across three different native
shapes: Claude's `mcpServers` JSON, Codex's `[mcp_servers.<name>]` TOML, and
Pi's `mcpServers` JSON. There is no single Agent Resource surface for seeing
what servers exist, which are managed, whether they are valid, or how one
registration maps to another harness. Registrations are configuration, not
content: they live inside files a harness also edits, often alongside
account, trust, and permission state, and they can carry credentials or name
local executables. Today the CLI cannot discover, inspect, validate, adopt,
manage, recover, or convert these registrations, so the user handles each
harness's files and commands by hand and risks overwriting unrelated
configuration or leaking secrets.

## Solution

Agent Resource treats one named MCP server registration as a first-class
resource, managed entry-by-entry inside each harness's native configuration
files. A new singular `mcp` command group lets the user list, inspect,
validate, register, unregister, adopt, replace, back up, recover, and convert
registrations across Claude Code, Codex, and native Pi. Packs gain an
opt-in `--type mcp` selection with inline declarations and bounded native
discovery. Every mutation is interactive by default with a review plan and
explicit approval, static validation through Zema never runs or connects to a
server, and credential material is redacted and never copied. `agent config`
stops exposing MCP units; MCP becomes its own surface with its own ownership
and recovery.

## User Stories

1. As a user, I want to list MCP server registrations across Claude Code, Codex, and native Pi, so that I can see what servers exist without opening each harness's configuration by hand.
2. As a user, I want `mcp list` to distinguish managed, unmanaged, and ownership-unverified entries, so that I know which registrations Agent Resource can safely change and which need adoption first.
3. As a user, I want to inspect one MCP registration for a selected harness and scope, so that I can read its native shape without touching the file.
4. As a user, I want inspection to redact literal credential values, so that reading a report never prints a secret.
5. As a user, I want to validate one registration with Zema against its harness's native contract, so that I can catch schema and reference mistakes without launching the server.
6. As a user, I want validation to distinguish stdio entries (requiring a command) from HTTP entries (requiring a URL), so that a mismatched or missing transport is reported precisely.
7. As a user, I want validation to reject fields that do not belong to the selected transport, so that an HTTP `cwd` or a stdio `oauth` is not silently ignored.
8. As a user, I want a present `type` field to agree with the command or URL, so that an inconsistent declaration is refused rather than accepted.
9. As a user, I want validation to shape-check documented runtime controls such as Codex tool lists and approval modes and Pi exposure settings, so that these fields are checked when present.
10. As a user, I want validation to return stable statuses (0 valid, 2 product error, 1 operational failure), so that automation can branch on the result.
11. As a user, I want validation to claim only static correctness, so that I am not misled into believing a registration has been connected or will be accepted at runtime.
12. As a user, I want to register a new MCP server interactively with a review plan and approval, so that I can see exactly what will be written before it is written.
13. As a user, I want to register a stdio server by supplying a command and its arguments and environment, so that I can configure a local server in the harness's native shape.
14. As a user, I want to register an HTTP server by supplying a URL and its authentication references, so that I can configure a remote server.
15. As a user, I want to edit a managed registration interactively with the same review and approval, so that changes to an existing entry are never silent.
16. As a user, I want unattended registration to require complete explicit inputs plus a dedicated MCP-risk acknowledgment, so that automation cannot accidentally consent to running an executable.
17. As a user, I want new or copied credentials to be supplied only as environment-variable or command references, so that the CLI never introduces a literal secret into configuration.
18. As a user, I want adoption to leave existing literal credentials in place without displaying them; complete replacement removes omitted credentials.
19. As a user, I want to adopt an existing untracked registration without rewriting it, so that I can bring it under management and record a baseline before any change.
20. As a user, I want an externally changed or deleted managed registration to require explicit reviewed drift resolution, so that a destructive operation never overwrites an edit I did not see.
21. As a user, I want any shared-file change to invalidate an already reviewed mutation plan, so that a stale plan cannot clobber unrelated edits.
22. As a user, I want unsupported or unsafe write surfaces to remain inspect-only with a clear refusal, so that the CLI never writes where it cannot establish a safe method.
23. As a user, I want to unregister a server interactively with a drift check, so that removal preserves the rest of the shared file.
24. As a user, I want backups to restore only the selected entry after a fresh review, so that restoration never blindly replaces a whole shared configuration file.
25. As a user, I want to recover an interrupted mutation through a reviewed action, so that recovery completes or rolls back only the affected entry without overwriting unrelated content.
26. As a user, I want conversion to cover all six directions among Claude Code, Codex, and native Pi, so that I can move a supported registration to any other harness.
27. As a user, I want conversion to preserve transport and scope, so that a stdio user-scope entry does not silently become an HTTP project-scope entry.
28. As a user, I want conversion to fail by default when a field cannot be represented, so that loss is never silent.
29. As a user, I want to approve a known, safe field omission explicitly, so that I can convert an entry whose runtime controls do not exist in the target.
30. As a user, I want conversion to report every field as represented, altered, omitted-after-review, or refused, so that I can audit exactly what changed.
31. As a user, I want OAuth state and provider credentials never copied during conversion, so that I re-authenticate at the target instead of inheriting tokens.
32. As a user, I want the source registration to remain managed and unchanged after a successful conversion, so that conversion records lineage without breaking the original.
33. As a user, I want to include MCP in a pack only through an explicit `--type mcp`, so that untyped pack operations never pull in executables or endpoints by default.
34. As a user, I want packs to declare MCP servers inline with native fields, so that a catalog can carry a registration directly.
35. As a user, I want pack MCP declarations to permit credential references but refuse literal secrets, so that a shared catalog cannot spread credentials.
36. As a user, I want pack MCP validation to be per requested harness, so that a selection is refused when any requested target does not support it.
37. As a user, I want bounded native discovery to read only explicitly named files at bounded paths, so that pack discovery never recursively sweeps or reads user configuration.
38. As a user, I want a pack MCP name that collides with an existing registration to require explicit reviewed resolution, so that nothing is silently replaced.
39. As a user, I want MCP operations removed from `agent config`, so that parent settings and MCP registrations never share a write path again.
40. As a user, I want non-MCP parent settings that mention MCP names to remain ordinary parent configuration, so that permission rules are not forced to resolve against managed registrations.
41. As a user, I want in-flight MCP parent-unit plans and evidence drained before retirement, so that retiring the old path never strands a half-completed operation.
42. As a user, I want deterministic text and a versioned JSON success envelope for MCP operations with redaction applied, so that scripts and humans get consistent output without secrets.
43. As a user, I want failures to emit no success JSON and to use stderr with a nonzero status, so that automation never mistakes a failure for success.
44. As a user, I want the same per-harness Zema validation applied at `mcp validate`, pack admission, and conversion checks, so that one registration is judged by one contract everywhere.
45. As a user, I want management records to identify a registration by harness, scope, native configuration location, and server name, so that ownership follows the entry rather than a file or a raw name.

## Implementation Decisions

### Resource model and ownership

- One managed unit is a named native server registration at one harness, one scope, one native configuration location, and one server name. Ownership is recorded in Agent Resource state, never by writing a marker into the native file.
- A location with no ownership record is unmanaged and inspect-only until explicitly adopted. Adoption records a reviewed baseline and ownership without rewriting the native entry.
- Native files are edited entry-by-entry: read the whole file, replace only the selected entry, and preserve every unrelated key, field, and byte apart from the entry itself. A shared-file change invalidates a reviewed plan; a final file check alone is not a concurrency guarantee.
- Where a safe mutation method cannot be established, the surface remains inspect-only and mutation commands fail with a clear explanation.

### Command surface

- A new singular `mcp` group exposes `list`, `inspect`, `validate`, `register`, `unregister`, `adopt`, `replace`, `backup` (with `list`, `restore`, `cleanup`), `recover`, and `convert`.
- A registration is selected by name plus explicit harness and scope; occurrences and paths are never lifecycle selectors.
- `register` (creation) and `replace` (editing) are interactive by default with a review plan and approval before any mutation. Unattended runs require complete explicit inputs and a dedicated MCP-risk acknowledgment.
- Read-only discovery keeps the existing list/inspect/validate vocabulary; lifecycle uses MCP-specific register/unregister verbs.
- `mcp list` distinguishes managed, unmanaged, and ownership-unverified entries without claiming runtime activation.

### Native contracts

- Claude Code: project registrations in project-root `.mcp.json`; user and local registrations share `~/.claude.json` (local nested under a project-path entry). Claude selects a whole winning entry by precedence rather than merging fields; managed policy and trust can prevent activation.
- Codex: named `[mcp_servers.<name>]` TOML tables in user and trusted-project configuration; published precedence does not establish a whole-server replacement rule, and managed requirements can constrain effectiveness.
- Native Pi: user agent-directory `mcp.json` and trusted-project `.pi/mcp.json`; a project entry usually replaces a same-name user entry, with a limited override form for enabled state and tool exposure. OAuth state is stored separately, and project provider-credential `auth` is prohibited.
- `agent config` stops inspecting, planning, and applying MCP units while retaining non-MCP parent settings. In-flight MCP parent-unit plans and evidence are drained before retirement; MCP mentions inside permission rules remain ordinary parent configuration.

### Validation with Zema

- One strict Zema schema per harness, modeled as a discriminated union with stdio and HTTP variants plus a transport-consistency refinement. Exactly one of `command` or `url` is required and must agree with any present `type`; a present `type` must be a supported value.
- Transport-inapplicable optional fields are validation errors. Documented runtime controls are shape-validated when present without interpreting their effect.
- The recognized field set is pinned to the research baseline; unknown fields are errors.
- Diagnostics reuse the repository's stable, value-free codes and categories, never echoing received values or credentials. Statuses are 0 valid, 2 product error, and 1 operational failure.
- Validation claims only static schema and reference correctness, never activation, connectivity, enforcement, or runtime acceptance.

### Credentials and security

- Review redacts sensitive literal values by default and discloses the execution or connection surface plus its risks: harness, scope, server, transport, executable or sanitized endpoint, helpers, credential references, and consequential settings.
- Replacement is a complete desired registration, not a patch: supply exactly
  one of `--command` or `--url` and every supported field to retain. Omitted
  fields, including existing credentials, unknown native settings and fields of
  the old transport, are removed. Review `proposedEntry` and redacted
  `observedEntry` in the dry-run plan before approval; unrelated shared-file
  entries remain untouched. Literal credentials are never displayed or newly
  introduced; backups retain protected prior entry evidence for recovery.
- New `--env` and `--header` values are accepted only in documented target
  forms. Claude project `.mcp.json` accepts whole `${NAME}` references; Pi
  accepts whole `${NAME}` and `!command` substitutions. Codex stdio accepts
  `${NAME}` only when the key equals NAME and encodes it in `env_vars`; Codex
  HTTP encodes `${NAME}` as NAME in `env_http_headers`. Defaults, renamed Codex
  variables, and unsupported command substitutions are refused. Antigravity
  reference substitution is not established by the available documentation,
  so these inputs are refused. These are static configuration checks only: no
  server, credential helper or harness is launched, and interpolation,
  authentication and runtime activation are not verified. Pi `!command` can
  execute code when the harness uses it; never put literal secrets in commands.
- Secret-bearing recovery evidence is retained only when necessary, in protected local state with strict access and explicit retention, never in plaintext logs or normal output.

### Conversion

- Conversion covers all six directions among Claude Code, Codex, and native Pi for fields each target can represent. Transport and scope are preserved; changing scope is a separate reviewed decision.
- Conversion fails by default when a source field cannot be represented. A field may be omitted only after an explicit reviewed decision that the omission is safe and understood; it is never silently dropped or approximated.
- Harness-specific runtime controls are reported field by field. OAuth state, provider-credential selection, and stored credentials are never copied; the target user re-authenticates separately.
- The source entry remains managed and unchanged; the conversion records lineage through a deterministic per-field account of represented, altered, omitted-after-review, and refused fields.

### Pack integration

- MCP is opt-in through an explicit `--type mcp`; untyped pack operations never include MCP by default.
- Pack MCP declarations are inline entries with native fields; they may use environment-variable or command references but never literal secrets or provider-credential selection.
- Validation is per requested target harness; a selection is refused as a whole when one target does not support it.
- Bounded native discovery reads only explicitly identified configuration files at bounded, project-level paths within the pack source; it never recursively scans or reads user configuration.
- A pack MCP name that collides with an existing native or managed registration requires explicit reviewed resolution.

### Seams and composition

- The new `mcp` group and its services are composed through the application's executor composition root, mirroring how the singular skill and agent groups inject their services.
- The test boundary is the existing injected `Executor.fake()` CLI surface with the MCP services injected and native files held in a memory filesystem. No new seam type is introduced.

## Testing Decisions

A good test asserts external behavior and native file effects, not internal
implementation details: it drives an invocation through the injected
`Executor.fake()` surface and then reads the affected native configuration
files and management state back from the memory filesystem. It never launches,
connects to, or authenticates against a server.

- The singular `mcp` command group is tested through `Executor.fake()` with injected MCP inspection, lifecycle, validation, conversion, and interaction services over `MemoryFileSystem(style: FileSystemStyle.posix)`.
- Native effects are asserted by reading `.mcp.json`, the home file, Codex TOML, and Pi `mcp.json` back from the memory filesystem, matching the existing agent and skill installation tests.
- Validation tests exercise the Zema schemas through the public validation service and the `mcp validate` command, covering transport discrimination, field matrices, unknown fields, and value-free diagnostics, following the existing skill-validation test patterns.
- Pack tests exercise `--type mcp` selection, inline declarations, per-target validation, bounded discovery, and collision handling through the existing pack lifecycle seam.
- Conversion tests exercise all supported directions and the deterministic field account, following the existing agent-conversion field-account tests.
- Prior art: `test/agent_install_test.dart` (injected executor, memory filesystem, context flags, scripted interaction), `test/pack_test.dart` (pack lifecycle and type selection), and the skill validation suites (Zema diagnostics and statuses).

## Out of Scope

- Launching, connecting to, authenticating with, or enumerating tools from an MCP server; all claims remain static and documentation-targeted.
- Runtime verification that a harness accepts or activates a registration.
- Pi subagent-extension-specific MCP integration and harnesses beyond Claude Code, Codex, and native Pi.
- Implementing the feature itself; this specification is a handoff for a ready-for-agent worker.
- Publishing a new CLI release.
- Modifying managed configuration files, trust, approvals, or credentials as a side effect of registration.

## Further Notes

- The native contracts are documentation and static-source research, pinned to specific baselines; installed harness versions may differ. A writer must re-verify the affected release before claiming behavior.
- The Claude user and local surfaces live in a shared home file whose third-party editing and concurrency protocol is not documented. Until a safe mutation method is established, those surfaces are inspect-only.
- `mcp list` is passive; it must not mimic Pi's `mcp list`, which connects to enabled servers.
- The deprecated plural `skills` and `agents` groups were removed separately and are not reintroduced by this work.
