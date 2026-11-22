> **Historical design record** — this document may not describe
> current behavior. See [README.md](../README.md) and
> [docs/guides/](guides/) for current guidance.

﻿# Native Prompt inspection and validation

Canonical policy: [mixed-harness discovery and validity reporting](https://github.com/louiss0/agent_resource/issues/77) and [Pi skill-backed Prompt installation compatibility](https://github.com/louiss0/agent_resource/issues/79), indexed by [the feature map](https://github.com/louiss0/agent_resource/issues/57).

`PromptInspectionService` is a read-only inspection foundation, not an install,
conversion, or execution API. Its filesystem is injectable. Call `inspect` with
an explicit `PromptForm.skill` directory or `PromptForm.template` file, optional
`consumer` (`claude`, `codex`, or `pi`), and optional caller-supplied
`PromptPlacement` (`project`, `user`, `uninstalled`, or `unknown`). Placement is
context supplied by the caller, not verified discovery, runtime activation, or
inferred from invocation controls.

The immutable result contains independent `views` for the three consumers,
`selectedConsumer` and `selectedView` (both absent without selection), frozen
native `fields` and `sidecarFields`, and `globalCompatibility`. There is no
universal classification or validity. Each view carries its own classification,
validity, diagnostics and argument/shell observations. A valid ordinary Skill
view means the inspector's supported native marker/metadata checks passed; it
is not a complete package-install readiness check. An unselected template is
unclassified even in the Pi view; select Pi explicitly to inspect its template
form. Selecting another consumer does not implicitly establish a Pi template
source profile either. Both Pi templates and skill-backed forms are supported by inspection;
explicit Pi Prompt installation is unsupported, and all installation is outside
this slice.

For a skill, Claude and Pi use `disable-model-invocation: true` and Codex uses
`policy.allow_implicit_invocation: false` in `agents/openai.yaml`. A known
manual-only control identifies a Prompt even when another validation fails.
Malformed relevant controls are unknown, not ordinary Skills. Verified absent
controls use native defaults only when the relevant metadata is well-formed.
The global compatibility result is `compatible` only when all three views are
valid Prompts, `unknown` if a view has malformed classification, otherwise
`incompatible`. It describes the forms and supported validation, not placement,
availability, runtime behavior, or a fourth harness. No custom resource labels
are needed or written.

Validation intentionally covers a documented subset: common skill marker name,
description, license, compatibility, metadata and allowed-tools shapes; the
supported Claude skill fields and Claude tool/context constraints; Pi template
description and argument hint; and the documented Codex sidecar sections and
field shapes represented by this inspector. Unknown fields are diagnosed rather
than silently treated as portable. Claude hook definitions are unsupported.
Compatibility is documentation-targeted, not tested against running harnesses.
A malformed Codex sidecar prevents a Claude or Pi Prompt from claiming the
sidecar exception, without changing their invocation facts. Ordinary Skill views
are not subject to another view's Prompt-only layout or body policy.

Tool dependency declarations require usable `type` and `value` identity strings,
with normalized limits of 64 and 1,024 Unicode characters respectively. Codex's
[first-party metadata resolver](https://github.com/openai/codex/blob/20b4ff2f35f2193608385e4caa8da8ceee45a3cf/codex-rs/skills/src/metadata.rs)
drops unusable dependencies; this product's validated-sidecar exception instead
reports them as invalid rather than silently accepting the omission. A known
manual-only policy still identifies a Prompt candidate, but absent controls in
such malformed metadata do not become a guessed ordinary Skill.

## Prompt shape and observations

Skill-backed Prompts permit only regular `SKILL.md`, optionally with a validated
regular `agents/openai.yaml` and its parent directory. Other files, directories,
links and unsupported entries are invalid for the Prompt view. Pi templates are
standalone Markdown. Prompt bodies are scanned for whole path-shaped
`references`, `scripts`, or `assets` segments followed by `/` or `\\`, including
code, links and external paths; `agents/` is exempt. Diagnostics report one-based
line and column without reproducing instruction text. This is a lexical scan,
not path resolution or intent analysis.

Claude skill argument expressions and dynamic shell injection are observations,
not rendering or execution. Pi template expressions are observed only for its
template form. Pi skill invocation appends arguments instead of applying template
substitutions, represented by `argumentsAppended`; Codex Skills do not inherit
Claude's expansion or shell semantics. Active argument expressions are permitted
in native Prompts; stricter Prompt-to-Agent conversion is future work.

## Safety and limits

Linked source path components are rejected; embedded links are never followed.
Instruction reads are capped at 1 MiB, YAML at 64 KiB, and directory enumeration
and absence confirmation at 1,024 entries. Scalar-aware YAML event preflight
rejects aliases, over 32 collection levels, and over 4,096 nodes before loading.
The internal YAML event parser dependency must be rechecked on upgrades. Nested
reported collections are immutable. Lookup, listing and read failures are
operational failures, not evidence of absence or validity. Inspection performs no
writes or executions and does not invoke harnesses, templates, shell, scripts,
hooks, external services or credential helpers.
