> **Historical design record** — this document may not describe
> current behavior. See [README.md](../README.md) and
> [docs/guides/](guides/) for current guidance.

# Safe editor interaction

Delivery: [#84](https://github.com/louiss0/agent_resource/issues/84).
Authority: the confirmed [platform editor research](https://github.com/louiss0/agent_resource/issues/75)
and the confirmed [editor completion, draft safety and consent
decisions](https://github.com/louiss0/agent_resource/issues/78).

## Scope and boundary

This slice is a shared module only. It adds the editor interaction that the
guided authoring frontends will use, and it changes nothing else:

- `lib/src/authoring/editor_interaction.dart`: the editor command grammar,
  the selection precedence, the completion contract and the value types of
  the interaction.
- `lib/src/authoring/editor_process.dart`: the resolution of the editor
  program and the runner that launches a program with an argument vector.
- `lib/src/authoring/editor_platform.dart`: the launcher of the
  platform-default text editor.
- `lib/src/services/editor_interaction_service.dart`: `EditorInteractionService`,
  the editing session over the existing protected
  [`InstructionDraftService`](protected-instruction-drafts.md).

There is **no** new command, no native resource publication and no
publication approval in this slice. The module is the seam that
[#85](https://github.com/louiss0/agent_resource/issues/85) will call.

The module is deliberately small and deep: a frontend supplies a protected
draft and receives the edited draft. Everything else — the selection of the
editor, the grammar of the configuration, the safety of the launch, the
evidence of the completion and the recovery after a failure — is inside the
module.

Generator provenance: `lib/src/authoring/editor_interaction.dart`,
`lib/src/authoring/editor_process.dart` and
`lib/src/authoring/editor_platform.dart` were scaffolded with
`mamba class --kind plain --directory lib/src/authoring --test` and edited.
`lib/src/services/editor_interaction_service.dart` was scaffolded with
`mamba service` directly in `lib/src/services/`, and its scaffold placeholders
were replaced with real tests. No skipped placeholder remains.

## The public seam

```dart
final service = EditorInteractionService(
  drafts: instructionDrafts,
  processRunner: ...,      // the launch of a program with an argument vector
  platformLauncher: ...,   // the platform-default text editor
  environment: ...,        // the terminal and display capabilities
  acknowledge: ...,        // the saved-and-finished confirmation
  recover: ...,            // the question after a failed launch
  executables: ...,        // the resolution of the editor program
);

final EditorEditOutcome outcome = await service.edit(
  options,
  draftId,
  editorChoice: 'code --wait',   // optional explicit choice
);
```

The outcome is one of:

| Outcome | Meaning |
| --- | --- |
| `EditorEditCompleted` | The editing finished and the effective instructions were read back. |
| `EditorEditNotFinished` | The operator did not confirm that the editing finished. The draft is retained. |
| `EditorEditBodyFile` | The operator continues with the protected working copy as a body file. |
| `EditorEditCancelled` | The operator cancelled. The draft is retained. |

An outcome never carries a publication approval. The edited draft is a
proposal: the frontend reviews it and confirms the publication on its own.

## Editor selection

The precedence is a contract of this application:

1. the explicit choice of the caller,
2. the configured `VISUAL` variable,
3. the configured `EDITOR` variable,
4. the platform-default text editor capability.

The variables are read from the captured configuration
(`LifecycleOptions.environment`), never from a resource, a pack or a draft.
A configuration that cannot be used is an error: it never falls through to
the next source. A broken configuration is not a missing configuration, so the
session offers the recovery choices instead of selecting another program on
its own.

The platform default is a *text editor* capability. A desktop file
association that is not an editing action is not an editor capability, and
the module never opens a file with an arbitrary program.

## The command grammar

An editor configuration is an executable and an argument vector.

- The arguments are separated by whitespace.
- A double-quoted segment is one literal argument that may carry whitespace.
  Inside a quoted segment, `\"` is a double quote and `\\` is a backslash.
- Every other character is literal data.
- The characters `| & ; < > $ \` ( )` outside a quoted segment are refused:
  they carry a shell expression.
- A shell interpreter (`cmd`, `powershell`, `sh`, `bash`, …) is refused as
  the executable, so the grammar can never be handed to one.
- A multi-line value is refused.

The draft path is passed as data: it is appended as one argument and is
never concatenated into another argument. The instruction body is never an
argument and is never logged.

### Wrappers, batch launchers and the resolved program

Dart documents that a Windows `.bat` or `.cmd` file may be interpreted
through a command processor even when the process is started without one.
The module therefore refuses a batch launcher:

- a batch launcher named by the configuration is refused;
- a batch launcher that is only found through the search path is refused,
  including the extension completion of the environment (`PATHEXT`);
- the runner refuses a batch launcher again at the launch boundary, so the
  refusal does not depend on the caller having checked the program.

The extension completion is limited to the binary executables of the
environment. Only `.COM` and `.EXE` are completed for a bare name, so a
search-path lookup can never silently start a script host or a batch
launcher. A batch launcher spelled explicitly is still refused by name.

This is a consequence for the documented wait on Windows. The Visual Studio
Code installer puts the `code` command on the search path as a `code.cmd`
batch launcher, so `code --wait` resolves to a refused program and cannot be
used by its bare name. The real executable is reached by its absolute path
(`Code.exe`) or by an explicit configuration that names it. The documented wait
of the editor is recognized for that binary spelling as well, so the program
that this module may launch is also the program whose completion contract it
knows. This limitation
is stated here, not hidden: the documented wait remains available for an
editor whose Windows entry is a binary executable.

The program that is checked is the program that runs. The resolution returns
the absolute path of the program, following the search order of the
operating system (the working directory of the session first on Windows,
then the directories of the search path), and the launch uses that path with
the captured environment and the captured working directory. A different
program can never be started behind the checked one.

The search order is the one of the platform. A posix system does not search
the working directory of the session, so a program beside the project can
never shadow the search path there. A posix storage distinguishes the case
of a name, so `code` and `Code` are two programs. A linked program is a
program: the link is followed to decide whether the candidate is a file.

A wrapper script is a program like any other: the module launches it with
the same argument boundaries, but it cannot prove what the wrapper does with
its arguments. A wrapper that is a batch launcher is refused.

## Completion evidence

Opening a file, launching an editor, finishing an editing session and saving
the intended content are different events. The module accepts three
different kinds of evidence and never confuses them:

| Evidence | When it is used |
| --- | --- |
| A documented wait | `code --wait` and `emacsclient` (without `-n` or `--no-wait`) document that they wait for the editing to finish. The session waits for that exit. The contract follows the name of the program, not the spelling of its path: the Windows binary of Visual Studio Code (`Code.exe`) carries the same documented wait as the `code` command. |
| A terminal editor exit | A known terminal editor inherits the terminal of the session and is waited for. Its exit is **not** acceptance: the operator may have discarded the changes. |
| A saved-and-finished acknowledgement | Every other editor, and the platform default, needs the explicit confirmation that the file was saved and the editing was finished. |

A graphical or unknown program is never awaited: it may run until the
operator closes it, and the session asks the operator instead.

### The lifecycle of the launched program

The launch mode follows the completion evidence:

| Program | Mode | The parent process |
| --- | --- | --- |
| A terminal editor | The streams of the operator are inherited. | The exit is awaited when the session waits for the editor; the terminal stays occupied until then. |
| An editor with a documented wait | Piped streams that are drained and discarded. | The documented exit is awaited. |
| Any other program | Detached, with no communication channel. | The session never waits: the parent process may end while the program runs on. |

The detached mode matters: a program without a documented completion contract
may run for a long time, and a parent that kept its streams open would stay
alive with it. A launch failure is still reported immediately, because the
launch itself fails before the program runs.

The acknowledgement permits the reading and the validation of the draft. It
is never a publication approval. Unchanged text is not a cancellation: the
edited draft is returned with the unchanged instructions.

## Recovery after a failure

A missing editor capability, an unusable configuration and a failed launch
are answered the same way. The operator chooses:

- **retry**: the same editor is launched again;
- **another editor**: another configuration is launched;
- **body file**: the session hands the protected working copy over as the
  body file of a later authoring run;
- **cancel**: the session stops and the draft is retained.

The session never chooses a program on its own, never publishes and never
removes the draft. Every attempt is bounded, so a recovery question cannot
loop forever. The draft is confirmed again before every launch and before a
body-file hand-over: a substituted working copy, a replaced snapshot or an
unconfirmed container refuses the launch.

## Dry-run and unattended sessions

A dry-run session and an unattended session are refused before any storage
is written and before any program is launched. They never ask a question,
never wait and never leave a working copy behind. A body file is the
alternative in an unattended run.

## Platform adapters

| Platform | The default text editor | Evidence |
| --- | --- | --- |
| Windows | The shell `edit` verb (`ShellExecuteW`). There is no fallback to the `open` verb and no fallback to another program. | Microsoft documents the verbs and the limits of the shell launch. The path of the launch is not exercised in the tests: it would open a program on the machine of the operator. |
| macOS | `/usr/bin/open -t`. The launcher does not wait for the editor. | Apple documents `open -t` for the default text editor. The `-W` semantics were only located in a reproduced manual, so the module does not claim them. |
| Linux | None. A desktop association is not an editor capability, so the launch fails clearly and the recovery choices are offered. | The freedesktop documentation describes preferred applications, not editors and not a document-completion protocol. |

The display capability is an assumption on the platforms whose default text
editor is a graphical program. It is not a verification of a desktop
session: a session without a desktop fails the launch clearly.

## Privacy

- The editable working copy is created inside the protected draft storage.
  The container is protected before the copy exists, and the protection is
  confirmed before every launch.
- The instruction body is never an argument of the editor, never in a prompt
  and never in a message. The messages carry paths and reasons only.
- The output of the launcher is drained and discarded. It is never reported.
- The original input file of the operator is never a cleanup target. The
  module removes nothing.
- The protection of the container cannot promise that an arbitrary editor
  makes no backup, swap, history, extension-managed or cloud copy. That
  limitation is stated, not hidden.

## Evidence and limits

Focused runs on the final tree:

- `dart analyze lib test`: clean.
- `dart format --output=none --set-exit-if-changed lib test`: clean.
- `dart test test/src/authoring/editor_interaction_test.dart
  test/src/authoring/editor_process_test.dart
  test/src/authoring/editor_platform_test.dart
  test/src/services/editor_interaction_service_test.dart
  test/src/services/editor_interaction_transport_test.dart`: 59 passing, one
  skipped (the platform launch of a default editor is not exercised).
- `dart test test/authoring_draft_process_test.dart
  test/authoring_draft_test.dart test/authoring_test.dart
  test/src/authoring/authoring_inputs_test.dart
  test/src/services/instruction_draft_service_test.dart`: 103 passing.

What the evidence does and does not show:

- A real program launch was exercised: a controlled helper process received
  the editable working copy of a real protected draft as **one** argument,
  although its path carries spaces. The edited text was read back through
  the protected draft storage, whose Windows access control list was
  established by the default privacy guard.
- The resolution and the launch were exercised with a supplied search path
  that differs from the search path of the host: the launched program was
  the resolved absolute path of the supplied search path, with the captured
  environment and the captured working directory.
- The lifecycle was exercised with a controlled long-lived helper program: a
  parent that launched it without a documented wait ended at once instead of
  waiting for the helper. The proof does not depend on a duration: the helper
  runs on for two minutes and marks its own end, so the parent that exited
  while the helper was still running did not wait for it. The duration of the
  launch is measured inside the parent, so that the measurement covers the
  launch and not the start-up of the parent. The helper was stopped by the
  test, so the test leaves no program behind.
- No real editor was launched, and no resource body was executed.
- The runs happened on Windows. The posix branches of the resolution (no
  search of the working directory, the case of a name, a linked program) are
  covered by tests that assert the posix expectation, but they were not
  executed on a posix host here.
- No macOS or Linux runtime behaviour was verified. The macOS launcher, the
  Windows shell launch and the desktop-session assumption are documentary.
- The harness was not exercised: nothing here proves that a Harness loads
  or activates an authored resource.
- This slice registers no CLI command: the module is the seam that
  [#85](https://github.com/louiss0/agent_resource/issues/85) calls, so the
  registered parsing and the help of the editor flow are proved there and not
  here. The proof of this slice is the public service seam and the injected
  process, terminal and platform adapters.

## Sources

The primary sources are collected in the research asset
`docs/research/platform-editor-launch.md` of the research worktree. The
decisive ones for this slice:

- Microsoft Learn, *ShellExecuteA function* (the `open` and `edit` verbs):
  https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shellexecutea
- Microsoft Learn, *SHELLEXECUTEINFOA* (process handles, DDE, no universal
  document-completion protocol):
  https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ns-shellapi-shellexecuteinfoa
- Apple, *Use command-line text editors in Terminal on Mac* (`open -t`):
  https://support.apple.com/guide/terminal/apdb02f1133-25af-4c65-8976-159609f99817/mac
- Visual Studio Code, *Command Line Interface* (`--wait`):
  https://code.visualstudio.com/docs/configure/command-line
- GNU Emacs Manual, *Invoking emacsclient* and *emacsclient Options*:
  https://www.gnu.org/software/emacs/manual/html_node/emacs/Invoking-emacsclient.html
  and https://www.gnu.org/software/emacs/manual/html_node/emacs/emacsclient-Options.html
- freedesktop.org, *xdg-open* and *xdg-mime* (preferred applications, not
  editors):
  https://portland.freedesktop.org/doc/xdg-open.html and
  https://portland.freedesktop.org/doc/xdg-mime.html
- Dart API, *Process.start* (argument vectors, the Windows batch warning,
  the process modes) and *ProcessStartMode*:
  https://api.dart.dev/dart-io/Process/start.html and
  https://api.dart.dev/dart-io/ProcessStartMode-class.html
