# Agent Resource

Agent Resource manages resources consumed by AI coding harnesses while preserving their native formats and compatibility differences.

## Language

**Resource**:
A skill, prompt, agent definition, MCP server configuration, plugin, or context file that a coding harness can consume.

**Prompt**:
Reusable instructions intended for explicit user invocation rather than automatic model selection through a harness's normal skill-invocation mechanism. A Prompt's argument and execution semantics depend on its applicable profile.

**Skill-backed prompt**:
A skill recognized as a Prompt for a selected Harness through that Harness's native controls disabling automatic model invocation, without a separate Agent Resource classification label.

**Global prompt**:
A harness-neutral, Skill-backed prompt intended for cross-project use and configured for manual-only invocation by the supported consuming harnesses. A harness-specific prompt installed at user scope is not, by scope alone, a Global prompt.

**Global-compatible prompt form**:
A Prompt representation documented to support shared manual-only use across the supported Harnesses, independently of its installation scope or actual cross-project availability.

**Harness-specific prompt**:
A Prompt authored for an explicitly selected harness's native conventions and supported fields, independently of whether it is available in one project or across projects.

**Native prompt template**:
A harness-native instruction template expanded on explicit user invocation, distinct from a Skill-backed prompt and subject to its own substitution semantics.

**Named native field**:
A documented native field of one resource kind and profile, supplied by name to a shared authoring operation. An unsupported field is refused with the supported names rather than ignored.

**Supported native field matrix**:
The documented set of named native fields for one resource kind and profile, with their value shapes, requiredness and supported clearing or inheritance. Accepting one field name across profiles does not establish equivalent semantics.

**Authoring plan**:
A read-only proposal for a native authoring or conversion operation, carrying the proposed native content, the reviewed observations and a stable plan identity. Building one writes nothing.

**Authoring publication**:
The reviewed publication of one authoring plan into its native location. It never rebuilds the proposal: a changed plan, a changed source, an occupied target or an unverified authority refuses the publication.

**Author-only output**:
A published native output without an ongoing installation record. It is untracked, not inert: a harness may still discover a file placed in one of its native roots.

**Authoring receipt**:
The evidence of one authoring act for an unmanaged output. A receipt is not an installation record, it does not bind an update source and it never adopts a source or an output.

**Authoring recovery copy**:
The protected copy of the previous bytes of an edited, replaced or retired source. It is evidence of the earlier content, not an installation record, and it does not restore ownership of the source.

**Authoring transaction**:
The versioned evidence of one ordinary authoring publication. It binds the reviewed plan, the published target, the reviewed source and the phase of the publication, and it is the authority of an interrupted publication. It is not an installation record.

**Recovery review identity**:
The digest of the current observations of one transaction and of the recovery it permits. It is the approval of one reviewed recovery or cleanup, and it is invalidated by any change of the observed state.

**Prompt pack installation**:
The installation of valid, supported skill-backed Prompts through the existing native Skill installation and its safety machinery. It keeps the Skill ownership record of the installed resource and it never adopts a standalone template or a Pi target.

**Prompt selection**:
The explicit selection of the Prompt resources of a pack for one or more requested targets. Every selected resource must be a valid Prompt in the view of every requested target, and the selection is refused as a whole when one resource does not qualify.

**Prompt scope**:
The declared and discovered Prompt sources of a pack. It holds the declared Skill entries, the declared Prompt entries and the Prompt discovery root. A declared catalog is authoritative, and the same source path declared twice is a conflicting declaration. The Prompt selection of a pack holds the sources of the scope that are a Prompt in a consumer view.

**Native Prompt view**:
The classification, the validity, the installation support and the diagnostics of one native source in one consuming harness. A source can be a Prompt for Claude and an ordinary Skill for Codex, and the view never states one universal classification.

**Native placement**:
The observed location context of a resource: project, user, uninstalled source, or unknown. Compatibility of a native form does not establish its placement, availability, or activation.

**Ownership-unverified observation**:
A discovered resource whose management authority could not be verified. Unverified ownership establishes neither a managed installation nor an unmanaged resource.

**Harness**:
An AI coding environment whose supported resources, native formats, and installation conventions determine how a resource can be used. A consuming harness is the harness whose native rules govern a particular resource view.

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

**Canonical skill installation**:
A managed skill installation whose owned contents are shared with consuming harnesses through explicitly tracked exposures, without assigning competing ownership of those contents to each harness.

**Harness exposure**:
A recorded way a harness can discover an installed resource, directly or through an associated link; an exposure does not establish that the harness loaded or activated the resource.

**Linked installation**:
A managed installation that owns only a link entry pointing to a resource; its target remains outside that installation's ownership.

**Installation baseline**:
The recorded state of a managed installation against which later changes are assessed; copied installations track their owned contents, while linked installations track the owned link entry separately from target-content observations.

**Recovery backup**:
A retained prior state of a managed installation that can support verified restoration; a linked installation's backup preserves the link, not a historical snapshot of its target.

**Managed replacement**:
Replacing the owned entry at a recorded installation location while continuing the same managed installation identity.

**Conversion lineage**:
The recorded relationship between a source resource and its converted successor, preserving their history without treating distinct installation locations or native forms as one managed identity.

**Conversion restore**:
An explicitly reviewed reversal of a completed conversion using retained source evidence, distinct from recovering an interrupted conversion or automatically adopting an unmanaged resource.

**Coordinated transaction reservation**:
The persisted claim of one pending coordinated conversion over its source and target participants, their installation identities, and their native names. The reservation is held by the recorded evidence rather than by the current occupant of a path, so a changed or missing occupant neither releases it nor proves the path free.

**Participant reference**:
The immutable intent of one coordinated conversion published in the scope that does not coordinate it, so that the reservation is visible to a mutation that cannot reach the coordinating scope. A participant reference is a discovery hint, never permission to act in another scope.

**Mutation plan**:
A reviewable proposal for changing a resource installation and its management records, based on observations rather than reserved filesystem state or permission to bypass safety checks.

**Resource origin**:
Where a resource came from, distinct from where it is installed; an origin may be unknown, declared, or supported by recorded evidence.

**Pack**:
A resource collection offered by a source, which may contain Skills, Agent definitions, or multiple resource types. Its available contents are distinct from the subset installed by a user; it is not itself an individual managed installation.

**Skill pack**:
A Pack offering Skills, often identified by its source repository owner and name, such as `mattpocock/skills`; the source may also offer other resource types.

**Reviewed resource inventory**:
The resource paths known at a Pack's last successful review for a resource type, including paths the user declined to install. Skills are identified by resource-folder paths and Agent definitions by native file paths; this inventory is distinct from installation ownership and installed-version state.

**Recorded snapshot ref**:
A reference to a retained historical installation snapshot, associated with the source evidence and content needed to identify that historical state. It selects a rollback version independently of the current meaning or availability of an upstream Git ref.

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
