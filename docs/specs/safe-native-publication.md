# Safe author-only and managed native publication

This spec records the implemented internal publication slice of the authoring
feature set. It follows the read-only authoring plan in
[`shared-native-authoring-inputs.md`](shared-native-authoring-inputs.md), the
versioned evidence contract in
[`conversion-evidence-identity.md`](conversion-evidence-identity.md) and the
coordinated transition contract in
[`coordinated-conversion-state.md`](coordinated-conversion-state.md).

The delivery ticket is [#69](https://github.com/louiss0/agent_resource/issues/69).

## Scope

`AuthoringPublicationService` publishes one reviewed authoring plan. It never
rebuilds a proposal: the reviewed plan carries the proposed native content and
the reviewed observations, and the publication refuses anything that no longer
matches them.

The slice adds:

- `lib/src/services/authoring_publication_service.dart`: the publication
  engine.
- `lib/src/authoring/package_manifest.dart`: the bounded reviewed manifest of
  the owned members of a native package.
- the reviewed conversion direction, source marker digest, package member
  digest and package shape of an output override in the authoring plan.
- the optional native destination of a conversion ownership in the conversion
  evidence.

No command adapter is registered. The public frontends arrive with their own
slices, and the public JSON operation-request routes are removed by those
frontend and migration tickets rather than by this module.

## Approval

- The publication requires the current plan identity. A stale identity is
  refused.
- The publication requires explicit approval. Planning, a dry run and a
  missing approval publish nothing.
- A plan that is not ready is refused. The strict semantic, required-field and
  reference gates stay in the plan: a proposal with an unresolved field, an
  unresolved native reference or an invalid native content is never
  published.
- A publication rechecks the reviewed observations at the live boundary: the
  source marker digest, the reviewed package member manifest, the occupancy
  of the target, the ownership of the target and the native uniqueness of the
  placement.

## Ownership

- A new output is author-only by default. An author-only output has no
  installation record, no baseline and no adoption. It carries an authoring
  receipt, which is persisted as a protected document beside the other
  management evidence: the receipt is evidence of an authoring act and not an
  ownership record.
- A managed publication requires an explicit request and a supported form and
  location. It reuses the ordinary lifecycle publication, so the installation
  record, the baseline, the uniqueness authority and the pending-transaction
  guard of that lifecycle apply.
- Managed publication is supported for Claude and Codex Skills and for
  Claude, Codex and common-Pi Agents. A Prompt has no managed lifecycle: a
  managed Prompt request is refused instead of falling back to an author-only
  output, and the Pi Prompt installation is not bypassed.
- An ordinary edit stays unmanaged. It does not require adoption and it does
  not create an installation record.
- A managed edit replaces the recorded installation and keeps its identity,
  its location and its backup associations.

## Placement

- The target must be absent. A new output never takes over an occupied or
  ambiguously owned path, not even one with identical bytes.
- A native placement applies the native uniqueness and shadowing rules even
  when the output is untracked: a native root is a discovery location. An
  output outside a native root carries no installed-name constraint, so a
  source folder keeps the name of the proposal.
- The output of an explicit override names the package directory, unless it
  names the marker of the package itself. The native name must match the
  directory name of a native placement and of an in-place edit.
- A clone copies the reviewed owned package members and the exact decoded body
  of the source. It copies no external dependency, no parent configuration and
  no runtime state, and it leaves the source untouched.
- A derived output keeps the honest evidence of its source. It never inherits
  the pack membership or the upstream update tracking of its source, it never
  copies the installation identity of its source and it never claims a
  verified origin.

## Edits, conversions and recovery

- An ordinary edit replaces the source in place. The proposed content is
  staged in protected storage and verified before the live source changes,
  and the previous bytes are retained as a protected authoring recovery copy.
- A managed package is staged next to the native root, in the private
  authoring staging directory of that root. The ordinary installation
  refuses a source that overlaps the management storage, so the staged
  package stays outside it. The staged package is removed after the
  publication, and the shared staging root is only removed when it is empty.
- A classification change routes through the conversion path. A Skill to
  Prompt edit is published as a conversion, and a Prompt to Skill edit is
  refused by the plan.
- A tracked conversion is published through the coordinated transition, so
  the ownership, the identity, the ledger reconciliation and the recovery
  payload follow the conversion contract. A same-location, same-form
  transition keeps the installation identity; a relocated or reclassified
  target receives a new linked identity and the source is retired.
- An ordinary conversion is published through the authoring path: the target
  is published and verified, the previous bytes are retained as a protected
  authoring recovery copy, and the source is retired only after the published
  target is verified. An in-place reclassification replaces the source
  content and a relocation removes the verified source entries. An entry
  outside the reviewed manifest is never removed: the source stays and the
  retirement is refused.
- A publication failure before the live write leaves no partial native
  output. A failure after the source was retired leaves the retained recovery
  copy of the previous bytes in place.

## Refusals

| Refusal | Status |
| --- | --- |
| The plan is not ready | 4 |
| The approval does not bind the current plan identity | 4 |
| The approval is missing | 4 |
| A dry run publishes nothing | 4 |
| The target is occupied | 4 |
| The target is already owned by an installation | 4 |
| The native name collides with a visible native name | 4 |
| The reviewed source changed after the plan was built | 4 |
| A managed publication of a Prompt | 4 |
| A managed publication outside an eligible native location | 4 |
| A managed source changed since its baseline | 4 |
| The staged candidate changed before publication | 6 |
| The published native target does not match the reviewed proposal | 6 |

## Changes to the shared seams

- The authoring plan exposes the reviewed conversion direction, the marker
  digest and the package member digest of the source, and the package
  directory of the placement. The plan identity binds them, so a changed
  source or a changed placement produces a different plan identity. The
  native destination of the placement follows the selected profile, which the
  plan identity already binds.
- The Pi Skill to Prompt conversion publishes a standalone native template in
  the Pi prompt root and records that the source must be removed, instead of
  proposing an in-place reclassification.
- The conversion ownership evidence carries an optional native destination. It
  is absent from an existing document, so an existing evidence digest stays
  valid, and it binds the destination of a reconciled record instead of
  guessing it from the native profile.

## Evidence and limits

The focused suite in
`test/src/services/authoring_publication_service_test.dart` covers the
author-only and managed publication of Skill packages, Agent files and Prompt
files, the clone of the owned package members, the refusal of an occupied
target, a stale identity, a missing approval, a managed Prompt request, a
changed source, a native name collision, a source-folder output, the ordinary
and the tracked conversion, the reclassification of a Skill into a Prompt, the
refusal of a Prompt to Skill reclassification, a failed publication and an
interrupted conversion publication.

The complete Dart suite passes locally on Windows with 909 passing and four
platform-skipped tests. `dart analyze` reports no findings.

The checks are static validity, ownership and readiness evidence. No Claude,
Codex or Pi runtime was exercised, no native harness activation or discovery
was proven, and no public command reaches this slice yet. The managed
publication of a Prompt and the Pi Prompt installation remain unsupported by
product decision, not by an unfinished implementation.

## Open questions

- An ordinary Skill to Pi template conversion publishes an unmanaged native
  template. The conversion evidence models a Pi template target as a tracked
  representation, so this publication stays outside the coordinated
  transition. Whether an unmanaged Pi template may be published as a first
  class conversion target is a product question that is not settled here.
- The authoring plan resolves a tracked source in the selected scope, so an
  authoring conversion does not reach the cross-scope transition of the
  coordinator. A cross-scope authoring transition needs an explicit source
  scope in the plan.
- The recovery of an interrupted ordinary publication is limited to the
  retained recovery copy. A reviewed recovery interface for the ordinary
  authoring path is not part of this slice.
