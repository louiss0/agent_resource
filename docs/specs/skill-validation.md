# Skill validation: agentskills-core-ascii-v1

## Problem Statement

Discovery identifies candidates and inspection returns text, but neither tells a developer whether a skill satisfies a stated correctness profile. The recovered research shows that normative Agent Skills prose, reference-validator behavior, and harness acceptance are different contracts. Users need reproducible, structured checks without executing resource code or overstating compliance.

## Solution

Add validate --skill <directory> using the named agentskills-core-ascii-v1 validation profile. Identify the pinned documentation baseline in every report. Distinguish specification errors, explicit product restrictions, and advisory warnings. Produce machine-readable reports with meaningful exit statuses. This is bounded static validation, not a safety certificate, universal compliance claim, lint suite, or runtime compatibility check.

## User Stories

1. As a developer, I want to select one skill directory explicitly, so that validation cannot inspect an inferred home or project.
2. As a developer, I want a named validation profile, so that I know exactly which rules ran.
3. As a developer, I want the upstream baseline recorded, so that results are reproducible against identified documentation.
4. As a developer, I want specification errors separated from product restrictions, so that a narrower local policy is not misrepresented as universal truth.
5. As a developer, I want recommendations represented as warnings, so that advice does not silently become a blocking requirement.
6. As a developer, I want missing or malformed frontmatter diagnosed, so that I can correct structural errors.
7. As a developer, I want required name and description checks, so that essential metadata is usable.
8. As a developer, I want literal name/directory agreement checked, so that location and declared identity are consistent.
9. As a developer, I want optional-field types and documented limits checked, so that malformed metadata is not silently coerced.
10. As a developer, I want unknown fields warned about but retained as nonblocking evidence, so that extensions are not universally declared invalid.
11. As a developer, I want independent metadata errors accumulated, so that one edit cycle can address several problems.
12. As a developer, I want bodies left uninterpreted, so that arbitrary Markdown is not rejected by invented requirements.
13. As a script author, I want stable JSON fields and diagnostic codes, so that automation need not parse human prose.
14. As a script author, I want invalid profiles to return a distinct nonzero status, so that checks can gate workflows.
15. As a script author, I want operational failures distinguished from completed invalid reports, so that inaccessible input is not misrepresented as a content verdict.
16. As a developer, I want reads bounded and linked markers excluded, so that validating unmanaged resources is observational and constrained.
17. As a developer, I want no resource execution, network requests, or mutations, so that validation does not activate untrusted instructions.
18. As a contributor, I want tests at the existing command seam, so that behavior remains testable without duplicating parser or filesystem implementation.

## Implementation Decisions

### Evidence and approved profile

- Use the recovered Agent Skills baseline research and filesystem-safety research as primary project evidence. The authoritative upstream snapshot is 69ef37e9424c0a7ea9dd2293b559e43ec8176379. Do not silently substitute current rolling web content or copy the demonstration validator's differences as normative requirements.
- Profile identifier: agentskills-core-ascii-v1. The user approved the bounded core profile, Unicode scalar-value length counting, literal directory/name matching, an explicitly product-specific ASCII name restriction, and nonblocking warnings for unknown fields.
- This profile does not resolve every ambiguity in the upstream prose. A passing result means valid for this identified profile only, not all-client acceptance, runtime verification, security, or complete semantic conformance.

### Command, report, and delivery

- Register a root validate action using the Mamba generator and shared executor. Require --skill; no implicit selection. Help succeeds without a selected directory; ordinary parser rejection remains framework-owned. Reject blank input before filesystem work.
- Inject the validation operation through a focused callback, binding the real operation at composition time. Keep reports and diagnostics typed internally; serialize only at the boundary. Use matching generators for new supported class declarations.
- Successful completed-valid report: JSON stdout, status 0. Completed-invalid report: JSON stderr, status 2 through MambaException. Operational failure: human-readable stderr, status 1, no report or partial JSON. Do not change process-global exit state inside a command or replace the production adapter.
- Disable ANSI color on Mamba's exported Chalk instance at the executable boundary so status-2 stderr is directly parseable JSON. Retain create() delivery, not a replacement adapter or custom parser; do not strip styling in report tests.
- Report has exactly path (normalized absolute lexical selected directory), profile (identifier), baseline (upstream commit), valid (boolean), diagnostics (array). No installation scope, destination, management ownership, or compatibility inference.
- Each diagnostic has exactly code (stable string), category (specification, product, advisory), severity (error or warning), field (string or null), message (human-readable string). valid is true exactly when no error diagnostic exists; warnings alone are successful.
- Preserve deterministic report ordering: structural/read gates first; then fields name, description, license, compatibility, metadata, allowed-tools; then unknown top-level keys in lexical order. Accumulate independent field errors after a usable mapping is available. Avoid cascades from missing/wrong-type fields. Do not require exact human message punctuation as a wire contract.

### Read and parse boundaries

- Selected root must exist as a directory; nonexistent/nondirectory or inaccessible root is an operational failure. Explicit root directory links are permitted and retain their lexical selected path. This is a disclosed explicit content root, not authorization to traverse internal links.
- Read only the immediate SKILL.md. Absence produces specification error SKILL_FILE_MISSING; nonregular marker such as a directory produces SKILL_FILE_TYPE; marker links produce product error SKILL_FILE_LINK without target reads. No nested resource traversal, reference fetching, scripts, commands, dependency installation, or file writes.
- Max marker bytes: 1,048,576, inclusive. Bound actual reads to cap plus one bytes and close every opened file on all paths. Over-cap produces product FILE_SIZE_LIMIT. Strict UTF-8 decoding with standard leading BOM behavior; malformed bytes produce product UTF8_INVALID. Actual I/O failures remain operational failures.
- Frontmatter starts with an exact standalone --- opening line and ends with a standalone --- closing line. Accept LF/CRLF; do not split a quoted or indented scalar merely because it contains --- characters. Body is ignored and may be empty. Missing opening/closing delimiters produce FRONTMATTER_MISSING or FRONTMATTER_UNTERMINATED specification diagnostics.
- YAML frontmatter bytes are capped at 65,536, inclusive; over-cap produces product FRONTMATTER_SIZE_LIMIT. Use a non-executing YAML parser as a declared direct dependency. Do not repair malformed values or coerce scalars. Malformed YAML and duplicate keys produce specification YAML_INVALID. Mapping required (FRONTMATTER_MAPPING); nonstring top-level keys produce product FRONTMATTER_KEYS.
- Byte caps bound input size, not a guaranteed CPU/memory/sandbox property for every parser behavior. No hostile concurrent-replacement resistance is claimed. Portable lookup errors can collapse to absence; report only observations and do not claim a secured filesystem boundary.

### Metadata checks

- Count raw Unicode scalar values, not UTF-8 bytes, UTF-16 code units, or graphemes. Do not trim, normalize, case-fold, or stringify values before comparisons. Whitespace-only name/description are errors.
- name required string, 1–64 scalar values. Codes NAME_REQUIRED, NAME_TYPE, NAME_EMPTY, NAME_LENGTH as applicable. ASCII characters must be lowercase a-z, digits, or hyphen; no leading/trailing hyphen or consecutive hyphens (NAME_FORMAT, specification). Non-ASCII names receive NAME_ASCII_POLICY (product), not a claim that Unicode is universally forbidden by the specification. Literal name must equal selected directory basename (NAME_DIRECTORY, specification).
- description required string, 1–1024 scalar values, nonblank. Codes DESCRIPTION_REQUIRED, DESCRIPTION_TYPE, DESCRIPTION_EMPTY, DESCRIPTION_LENGTH. Generic prose is not a validity error.
- license, when present, must be a string (LICENSE_TYPE); no SPDX-only grammar, minimum length, or mandatory license file.
- compatibility, when present, must be a string (COMPATIBILITY_TYPE) of 1–500 scalar values (COMPATIBILITY_LENGTH). Do not invent an additional whitespace/nonblank rule.
- metadata, when present, must be a map (METADATA_TYPE) with string keys and string values (METADATA_ENTRY_TYPE). No required author/version fields, coercion, nested-object support, or mandatory namespace convention.
- allowed-tools, when present, must be a string (ALLOWED_TOOLS_TYPE). Do not execute tools, parse a universal permission grammar, or require nonempty text without a documented rule.
- Unknown top-level string keys yield advisory warning UNKNOWN_FIELD, one per key sorted lexically. Do not invalidate merely because the pinned demonstration validator rejects those fields.
- Optional directories and arbitrary additional contents are permitted; no required body, scripts, references, assets, heading, line count, tokenizer budget, or body-link validation in this profile.

## Testing Decisions

Use the established shared-executor temporary-filesystem seam, with complete result metadata and exact/matched report JSON. A small real-process smoke set verifies status and stream delivery for valid, invalid, and operational outcomes. Do not duplicate entire fake suites or test private parser internals. Command groups mirror agent_resource then validate. User approved continuing the existing read-only command seam.

These are 15 acceptance checks per feature area (60 checks total), not 60 mandatory separate test functions. Parameterize related boundaries and accumulate assertions where one invocation proves several facts.

### Feature 1: Command and report contract — 15 checks

1. Root help advertises validate while preserving discover/inspect.
2. Validate help explains profile, scope, and non-claims.
3. Help exposes --skill and succeeds without a selected root.
4. Missing --skill is parser rejection.
5. Missing option value is parser rejection.
6. Unknown option and unexpected positional input are rejected.
7. Blank selected input fails operationally before reading.
8. Missing or nondirectory root returns status 1 with useful diagnostic.
9. Valid input yields success variant, status 0, and parsed report.
10. Invalid input yields failure variant, status 2, JSON diagnostic message, and no retained success output.
11. Report has exactly the five specified keys and identified baseline/profile.
12. Diagnostic objects have exactly the five specified fields/types/categories.
13. Warnings alone leave valid true and status 0.
14. Reused-adapter valid/invalid/valid results do not retain stale diagnostics.
15. Production valid/invalid/operational invocations use stdout0/stderr2/stderr1 respectively, with no partial JSON on the wrong stream.

### Feature 2: Required-field correctness — 15 checks

1. A minimal valid skill with empty body passes.
2. Missing name is diagnosed.
3. Wrong-type name is diagnosed without coercion.
4. Empty or whitespace-only name is diagnosed.
5. Name length boundary 64/65 is enforced.
6. Uppercase ASCII, forbidden ASCII punctuation, and leading/trailing/consecutive hyphens produce specification format errors.
7. Non-ASCII name policy is labeled product, not specification repertoire failure.
8. Literal basename mismatch is diagnosed, without case-folding.
9. Missing description is diagnosed.
10. Wrong-type description is diagnosed without coercion.
11. Empty or whitespace-only description is diagnosed.
12. Description length boundary 1024/1025 is enforced.
13. Astral Unicode description characters count as one scalar each, not UTF-16 units.
14. Multiple independent field failures accumulate in stable field order.
15. Malformed Markdown body, absent recommended sections, and arbitrary extra directories do not create invented validity failures.

### Feature 3: YAML and optional metadata — 15 checks

1. LF and CRLF delimiter lines are accepted.
2. Missing opening delimiter is diagnosed.
3. Missing closing delimiter is diagnosed.
4. Quoted/indented scalar text containing --- does not prematurely terminate frontmatter.
5. Malformed YAML is diagnosed.
6. Duplicate YAML mapping keys are diagnosed.
7. Nonmapping/empty YAML is diagnosed.
8. Nonstring top-level keys receive a product restriction diagnostic.
9. License string passes and nonstring value fails.
10. Compatibility lengths 1/500 pass, 0/501 fail; nonstring fails.
11. Compatibility uses scalar counts rather than bytes or UTF-16 units.
12. Metadata string-to-string map passes; nonmap fails.
13. Nonstring metadata keys/values, including nested maps/lists, fail without coercion.
14. Allowed-tools string passes; nonstring fails, without permission interpretation.
15. Unknown keys produce deterministically ordered nonblocking warnings; recognized optional fields are not warned about.

### Feature 4: Bounded, inert filesystem behavior — 15 checks

1. Missing immediate marker yields a structured specification error.
2. Directory marker yields a structured type error.
3. Linked marker is excluded without target decoding; malformed external target remains untouched.
4. Explicit root link preserves selected lexical path where link creation is available.
5. Nested markers do not satisfy the immediate marker requirement.
6. Marker size exactly 1 MiB is accepted when contents are otherwise valid.
7. Marker size cap plus one is rejected with product FILE_SIZE_LIMIT.
8. Malformed UTF-8 yields product UTF8_INVALID and no coercion.
9. Standard UTF-8 BOM behavior is supported.
10. YAML frontmatter byte cap exactly 64 KiB passes; cap plus one fails with product restriction.
11. Multibyte fixtures prove file/frontmatter budgets count bytes, not characters.
12. Success, invalid reports, help, and parser failures preserve seeded filesystem entries and bytes.
13. References, scripts, URLs, and tool declarations remain inert; no external content inspection is required.
14. Read files close on success and failure, allowing fixture teardown/rename on Windows.
15. Reports and documentation make no security/runtime compatibility, universal compliance, origin, or ownership claims.

Explicitly skip link checks with reasons where OS permissions prevent link creation. Avoid privileged permission manipulation. Redirect production home/config environments to temporary fixtures. Compare entry types and bytes, not access timestamps. Use existing finite subprocess deadlines and unconditional cleanup. Run focused tests and analysis during implementation, full tests and formatting at the end, then independent Standards and Spec reviews before committing intended changes only.

## Out of Scope

- Full Unicode naming policy or normalization, reference-validator bug compatibility, native-harness profiles, or runtime verification.
- Linting body quality, checking Markdown links/scripts, tool-permission enforcement, dependency downloads, execution, and network access.
- Installation, adoption, management records, mutation plans, backups, removal, or any writes during validation.
- Validating every bundled resource, closed directory schemas, universal safety certification, or a hardened hostile-writer sandbox.
- Automatic profile negotiation, rolling upstream updates, batch validation, repair/rewrite commands, human-output renderers, and new global adapters.

## Further Notes

The user explicitly approved this core profile and nonzero-invalid exit contract after the existing research was recovered. Six research notes are now local and the research worktrees have been removed; their branches and a local untracked source archive remain preserved. No fresh research is needed to restate already documented facts. Use openai/gpt-5.6-luna for subagents and preserve unrelated source archives/concurrent changes.
