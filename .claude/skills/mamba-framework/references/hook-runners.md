# Hook runners

Use hook runners for lifecycle behavior that surrounds command execution.
Hooks receive the selected invocation's `ValueOf` function, and may complete
synchronously or return a `Future`.

Import `package:mamba/mamba.dart` for hook mixins, context types, stdin, and
`MambaException`. Add `dart:async` when naming `FutureOr`, and
`package:mamba/executor.dart` for result metadata.

## Contents

- [Choose a hook runner](#choose-a-hook-runner)
- [Wrap one command](#wrap-one-command)
- [Wrap group descendants](#wrap-group-descendants)
- [Understand execution order](#understand-execution-order)
- [Read input and share state](#read-input-and-share-state)
- [Interpret hook failures](#interpret-hook-failures)

## Choose a hook runner

| Mixin | Apply to | Scope | Context |
| --- | --- | --- | --- |
| `HookRunner` | `Command` | That command's `run` call | Read-only `MambaReadContext` |
| `PersistentHookRunner` | `GroupCommand` | Any selected descendant | Mutable `MambaContext` in pre-hooks; read-only `MambaReadContext` in post-hooks |

Use `HookRunner` for behavior owned by one command, such as validation,
instrumentation, or success-only post-processing. Use `PersistentHookRunner` for a
group concern that wraps every descendant, such as authentication, tracing,
or shared state setup.

## Wrap one command

Mix `HookRunner` into a command and implement `preRun`. Override `postRun` only
when success-only follow-up behavior is required:

```dart
final class DeployCommand extends Command with HookRunner {
  @override
  String get name => 'deploy';

  @override
  String get shortDescription => 'Deploy the application.';

  @override
  FutureOr<void> preRun(
    ValueOf valueOf,
    MambaReadContext context,
    ProcessedStandardInput? input,
  ) {}

  @override
  FutureOr<void> postRun(
    ValueOf valueOf,
    MambaReadContext context,
  ) {}

  @override
  String run(ValueOf valueOf, List<String> args) => 'Deployed.';
}
```

`preRun` is the only hook that receives processed standard input. A successful
`preRun` and `run` must both succeed for `postRun` to run. A failure in any
pre-hook or `run` skips every ordinary and persistent post-hook. Pass
`standardInput` to `Executor.fake()` to supply input in a test.

## Wrap group descendants

Mix `PersistentHookRunner` into a group to surround execution anywhere below
that group:

```dart
final class WorkspaceCommand extends GroupCommand
    with PersistentHookRunner {
  new() : super([DeployCommand()]);

  @override
  String get name => 'workspace';

  @override
  String get shortDescription => 'Manage the workspace.';

  @override
  FutureOr<void> prePersistentRun(
    ValueOf valueOf,
    MambaContext context,
  ) {}

  @override
  FutureOr<void> postPersistentRun(
    ValueOf valueOf,
    MambaReadContext context,
  ) {}
}
```

Persistent pre-hooks run sequentially from the outermost selected group inward.
After all pre-hooks, `run`, and ordinary `postRun` succeed, persistent post-hooks
run concurrently using `Future.wait` with `eagerError: true`. A failed pre-hook prevents deeper hooks
and the command from running and skips every post-hook, including those of
initialized outer groups. An ordinary `postRun` failure skips the concurrent
persistent post-hook batch.

## Understand execution order

For a nested command with both mixins, Mamba executes:

1. Persistent pre-hooks, outermost to innermost.
2. The selected command's `preRun`.
3. The selected command's `run`.
4. The selected command's `postRun` after all pre-hooks and `run` succeed.
5. A concurrent batch of persistent post-hooks after ordinary `postRun` succeeds.

Setup and ordinary command phases are sequential. Persistent post-hooks share
a read-only context view, but their asynchronous work can interleave after an
`await`; they must not rely on other post-hooks finishing first. Success waits
for every hook, but failure returns immediately without cancelling siblings.
Post-hooks are success-path behavior, not failure cleanup; use
application-owned `try`/`finally` for mandatory cleanup.

## Read input and share state

Use `valueOf` with the same retained declaration instances registered
on the command. In `preRun`, inspect `ProcessedStandardInput.bytes`, `text`,
`utf8Text`, or `json`; the value is `null` when no input is available. These are
views of the buffered input, not multiple reads from the process stream.
Only the selected command's ordinary pre-hook receives stdin; persistent
pre-hooks do not. Invalid UTF-8/JSON decoding throws in that pre-hook phase.
`json` may be a map, list, scalar, or null; validate its shape before using it.
The supplied bytes are retained without copying; do not mutate them while in use.

Ordinary hooks and persistent post-hooks receive `MambaReadContext`, so they
can read but not mutate executor state. Only persistent pre-hooks receive
`MambaContext` and can store scalar state under retained `MambaContextKey<T>`
instances. The executor supplies the same read-only view to command hooks and
the persistent post-hook batch. The context belongs to the executor and
survives when that executor instance is reused. A read-only view is not an
invocation snapshot: overlapping invocations can observe shared context writes.
Use fresh contexts/configurations when those values must be isolated.

Store values with the matching scalar wrapper; `get` returns the unwrapped
primitive or null when unset. Writers and readers must share the same key
instance. Use separately allocated non-const keys for independent slots of the
same type; identical const keys can be canonicalized to the same instance:

```dart
final workspaceKey = MambaContextKey<String>();
final context = MambaContext()
  ..set(workspaceKey, const MambaContextString('development'));
final String? workspace = MambaReadContext(context).get(workspaceKey);
```

Use `MambaContextBool`, `MambaContextInt`, or `MambaContextDouble` for the other
supported scalar types. Context cannot hold arbitrary domain services; inject
those through application constructors instead. See the
[executor ownership model](../SKILL.md#own-dependencies-and-shared-state).

## Interpret hook failures

Mamba records hook exceptions as `MambaExecutionException` values with the hook's
execution phase and command path. Persistent hook errors identify the owning
group; ordinary hook errors identify the selected command. The result exposes
one required `error`. Sequential failures skip later phases. Concurrent
persistent post-hook failures do not cancel already-started siblings. The first
observed exception returns immediately with its metadata and exit code; a first
observed Dart `Error` escapes immediately instead. Siblings can still produce
effects after execution returns. Later failures, including `Error`s, are
consumed by `Future.wait` and do not replace the first failure.
