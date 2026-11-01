# Zema validation integration

## Approved policy

The current conversation supersedes the earlier Skill unknown-field advisory decision. Production Skill validation uses the new `agentskills-core-strict-ascii-v1` profile against pinned upstream baseline `69ef37e9424c0a7ea9dd2293b559e43ec8176379`. Unknown top-level fields are product errors; ASCII-only naming remains product policy. The six pinned core fields plus the recognized `disable-model-invocation` harness extension, scalar-value limits, stable diagnostics, bounded inert reads/parsing, JSON report, and statuses 0/2/1 are unchanged.

`disable-model-invocation` is an optional boolean recognized by the strict product allowlist. [Pi Skills](https://pi.dev/docs/latest/skills) documents that `true` keeps manual `/skill:name` invocation, and [Claude Skills](https://code.claude.com/docs/en/skills) documents the same boolean. [Codex Skills](https://developers.openai.com/codex/skills/) instead documents `policy.allow_implicit_invocation: false` in `agents/openai.yaml`, not this frontmatter key. The [Agent Skills specification](https://agentskills.io/specification.md) still defines six core keys. Validation accepts the extension as metadata only: it neither enforces runtime invocation policy nor converts a Skill into a Prompt resource or Prompt lifecycle.

Pack and publisher configuration objects are closed recursively. Every declared collection rejects an explicitly empty array but may be omitted and normalized to an empty internal default. Explicit null is different from omission and is rejected for nonnullable fields. Diagnostics contain a field path, stable code, and message without received values, source bodies, credentials, or terminal-control characters.

## Applied sites

| Contract | Public entry point | Applied consumers |
| --- | --- | --- |
| Consumer/pack configuration | `PackConfiguration.parse` / `.load` | `config validate`, pack lifecycle, publisher catalog loading through the existing parser |
| Source publisher catalog | `ResourceCatalog.load` | Installation requests; only the requested resource type receives entry semantics, preserving type isolation |
| Skill frontmatter | `validateSkill` | `skill validate` and the existing managed-Skill validation lifecycle |
| Shared Agent frontmatter | `SharedAgentFormat.validate` | New library-only boundary; no CLI or lifecycle consumer yet |

`readDeclaredSkillName` remains name-only discovery and does not perform speculative full Skill validation. Native Claude, Pi, and Codex inspection, authoring, installation, and conversion keep their existing schemas. Shared Agent extension fields are preserved in a deeply immutable snapshot; this library does not install, convert, enumerate, or interpret them.

## Deferred consumers

No shared-Agent CLI, enum, harness conversion, installation, or native-schema integration is added. A future consumer must call `SharedAgentFormat.validate` explicitly rather than weakening native validation or treating preserved extensions as recognized capabilities.
