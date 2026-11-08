# Coordinated conversion state and recovery

This spec records the implemented internal coordinator slice for Prompt resource
conversion. It follows the versioned evidence and identity contract in
[`conversion-evidence-identity.md`](conversion-evidence-identity.md) and the
canonical decisions in issues [#65](https://github.com/louiss0/agent_resource/issues/65),
[#76](https://github.com/louiss0/agent_resource/issues/76), and
[#80](https://github.com/louiss0/agent_resource/issues/80).

The delivery ticket is [#68](https://github.com/louiss0/agent_resource/issues/68).

## Scope

`ConversionCoordinator` is an internal transition engine. It does not register a
command, expose public apply or recovery, or bypass the later pending-transaction
and publication gates.

For one reviewed conversion it:

1. acquires the existing project/user lifecycle coordination domain;
2. verifies the source baseline, target absence, source ledger identity, target
   ownership across both scopes, and supported target form;
3. persists the resolved participants, original source record, authority context,
   and identity/membership intents before creating transaction staging;
4. stages an independent source payload and proposed target under protected
   conversion storage, verifies both manifests, and upgrades the intent;
5. publishes and verifies the native target;
6. writes one protected commit decision binding the complete reviewed evidence,
   including participants, payloads, ownership, membership, and context;
7. reconciles target ownership and source retirement across project and user
   ledgers without discarding unrelated pack/history record groups;
8. verifies the original source or quarantine, records removal intent, removes
   that original and private staging, retains the independent source payload,
   and persists terminal evidence.

A failure before the commit decision restores or removes only a target whose
staged digest still binds and records `rolledBack`. A failure after the commit
completes forward when possible. A reconstructed coordinator can validate the
persisted decision and payloads, replay idempotent ledger reconciliation, and
finish cleanup. Changed, missing, corrupt, ambiguous, or unsupported evidence
is retained and reported with status 6. The coordinator records `recoveryRequired`
where possible without erasing an already-observed committed/reconciled phase or
reopening a terminal transaction. A missing commit marker is not rollback
permission when the evidence or materialized ownership contradicts rollback.

## Supported forms

The engine covers regular-file to regular-file, directory to regular-file, and
same-location regular-file replacement. Directory targets are supported for
copied and canonical Skill forms. `skill-link` target publication is refused:
the coordinator does not manufacture an ordinary directory where lifecycle
semantics require a native link.
Linked and canonical/shared source installations are refused; conversion cannot
retire a resource while leaving unmanaged shared exposures behind.

Unmanaged authoring transitions retain their receipt-only identity and create no
installation record. Managed moved or reclassified targets receive the identity
resolved by the evidence service; same-location/same-form transitions keep the
existing installation identity.
Retained identities preserve backup associations and provenance. Moved targets
retain source provenance separately from their own upstream tracking; the retired
source keeps its original backup associations.

## Safety and evidence limits

- Proposed target paths must be safe relative paths. Existing target occupants
  and cross-scope live ownership are refused before staging. Linked ancestors,
  overlapping source/target trees, and overlap with management storage reject.
- Managed source identity is checked against ledger scope, location, root, kind,
  form, and live lifecycle before publication.
- Recovery binds the original project/user authority context and checks exact
  source record snapshots, target identity collisions, and cross-scope ownership
  before reconciliation. It does not replace later ledger edits with a fresh
  baseline or infer that an unavailable scope is unowned.
- Source and target observations are rechecked at the live-mutation boundary.
- Manifest traversal is bounded, does not follow links, and rejects unsupported
  entries. Conversion evidence and management documents retain their existing
  byte/depth/node limits.
- The coordinator uses the existing cooperative lifecycle lock domain. It does
  not claim resistance to hostile external writers, an atomic multi-file or
  cross-ledger filesystem transaction, or guaranteed power-loss durability.
  The protected commit decision and retained payload provide logical replay and
  conservative refusal within the repository's documented local-filesystem
  trust envelope.
- Protected document replacement uses a flushed bounded write because portable
  Dart rename-overwrite behavior differs by platform. A torn or corrupt document
  fails closed; it is not accepted as free state.
- An immutable initial-intent copy supports rollback if the preparation evidence
  upgrade tears. It is removed before live publication. A torn first intent or
  later document without a valid fallback remains blocked, not guessed away.
- Rollback verifies the original/quarantine and retained payload before removing
  a published target. Partial or changed publication is retained for recovery
  rather than deleted merely because this invocation attempted to write it.

## Verification evidence

The focused suite injects failures at preparation, payload copy, target staging,
evidence persistence, publication, commit, ledger reconciliation, cleanup, and
in-place quarantine. It covers cross-scope reconciliation, source/target drift,
unsafe paths, occupied and cross-scope-owned targets, unsupported links,
readable terminal evidence, membership observations, and reconstructed-service
post-commit completion. Cross-scope tests interrupt after target publication,
commit, each ledger publication, source removal, and staging cleanup. Regression
cases cover ledger-group preservation, backup associations, changed source
metadata, changed authority, participant/commit mismatch, torn preparation
evidence, and repeated refusal after a committed decision disappears.

The complete Dart suite passed locally on Windows with 786 passing and 4
platform-skipped tests. `dart analyze` passed. Separate disposable-directory
smoke checks on the real Windows filesystem interrupted moved-file, in-place,
and directory-to-file conversions after commit publication, then reconstructed
services and verified target bytes, original-source removal, retained backup
bytes, and unrelated ledger history. The deterministic suite also exercises
memory-backed cross-scope restart boundaries. These checks do not certify a
Claude, Codex, or Pi runtime, native harness activation, cross-volume rename
capability, hostile concurrency, or power-loss durability.
