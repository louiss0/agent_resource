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
3. stages an independent source payload and proposed target under protected
   conversion storage and verifies both manifests;
4. persists the resolved participants and identity/membership intents;
5. publishes and verifies the native target;
6. writes one protected commit decision binding source, payload, target, and
   transaction identity;
7. reconciles target ownership and source retirement across project and user
   ledgers, recording detached/retired membership observations with the records;
8. retains the verified source payload, removes private staging/quarantine
   entries, and persists terminal evidence.

A failure before the commit decision restores or removes only a target whose
staged digest still binds and records `rolledBack`. A failure after the commit
completes forward when possible. A reconstructed coordinator can validate the
persisted decision and payloads, replay idempotent ledger reconciliation, and
finish cleanup. Changed, missing, corrupt, ambiguous, or unsupported evidence
is retained as `recoveryRequired` and reported with status 6.

## Supported forms

The engine covers regular-file to regular-file, directory to regular-file, and
same-location regular-file replacement. Directory targets are supported for
copied and canonical Skill forms. `skill-link` target publication is refused:
the coordinator does not manufacture an ordinary directory where lifecycle
semantics require a native link.

Unmanaged authoring transitions retain their receipt-only identity and create no
installation record. Managed moved or reclassified targets receive the identity
resolved by the evidence service; same-location/same-form transitions keep the
existing installation identity.

## Safety and evidence limits

- Proposed target paths must be safe relative paths. Existing target occupants
  and cross-scope live ownership are refused before staging.
- Managed source identity is checked against ledger scope, location, root, kind,
  form, and live lifecycle before publication.
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

## Verification evidence

The focused suite injects failures at preparation, payload copy, target staging,
evidence persistence, publication, commit, ledger reconciliation, cleanup, and
in-place quarantine. It covers cross-scope reconciliation, source/target drift,
unsafe paths, occupied and cross-scope-owned targets, unsupported links,
readable terminal evidence, membership observations, and reconstructed-service
post-commit completion.

The complete Dart suite passed locally on Windows with 762 passing and 4
platform-skipped tests. `dart analyze` passed. These checks exercise the
filesystem seam and memory-backed reconstructed services; they do not certify a
Claude, Codex, or Pi runtime, native harness activation, hostile concurrency, or
power-loss durability.
