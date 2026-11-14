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
- The document also binds the authority context of the publication: its
  scope, its state root, its project root, the effective home and the state
  root of the user scope when the host configures one. Copied evidence never
  authorizes a recovery in another scope, another project, another home or
  another user ledger.
- A scope that the host does not configure is never bound and never blocks a
  mutation: the authority of the recorded context decides which scope is
  read. An authority that the recorded context requires but that the host
  cannot resolve refuses the recovery; it is never treated as an unowned
  location. The authority is never rebaselined: a scope or a home that the
  recorded context did not bind and that the host offers later refuses the
  recovery.
- Every bound scope is read before a rollback: the project ledger and the
  user ledger of the recorded context. A live installation that owns or
  exposes the published target or the reviewed source refuses the recovery.
- The phases are `prepared`, `published`, `committed`, `completed` and
  `rolledBack`. The receipt of the publication is the commit point: the
  transaction is committed with the receipt and completed after it. A
  publication that committed its receipt is never rolled back.
- The evidence of a transaction records the reviewed content of the
  retained payload (`payloadManifest`), the reviewed content that the
  published target has to carry (`plannedManifest`), the verified content of
  the published target (`publishedManifest`) and the native location that the
  authoring receipt records (`receiptTarget`).
- The publication never blesses what it observes. The observed content of the
  published target has to equal the reviewed plan exactly; an unexpected
  member, a missing member or a changed byte is a failed publication.
- The document is private, bounded and fail closed. An unknown key, an
  unknown schema version, a corrupt digest and an inconsistent document are
  never evidence of a free state. A document is decoded before it is
  written, so an unreadable evidence document is never recorded.
- A managed publication keeps the transaction authority of the ordinary
  lifecycle or of the coordinated transition. It never records a second
  authoring transaction.
- An authoring transaction is not an installation record. It never adopts a
  source and it never binds an update source.

## The recovery interface

- `authoring list` inventories the transactions of the selected scopes. It
  takes no lock, writes nothing and keeps a corrupt document visible as
  unresolved. A retained payload or a staged candidate that no transaction
  records stays visible as an orphan. A recorded cleanup or rollback intent
  is reported with its own status and never as a transaction.
- `authoring inspect` reports the transaction, the exact current
  observations of the published target, the reviewed source and the retained
  payload, and the recovery that the transaction permits. It writes nothing.
- `authoring recover` is a read-only review without a plan identity or
  without `--apply`. The apply requires the current review identity, the
  explicit approval, the apply mode and the permitted direction of the
  transaction.
- The observations bind the exact current state: the observed content of the
  target, of the source and of the retained payload, the state of the
  authoring receipt and the bound cleanup intent. The review identity is the
  digest of that state, and the apply recomputes the observations under the
  lock before it changes anything.
- The permitted direction comes from the validated receipt, not from the
  recorded phase. A receipt that matches the reviewed publication field by
  field and carries the derived receipt identity proves the commit, so the
  transaction may only be completed. A publication without a receipt never
  committed, so it may be rolled back.
- A transaction before its commit may be rolled back: the published target is
  removed and the reviewed source is restored from the retained payload. The
  rollback verifies the retained payload, the current observations and the
  ownership of both scopes before it removes anything. A live installation
  that owns or exposes the published target or the reviewed source refuses
  the recovery. The rollback restores the reviewed source over the published
  content, so an entry outside the reviewed manifest is never removed. Only
  an entry that the reviewed publication evidence names and that still
  carries the reviewed bytes is removed.
- A committed transaction may only be completed: the published target is
  verified and the transaction is recorded as completed. The receipt is
  never recreated: a journal that claims a commit without its receipt, or a
  receipt that does not match the reviewed publication, is inconsistent
  evidence and the recovery is refused.
- `authoring cleanup` removes the retained private payload of a terminal
  transaction. It keeps the evidence document as the audit record and it
  forfeits the payload based restore of the source. The cleanup has its own
  review identity: a cleanup approval never authorizes a recovery. The
  review discloses the forfeiture, the cleanup writes a bound cleanup intent
  before the deletion and it refuses a payload that carries an unexpected or
  changed member. An unfinished transaction is never cleaned up, and a
  repeated cleanup is refused.
- The cleanup status is truthful: `available` for a payload without an
  intent, `interrupted` for an authorized deletion that did not finish,
  `partial` for a payload that a recorded deletion reduced, `cleaned` for a
  payload that a bound intent removed, `unavailable` for a transaction
  without a payload and `unresolved` for a payload that is missing without a
  recorded cleanup.
- No recovery path deletes an unfinished transaction, an editing draft or a
  user input file. The drafts of the editor and the transactions of the
  native publication are separate authorities.

## The pending authoring guard

- A pending ordinary authoring transaction reserves its published location,
  its reviewed source and its visible native name. The existing mutators of
  the lifecycle check that reservation before they write, so a second
  publication never replaces pending evidence.
- The exclusion of the recovery is granted to one exact evidence document:
  a transaction of another scope that happens to carry the same identity is
  never exempt.
- An ordinary author-only publication runs under the coordination lock of
  its scope and refuses a location that a pending authoring transaction
  reserves. The retained payload of a plan is never overwritten by a retry.

## Refusals

| Refusal | Status |
| --- | --- |
| The transaction does not exist | 4 |
| The review identity is stale | 4 |
| The explicit approval is missing | 4 |
| The recovery direction is not the permitted one | 4 |
| The transaction is terminal | 4 |
| An unfinished transaction is cleaned up | 4 |
| A repeated cleanup of a removed payload | 4 |
| The transaction changed since the review | 6 |
| The observed state changed since the review | 6 |
| The published target changed | 6 |
| The source changed since the publication | 6 |
| The location is owned by an installation | 6 |
| The publication committed its receipt | 6 |
| The receipt does not match the reviewed publication | 6 |
| The journal claims a commit without its receipt | 6 |
| The transaction belongs to another authority context | 6 |
| The transaction belongs to another home or user state root | 6 |
| The required scope authority is unavailable | 6 |
| The recorded context bound no home or user state root | 6 |
| The retained payload is missing or changed | 6 |
| The retained payload is not a readable copy | 6 |
| A pending authoring transaction blocks the mutation | 6 |

## Evidence and limits

The focused suite of the recovery service covers the transaction recording
of an ordinary publication, the inventory, the read-only inspection, the
rollback of an interrupted publication, the restoration of the reviewed
source, the refusal of a stale review identity, a missing approval, a
changed target, a committed receipt, a terminal replay, the cleanup of a
terminal transaction, the refusal of an unfinished and of a repeated
cleanup, the orphan payload in the inventory, the reconstruction of the
service, the visibility of a corrupt document, the validated receipt
direction, the inconsistent journal, the pending authoring guard, the
copied evidence, the adopted location, the interrupted cleanup and the
interrupted restore.

The platform evidence of this slice is a local run on Microsoft Windows 11
Home 10.0.26200 with the Dart SDK 3.13.2 on `windows_x64`. The local run
published an ordinary output, interrupted it, inspected it, rolled it back
and confirmed the restored source, the retained receipt and the empty
private staging on the real local filesystem. `dart analyze` reports no
findings.

The checks are static ownership and recovery evidence. No Claude, Codex or Pi
runtime was exercised, no native harness activation was proven and the
completed inverse restore of a conversion remains a separate slice.

## Open questions

- The recovery of an ordinary publication restores the reviewed source from
  the retained payload. A reviewed inverse restore of a *completed*
  conversion is a separate dependent slice and is not available here.
- A restore copies the retained payload member by member. A copy that is
  interrupted may leave a truncated member behind. The recovery refuses a
  changed survivor, because the transaction cannot prove that the truncated
  bytes are its own, and it keeps the retained payload for a manual
  resolution. An atomic per-file restore is a possible later improvement.
- The pending authoring transaction reserves the paths of its target and its
  source and the visible native name of its native root while it is not
  terminal.
