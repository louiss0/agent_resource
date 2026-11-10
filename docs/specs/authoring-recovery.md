# Authoring interruption recovery and guarded evidence cleanup

This spec records the implemented recovery slice of the authoring feature set.
It follows the publication contract in
[`safe-native-publication.md`](safe-native-publication.md) and the coordinated
transition contract in
[`coordinated-conversion-state.md`](coordinated-conversion-state.md).

The delivery ticket is [#70](https://github.com/louiss0/agent_resource/issues/70).

## Scope

The slice wires the ordinary authoring publication into a transaction
authority and exposes its inspection, its recovery and its guarded cleanup.

It adds:

- `lib/src/authoring/authoring_transaction.dart`: the versioned transaction
  document of one ordinary publication.
- `lib/src/authoring/authoring_receipt.dart`: the protected authoring receipt
  of one unmanaged output.
- `lib/src/services/authoring_recovery_service.dart`: the inventory, the
  inspection, the reviewed recovery and the reviewed cleanup.
- `lib/authoring.dart` and `lib/authoring_action.dart`: the registered
  `authoring list|inspect|recover|cleanup` commands.
- the transaction recording of the ordinary publication in
  `lib/src/services/authoring_publication_service.dart`.

The public authoring create, edit and conversion routes remain gated: this
slice exposes the recovery of an interrupted publication, not a new way to
publish.

## The transaction authority

- An ordinary publication records one transaction before its live change. The
  document binds the reviewed plan, the published target, the reviewed
  source, the digest of the published content, the retained recovery payload
  and the phase of the publication.
- The phases are `prepared`, `published`, `committed`, `completed` and
  `rolledBack`. The receipt of the publication is the commit point: the
  transaction is committed with the receipt and completed after it. A
  publication that committed its receipt is never rolled back.
- The document is private, bounded and fail closed. An unknown key, an
  unknown schema version, a corrupt digest and an inconsistent document are
  never evidence of a free state.
- A managed publication keeps the transaction authority of the ordinary
  lifecycle or of the coordinated transition. It never records a second
  authoring transaction.
- An authoring transaction is not an installation record. It never adopts a
  source and it never binds an update source.

## The recovery interface

- `authoring list` inventories the transactions of the selected scopes. It
  takes no lock, writes nothing and keeps a corrupt document visible as
  unresolved evidence. A retained payload or a staged candidate that no
  transaction records stays visible as an orphan.
- `authoring inspect` reports the transaction, the current observations of
  the published target, the reviewed source and the retained payload, and the
  recovery that the transaction permits. It writes nothing.
- `authoring recover` is a read-only review without a plan identity or
  without `--apply`. The apply requires the current review identity, the
  explicit approval, the apply mode and the permitted direction of the
  transaction.
- A transaction before its commit may be rolled back: the published target is
  removed and the reviewed source is restored from the retained payload. The
  rollback verifies the retained payload and the current observations before
  it removes anything, and it restores the reviewed source over the published
  content, so an entry outside the reviewed manifest is never removed. A
  committed transaction may only be completed: the published target is
  verified and the missing receipt is written.
- `authoring cleanup` removes the retained private payload of a terminal
  transaction. It keeps the evidence document as the audit record and it
  forfeits the payload based restore of the source. The review discloses the
  forfeiture, the cleanup writes a bound cleanup intent before the deletion
  and it refuses a payload that carries an unexpected or changed member. An
  unfinished transaction is never cleaned up, and a repeated cleanup is
  refused.
- No recovery path deletes an unfinished transaction, an editing draft or a
  user input file. The drafts of the editor and the transactions of the
  native publication are separate authorities.

## Refusals

| Refusal | Status |
| --- | --- |
| The transaction does not exist | 4 |
| The review identity is stale | 4 |
| The explicit approval is missing | 4 |
| The recovery direction is not the permitted one | 4 |
| The transaction is terminal | 4 |
| An unfinished transaction is cleaned up | 4 |
| The transaction changed since the review | 6 |
| The published target changed | 6 |
| The source changed since the publication | 6 |
| The publication committed its receipt | 6 |
| The retained payload is missing or changed | 6 |
| The retained payload is not a readable copy | 6 |

## Evidence and limits

The focused suites cover the transaction recording of an ordinary
publication, the inventory, the read-only inspection, the rollback of an
interrupted publication, the restoration of the reviewed source, the refusal
of a stale review identity, a missing approval, a changed target, a
committed receipt, a terminal replay, the cleanup of a terminal transaction,
the refusal of an unfinished and of a repeated cleanup, the orphan payload in
the inventory, the reconstruction of the service, the visibility of a corrupt
document and the registered commands.

The complete Dart suite passes locally on Windows with 932 passing and four
platform-skipped tests. `dart analyze` reports no findings.

The checks are static ownership and recovery evidence. No Claude, Codex or Pi
runtime was exercised, no native harness activation was proven and the
completed inverse restore of a conversion remains a separate slice.

## Open questions

- The recovery of an ordinary publication restores the reviewed source from
  the retained payload. A reviewed inverse restore of a *completed*
  conversion is a separate dependent slice and is not available here.
- The authoring transaction reserves the paths of its target and its source
  only while it is not terminal. A pending authoring transaction does not yet
  reserve a native name across the discovery roots, so a name conflict with a
  pending publication is not detected by the pending-transaction guard.
