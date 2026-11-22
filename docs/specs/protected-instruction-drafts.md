> **Historical design record** — this document may not describe
> current behavior. See [README.md](../README.md) and
> [docs/guides/](guides/) for current guidance.

# Protected, resumable instruction drafts

Delivery: [#83](https://github.com/louiss0/agent_resource/issues/83).
Authority: confirmed [plain-text creation](https://github.com/louiss0/agent_resource/issues/73),
[native input](https://github.com/louiss0/agent_resource/issues/74),
[editor/draft safety](https://github.com/louiss0/agent_resource/issues/78), and
[author-only ownership](https://github.com/louiss0/agent_resource/issues/80) decisions.

## Module and boundary

`InstructionDraftService` owns retained instruction editing storage, not native
resource publication, installation ownership, or transaction recovery. It reuses
`AuthoringInputs`, `AuthoringPlanService`, and the existing lifecycle IO/private
storage seams. Protected drafts are not `AuthoringTransaction` recovery payloads.

The module provides prepare, list/find, inspect, read, explicit editable-copy
preparation, resume, discard, and verified-owned success-cleanup. Preparing a
draft is an explicit writing operation. Plans and dry-run never prepare a draft
or an editable copy, launch an editor, or publish a resource.

The public recovery commands are:

```text
authoring draft list [--scope project|user] [--format text|json]
authoring draft inspect <draft-id> [context options]
authoring draft resume <draft-id> [context options]
authoring draft discard <draft-id> [--dry-run]
authoring draft discard <draft-id> --apply --yes
```

Scope defaults to project. Context options are `--cwd`, `--project-root`,
`--home`, and `--state-dir`. Reports are metadata-only; there is no body-printing
flag. These recovery commands do not expose publication or the deferred guided
create/edit frontends. Draft preparation and editor interaction are separate
module operations for those frontends.

## Inputs and retained evidence

The selected body is a text file, explicitly selected stdin with a supplied
reader, or literal text. Existing input normalization refuses conflicting
selectors; unattended operation never implicitly waits for stdin. Multiline
instruction text, whitespace, and line endings are retained without trimming.
Literal inputs retain the usual shell-history/process-list privacy limitation.
The original input file is never a cleanup target.

Each opaque `drf_<32 hex>` identity selects one fixed directory under the
resolved state's `instruction-drafts` root. It contains:

- `draft.json`: bounded, versioned metadata with operation, native selectors,
  declared-field intent, origin, and a digest-bound snapshot description;
- `body`: the immutable prepared instruction snapshot;
- `working.txt`: an optional, explicitly created plain-text editor working copy.
  Its extension permits a later native text-edit adapter to request the OS's
  text-edit action; it is not a native resource kind/profile inference.

Metadata does not contain the instruction body, an old plan identity, or
publication approval. Source/output paths are anchored to the preparation
context, so a different resume working directory does not silently retarget a
relative request. Metadata is internal storage, not a public JSON operation
request format or native resource classification metadata.

The mutable working copy is intentionally distinct from the digest-bound
snapshot. An editor may save by replacing that file inside the protected
container. Changed working text becomes a fresh proposal, not implicit consent;
unchanged working text is not cancellation. Unexpected entries, links, path
escapes, corrupt metadata, and changed immutable snapshots are not permission
to delete arbitrary files.

## Privacy and failure

Storage protection is established and verified before instruction bytes are
written. Reads use a separate verification-only path: finding, inspecting, and
resuming do not repair permissions or create storage. Unknown filesystem privacy
capabilities fail closed; in-memory tests explicitly inject their verifier rather
than claiming OS confidentiality.

Container protection matters because editors can replace files. Protection of
this container does not guarantee that an editor makes no backup, swap, history,
extension-managed, or cloud copy. This module launches no editor at all.

Cancellation and failure do not expire drafts. Malformed or incomplete retained
entries remain unresolved in inventory rather than being silently deleted. A
resume that cannot verify its evidence refuses and retains it; this is not a
promise to automatically repair every torn draft. A damaged metadata document,
a changed ACL, or an unexpected editor swap/backup entry can also block automatic
discard. Inspect the reported retained directory and review its ownership and
contents manually; preserve any needed instructions/evidence before arranging
manual repair or removal. There is no force-discard or recursive catch-all
cleanup for unknown editor artifacts.

Discard previews by default. Only explicit `--apply --yes` requests removal of
the verified, narrowly owned draft entries. No original input or native resource
is deleted. Cleanup is not secure erasure.

`cleanupOwned` is a separate frontend seam for use **only after successful
publication**. It returns cleanup failure independently, so a caller must report
both the published output and any retained draft rather than erase successful
publication evidence or report that nothing was created. The draft module never
performs publication or infers its success.

## Fresh resume

Resume reads current instructions, reconstructs the saved native intent, and
runs the read-only planner against fresh source, destination, and ownership
observations. It returns a fresh reviewable plan, not an apply operation. Target
occupancy is included in plan identity as well as readiness, so a new occupant
invalidates the previously reviewed target observation. A ready resumed plan
still requires a separate current publication approval in the eventual frontend.

## Evidence and limits

Tests cover exact body selection, immutable snapshots, editor replacement saves,
restart/resume, fresh observations, refusal before sensitive writes, injected IO
faults, path/link/metadata substitution, narrow cleanup, and read-only dry-run.
Registered command tests verify help/parsing, no body disclosure, no publication,
explicit discard consent, and state/source-byte preservation. A real isolated CLI
process test prepares protected local storage, reconstructs the service in new
processes, and exercises read-only recovery and explicit discard.

The default Windows verifier accepts only the qualified current account,
SYSTEM, and Administrators. It depends on recognized `icacls` output; an
unrecognized/localized ACL representation fails closed. The Unix verifier checks
permission bits and owner identity using `id` and the GNU/BSD `stat` formats.
Dart's [FileStat API](https://api.dart.dev/dart-io/FileStat-class.html) does not
expose UID/GID. Apple's [primary stat manual source](https://github.com/apple-oss-distributions/file_cmds/blob/main/stat/stat.1)
documents `-f` formatting and the `%u`/`%g` owner fields. That is documentary
evidence, not a macOS runtime test.

Each read verifies the current container rather than caching its permission
proof across operations. Consequently, inventories can perform one platform
permission query per draft; this is a deliberate safety/cost tradeoff, not a
claim of constant-cost discovery. Only the current Windows account is cached.

Final verification:

- `dart format lib test` and `dart analyze`: clean.
- Core module suite: 63 passing tests; registered command and native-process
  tests cover the actual recovery surface, body-free projection, per-entry read
  failure, and the `.txt` editor working file.
- Full suite on the final tree: `dart test --concurrency=1 --timeout=3m` —
  **1,084 passed, four platform skips**.
- An earlier concurrency-2 run hit a timeout in the existing Agent inventory
  production-process test. That file passed in isolation (43 passed, one skip),
  and the subsequent serialized full run above passed. No unrelated test or
  timeout was weakened.
- Independent Standards and Spec reviews were completed. Concrete findings were
  repaired; the nonblocking permission-query cost and manual-recovery boundary
  are documented above. A mistaken macOS `stat` finding was withdrawn after
  checking Apple's primary manual source.

Local Windows ACL checks and controlled process tests do not verify a native
editor, another operating system, or Harness loading/activation.
