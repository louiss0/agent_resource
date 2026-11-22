# Product audit: completeness, guidance, and preferences

## Summary

Agent Resource has substantial functionality, but its four core resource
surfaces do not yet form a consistent product. The primary problem is not
simply too few features or too few interactive questions. It is inconsistent
workflows, partially integrated preferences, cross-feature incompatibilities,
and documentation that no longer reliably describes the implementation.

A focused consolidation phase is recommended, not a rewrite.

## Scope and evidence

This audit covered MCP registrations, Skills, Prompts, Context templates and
injection, command discoverability, guided interaction, and preferences.
It traced executable registration, commands, services, tests, and specs.

Fresh local verification during the audit:

- Root and resource-group help were exercised.
- `dart analyze` reported no issues.
- `dart test --reporter compact` finished with 1,687 passing tests and 5 skips.
- No implementation files or real user resources were intentionally changed.

These checks do not establish live Claude/Codex/Pi activation, runtime
compatibility, cross-platform terminal acceptance, or release qualification.
The code-traced concerns below have not been independently reproduced by
new targeted tests during this audit.

## 1. Feature completeness

All four requested resource types are implemented, but they have different
lifecycle coverage.

| Resource | Implemented surface | Main product gap |
| --- | --- | --- |
| Skills | Creation, inventory, inspection, validation, installation, adoption, replacement, removal, backups, and recovery | Comparatively mature, but native validation and installation admission differ |
| MCP | Inventory, static validation, registration, adoption, replacement, removal, conversion, backups, and recovery | Ordinary editing and native credential-reference workflows remain incomplete |
| Prompts | Creation, inventory, inspection, validation, restricted pack installation, and transaction recovery | No cohesive public editing, installation, and management lifecycle |
| Context | Reusable template creation, editing, deletion, selection, and injection | Injection is one-shot publication, not tracked destination synchronization |

Important boundaries:

- There is no registered direct `prompt install` or `prompt edit` command.
- Supported Prompt pack installations use Skill ownership records. Subsequent
  lifecycle operations use Skill selectors rather than Prompt selectors.
- Pi Prompt templates can be created and inspected but cannot be installed
  through the Prompt pack route.
- Prompt creation refuses managed publication through `--manage`.
- Editing a stored Context template does not automatically update files into
  which it was previously injected.
- MCP inspection and validation are static operations, not connectivity or
  runtime activation checks.
- Claude user/local MCP scopes are inspect-only for native mutation.

These can be legitimate release boundaries. They should be documented as
intentional limits rather than discovered through command refusals.

### Supporting locations

- `lib/agent_resource.dart`: composition root and registered resource groups.
- `lib/skill.dart:53–70`: Skill command registration.
- `lib/prompt.dart:28–41`: Prompt command registration.
- `lib/src/services/pack_lifecycle_service.dart:583–623`: restricted Prompt
  routing through pack installation.
- `lib/src/services/pack_prompt_service.dart:169–220`: Prompt selection and
  target restrictions.
- `lib/src/services/mcp_mutation_service.dart:247–264`: inspect-only Claude
  mutation scopes.

## 2. Preferences exist, but are hidden and inconsistent

The persistent preference model already supports:

- Preferred installation targets.
- Preferred Skill installation method.
- Snapshot retention days.

Pack workflows use this model. Direct `skill install` and `agent install`
construct their requests without loading the same preference model.

The public `config` group exposes `validate`, but no effective-settings
viewer or preference editor. Users cannot readily discover which settings
are in effect, their configuration path, or where individual values came
from.

Some direct-install choices instead come from hardcoded defaults or detected
native directories. Detection is useful evidence, but it is not saved user
intent.

### Recommended preference experience

Build on the existing configuration rather than create a second settings
system:

1. Show effective settings and configuration paths.
2. Explain each resolved value's origin: explicit argument, project config,
   user config, detection, or built-in default.
3. Provide an explicit, previewable way to save preferences.
4. Apply existing preferences consistently to interactive direct-install
   and pack workflows.
5. Preserve explicit unattended contracts rather than silently changing
   script behavior through newly consulted personal defaults.

Useful durable questions include:

- Which harnesses should normally be selected?
- Should this resource apply to this project or across projects?
- Should Skills normally use canonical storage, copies, or local source links?
- Should the selected preference be saved?

Approval, adoption authority, destructive consent, risk acknowledgements,
and credentials must not become remembered blanket permissions.

### Supporting locations

- `lib/src/pack/pack_configuration.dart:61–84`: preference model.
- `lib/src/pack/pack_configuration.dart:313–429`: user configuration and
  preference inheritance.
- `lib/src/pack/pack_configuration.dart:856–903`: accepted preference keys.
- `lib/src/services/pack_lifecycle_service.dart:4550–4639`: pack target and
  method resolution.
- `lib/config.dart:12–28`: public configuration command surface.

## 3. Guidance needs consistency, not more questions everywhere

Installation already supports meaningful interaction: source entry, resource
selection, consumer selection, profile selection where applicable, plan
presentation, and approval.

The gaps are elsewhere:

- Guided creation still requires an explicit profile before its missing-field
  guidance begins.
- Creation defaults to project scope, while bare Skill and Prompt inventory
  defaults to user scope. A newly created resource can therefore appear to
  be missing from a subsequent bare list command.
- Creation normally plans first and requires `--apply` for publication;
  installation follows a different interaction pattern.
- Context injection can request confirmation before rendering its destination
  and change report.
- Pack interactivity checks stdin terminal availability without consistently
  requiring stdout to be a terminal as well.
- Root help lists groups but does not provide a short task-oriented first
  success path.

Recommended interaction principles:

- Keep no-argument help read-only.
- Offer an optional guided starting point that routes into existing flows.
- Show resolved scope, targets, method, and their origins.
- Let users change relevant choices without asking every question every time.
- Standardize preview, then confirmation, then write.
- Require usable input and output terminals for interactive workflows.
- Show an equivalent explicit command after guided operations where useful.

### Supporting locations

- `lib/src/installation/installation_interaction.dart:28–49`: existing
  installation interaction contract.
- `lib/src/installation/installation_batch.dart:28–38`: installation preview
  before approval.
- `lib/src/authoring/guided_create_command.dart:202–211`: explicit profile
  requirement.
- `lib/src/authoring/guided_create_fields.dart:30–35`: creation scope default.
- `lib/skill.dart:108–112` and `lib/prompt.dart:211–215`: inventory defaults.
- `lib/context_inject.dart:138–195`: report and approval ordering.
- `lib/pack_action.dart:286–289`: pack terminal detection.

## 4. Cross-feature concerns to reproduce before expansion

The following are code-traced findings, not newly reproduced failures.
They should become focused regression tests before implementation changes.

### Canonical installation versus Prompt inventory

Canonical Claude Skill installation creates a native link exposure. Prompt
inventory refuses visible linked candidates before classification, potentially
causing a normal installation workflow to make an inventory workflow fail.

Evidence:

- `lib/src/services/skill_installation_service.dart:313–337`
- `lib/src/services/prompt_read_service.dart:175–210`

Desired outcome: safe inventory behavior that remains usable in the presence
of the application's own canonical installations, without blindly following
untrusted links.

### Validation versus installation admission

Public native Skill validation and installation use different acceptance
rules. A native field can be valid for a harness but rejected by the stricter
installation validator.

Evidence:

- `lib/skill.dart:308–332`
- `lib/src/services/skill_lifecycle_service.dart:956–980`
- `lib/src/skill_validation.dart:408–420,507–521`
- `test/skill_native_view_test.dart:180–202`

Desired outcome: distinguish native validity from installation eligibility
explicitly, or align the admission rules where appropriate.

### MCP replacement is a partial patch interface

Replacement merges maps and only updates arguments when supplied arguments
are non-empty. It lacks clear removal semantics for ordinary fields and does
not cleanly switch transport by removing incompatible existing fields.

Evidence: `lib/src/services/mcp_mutation_service.dart:490–511`.

Desired outcome: ordinary edits can explicitly clear or remove values, with
reviewable native consequences.

### MCP credential references need harness-specific encoding

New environment/header inputs accept reference-like strings, but Codex output
uses static `env` and `http_headers` maps rather than exposing native
reference fields such as `env_http_headers`, `bearer_token_env_var`, or
`env_vars`. Static shape validation does not establish working authentication.

Evidence:

- `lib/src/services/mcp_mutation_service.dart:466–535`
- `lib/src/mcp/mcp_validation.dart:246–260`
- `docs/research/codex-mcp.md:13–19`

Desired outcome: encode references according to the selected harness and
refuse unsupported substitutions instead of assuming portable semantics.
Live behavior remains unverified by this audit.

### Context confirmation can leave stale destination evidence

Template authoring observes the destination before awaiting approval, then
stages and publishes without a matching destination recheck after approval.
An external change during the confirmation wait may be overwritten.

Evidence: `lib/src/services/context_template_authoring_service.dart:207–238`.

Desired outcome: test changes during approval and enforce a documented,
bounded concurrent-writer contract.

### Context multi-target publication can be partial

Context injection publishes targets sequentially and writes receipts after
each rename. A later failure can leave earlier targets changed. Staging under
user state and renaming into a project also deserves cross-volume testing.

Evidence: `lib/src/services/context_injection_service.dart:252–302`.

Desired outcome: explicit partial-failure reporting and a verified recovery
journey, with publication behavior tested across supported filesystem layouts.

### Context parent-link boundary needs verification

Folder checks inspect descendants below the selected project root, while
final-target checks do not establish the complete parent chain. Injection to
`.claude/CLAUDE.md` through a linked `.claude` parent deserves a targeted test.

Evidence:

- `lib/src/context/context_target_resolution.dart:85–86`
- `lib/src/services/context_injection_service.dart:426–494`

Desired outcome: make the trusted-root and no-link boundary explicit and
verify it for roots, native homes, intermediate directories, and final files.

## 5. Documentation drift contributes directly to confusion

The README understates current Skill support. Its claim that Codex's
`agents/` sidecar directory is not accepted contradicts current tree
validation, which permits that native support directory. Installation also
contains root Markdown migration behavior absent from the old restrictions.

The initial command overview omits MCP and Context, although both are
registered. Dedicated first-success walkthroughs for those resource types
are missing. Some planning documents describe delivered behavior as pending
or absent.

Evidence:

- `README.md:54–61,142–153`
- `lib/src/services/lifecycle_state_service.dart:4144–4175`
- `lib/src/installation/skill_root_markdown_migration.dart:68–138`
- `docs/specs/prompt-feature-delivery.md`
- `docs/specs/prompt-pack-installation.md`
- `docs/specs/prompt-pack-discovery.md`

The existing `docs/release-qualification.md`, which was already untracked at
the start of this audit, says the project is not qualified for release. Its
historical verification evidence must not be confused with this audit's
fresh local test run.

Recommended documentation structure:

- A short statement of the first-release promise.
- One first-success journey for each core resource type.
- A current supported/limited/deferred feature matrix.
- A preference and configuration guide.
- Separate advanced references for ownership, transactions, and recovery.
- Clear labels distinguishing planning documents from delivered contracts.

## 6. Recommended consolidation order

### First: define a bounded release promise

Choose supported end-to-end journeys for each core resource type and record
intentional deferrals. Do not require identical command trees where native
formats genuinely differ.

Feature completeness should be measured against these agreed journeys, not
against the number of services or command names.

### Second: reproduce and address cross-feature and publication gaps

Prioritize inventory interoperability, validation/admission consistency,
Context approval drift, path boundaries, and partial-publication behavior.
Use targeted regression tests before repair.

### Third: make existing preferences visible and consistent

Expose effective configuration and value provenance. Apply the current
preference model consistently to interactive workflows before adding many
new preference fields.

### Fourth: standardize the interactive contract

Make preview-before-confirmation-before-write consistent. Explain scope and
method defaults. Normalize terminal detection and preserve unattended
behavior.

### Fifth: refresh first-success documentation

Document what the implementation actually supports, including intentional
limits. Keep advanced recovery concepts available without making them the
first thing ordinary users must understand.

## Conclusion

This is a feature-rich implementation that needs integration, clearer
boundaries, and a more deliberate user experience. Test health is strong,
but does not resolve product completeness or release readiness.

The next milestone should be **make the existing core predictable**, not
**add enough features to feel complete**.
