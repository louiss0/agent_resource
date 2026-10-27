# Agent Resource

Agent Resource manages resources consumed by AI coding harnesses while preserving their native formats and compatibility differences.

## Language

**Resource**:
A skill, prompt, agent definition, MCP server configuration, plugin, or context file that a coding harness can consume.

**Harness**:
An AI coding environment whose supported resources, native formats, and installation conventions determine how a resource can be used.

**Harness profile**:
An explicit compatibility target describing the resource conventions Agent Resource follows for a harness, with an identified documentation baseline.

**Documentation-targeted**:
A compatibility claim based on an identified official documentation baseline, without implying that the native harness behavior has been runtime-verified.

**Runtime-verified**:
A compatibility claim supported by a recorded check of a specific behavior on an identified harness release, client, and operating-system environment.

**Skill destination**:
The storage convention selected for a skill: Claude-specific, Codex-specific, or shared. Destination is independent of installation scope and consuming harness compatibility.

**Shared destination**:
Skill storage intended for use by multiple compatible harnesses, without exclusive harness ownership or a guarantee that every harness discovers it.

**Installation scope**:
Whether an installation belongs to one project or the user's cross-project environment, independently of its destination and consuming harnesses.

**Discovery occurrence**:
A resource candidate found at a location and installation scope, with any known consuming-harness relationships recorded separately; discovery alone establishes neither validity nor management ownership.

**Managed installation**:
A particular resource installation that Agent Resource has created or explicitly adopted and tracks for lifecycle operations; its identity is tied to its recorded installation location, not merely its name or source.

**Copied installation**:
A managed installation whose resource contents are a separate copy owned for lifecycle management, rather than a link to a user-owned source.

**Linked installation**:
A managed installation that owns only a link entry pointing to a resource; its target remains outside that installation's ownership.

**Installation baseline**:
The recorded state of a managed installation against which later changes are assessed; copied installations track their owned contents, while linked installations track the owned link entry separately from target-content observations.

**Recovery backup**:
A retained prior state of a managed installation that can support verified restoration; a linked installation's backup preserves the link, not a historical snapshot of its target.

**Managed replacement**:
Replacing the owned entry at a recorded installation location while continuing the same managed installation identity.

**Mutation plan**:
A reviewable proposal for changing a resource installation and its management records, based on observations rather than reserved filesystem state or permission to bypass safety checks.

**Resource origin**:
Where a resource came from, distinct from where it is installed; an origin may be unknown, declared, or supported by recorded evidence.

**Unmanaged resource**:
An existing resource that Agent Resource may discover and inspect but has not created or explicitly adopted for lifecycle management.

**Adoption**:
An explicit action that brings an existing unmanaged resource installation under Agent Resource's management.

**Agent definition**:
Native configuration and instructions describing a specialized agent for a harness, distinct from a skill or persistent context file.

**Agent role binding**:
A native registration associating a named agent role with configuration sources and inheritance context, distinct from a standalone agent file.

**Common Pi Agent profile**:
Agent Resource's shared declaration contract for the two selected Pi subagent extensions, not a Pi-core format or a claim of identical runtime behavior.

**Parent configuration change**:
An explicitly requested change to harness settings shared by the parent session and potentially multiple agents, distinct from changing one agent definition.

**Agent composition**:
Constructing an agent definition from supported declarations and resource references while preserving the consuming harness's semantics; it does not imply runtime orchestration.

**Agent portability**:
The extent to which an agent definition's requirements and behavior can be represented in another harness, including altered, lost, or unverified semantics.

**Agent authoring**:
Creating, cloning, editing, or composing a native Agent definition without implying cross-harness conversion or runtime orchestration.

**Operation request**:
A bounded, versioned JSON document selecting one explicit operation, native source/target, context, declarations, and field-specific decisions; it is not a universal Agent schema.

**Plan identity**:
The stable identifier of a Mutation plan, bound to its request and relevant source, target, reference, parent, and decision observations rather than timestamps or random transaction IDs.

**Conversion field account**:
The per-field evidence for Agent portability, recording represented, altered, inherited, unresolved, unrepresentable, or deliberately omitted declarations and their native provenance.

**Exposure note**:
A deterministic, source-qualified observation about a declared execution surface and its conditions; not a security score, effective-tool enumeration, or enforcement certification.

**Agent graph**:
A bounded set of typed native dependency nodes and relationship edges with declaration provenance, resolution bases, coverage, and relationship-specific blockers.

**Readiness**:
Whether complete static correctness, reference, destination, ownership, and field-decision checks permit a reviewed publication; never a claim of runtime activation or enforcement.

**Context**:
Persistent project or user instructions consumed by a coding harness, initially represented by AGENTS.md or CLAUDE.md.
_Avoid_: Agent template, agent definition

**Validation**:
Checking a resource for correctness and conformance to its applicable specification and target harness requirements.

**Validation profile**:
An identified set of resource correctness checks that distinguishes specification requirements, product restrictions, and target-harness rules.

**Linting**:
Identifying suspicious, inconsistent, or discouraged resource patterns that may still be valid.
