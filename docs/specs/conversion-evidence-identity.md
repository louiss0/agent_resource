# Conversion evidence and identity transitions

This spec documents the implemented evidence slice of the Prompt conversion
feature: the versioned conversion transaction and participant schemas, the
baseline and payload binding, the complete before and after ownership and
membership records, and the identity transitions.

Canonical decisions: [conversion state migration and crash recovery](https://github.com/louiss0/agent_resource/issues/65),
[guided edit, clone, compose and conversion interactions](https://github.com/louiss0/agent_resource/issues/76) and
[ownership of newly authored cloned and composed outputs](https://github.com/louiss0/agent_resource/issues/80).

## Scope and boundaries

The slice implements the evidence contract only. It adds:

- `lib/src/conversion/conversion_evidence.dart`: the versioned evidence
  document, its participants, its records and its validation.
- `lib/src/conversion/conversion_identity.dart`: the identity transitions.
- `lib/src/services/conversion_evidence_service.dart`: the preparation and the
  read-only reading of persisted evidence.
- `lib/src/services/lifecycle_state_service.dart`: the native Pi template
  artifact kind for tracked conversions.

There is no coordinator, no publication, no installation mutation and no
command adapter in this slice. The coordinator, the coordinated transaction,
the recovery interface and the public frontends arrive with their own
tickets.

## The evidence document

The document is versioned (`schemaVersion` 1) and identified by a
`cvx_<32 hex>` transaction identifier. It carries exactly one source
participant and one target participant, the approvals, the observations and a
digest that binds the whole document.

Each participant records:

- the role and the intended effect, the native artifact kind, the native
  form, the native profile, the location, the native root and the scope;
- the identity: the installation identifier of a managed participant, the
  authoring receipt of an unmanaged one, and the lineage links;
- the ownership before and the ownership after;
- the upstream membership before and the membership after;
- the verified baseline manifest, the protected independent source payload,
  the staged target evidence and the publication evidence;
- the authority under which the participant is observed.

### Bounds and integrity

- The document is bounded to 4 MiB before it is parsed. The nesting depth is
  counted lexically before the document is parsed, and the node and depth
  limits are checked again on the parsed document.
- The baseline digest binds the manifest entries. A protected payload
  requires a verified baseline and its digest must equal the baseline digest
  of the same participant. An unprotected payload is refused.
- The document digest is computed over the canonical form of the document, so
  an equal document produces an equal digest.
- Unknown fields, an unknown schema version, an unknown artifact kind, a
  participant outside its recorded native root, a missing required ownership
  record, a mismatched participant role, a relative path and a corrupt digest
  all fail closed. They are never evidence of a free state.
- The evidence contains no resource classification label. The known-key
  sets reject any custom field, so a classification key cannot be carried
  into a native resource or an evidence document.

### Authority and scopes

A participant may record the authority under which it is observed: the scope,
the project root, the native root and the approval of that authority. Every
recorded native root, including the roots of the ownership records and of the
authority, must contain the location of the participant, so a persisted path
is not unvalidated write authority.

## Ownership, receipts and membership

- A managed participant owns an installation identifier. An unmanaged
  participant owns only an authoring receipt. A receipt never becomes an
  installation record: an authoring receipt does not adopt its source or its
  output.
- The ownership before and the ownership after describe the same location as
  the participant; a mismatch is refused.
- The membership records observe the upstream tracking of a participant. A
  derived target detaches the upstream tracking of its source: the provenance
  is retained, the source updates do not resurrect the derived target, and
  reassociation needs a separate explicit operation.

## Identity transitions

| Source and target | Identity effect |
| --- | --- |
| Same location and same native form | The target keeps the installation identifier; the installation continues and the source is not retired. |
| Different location or different native form | The target receives a new linked identifier, the source is retired, and the upstream membership is detached. |
| Unmanaged source | The target stays unmanaged; an unmanaged source never adopts and is never adopted. |

A relocated or reclassified target requires a new installation identifier. The
identity of the target records the retired source as its predecessor and as
the source it was converted from, so the conversion history stays linked
without pretending that the new identifier is the old one.

## Native artifact kinds

The participants keep the ownership of the artifact they are. There is no
universal Prompt kind. The kinds are the native ones: `skill-copy`,
`skill-link`, `skill-canonical`, `agent-file` and `prompt-template`.

The Pi template kind exists only for an approved tracked conversion: a
template target that is not a managed installation is refused. A template
source may be an ordinary unmanaged authoring artifact. There is no generic
new Pi prompt installation, and the ordinary Skill lifecycle compatibility of
an installed skill-backed Prompt is untouched.

## Legacy readability

The existing installation records keep their schema. A legacy record parses as
before, and a tracked Pi template record uses the new native artifact kind
with the same record shape. The conversion evidence lives beside the existing
state in its own directory and never changes the meaning of an existing
record.

## Evidence and limits

- The checks are static evidence about a conversion. They are not a
  coordinator decision, not a publication and not a runtime verification.
- No conversion was published, no installation record was written and no
  harness was invoked.
- The checks were run locally on Windows.
