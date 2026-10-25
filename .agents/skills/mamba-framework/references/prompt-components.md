# Prompt components

## Components created by Mamba

Mamba creates four kinds of reusable component under
`lib/components/<name>.dart`. Each is a plain class that owns one interaction,
not a registered command, an argv declaration, or a callable function. Its
constructor accepts a `label` with a generated default. Await its async
`render()` method and handle its result in application code; answers do not
become `ValueOf` inputs. Scaffolding command recipes belong in the application's
`AGENTS.md`.

### Prompt

`Future<String?> render()` asks for text using `ClixInput`. Input is trimmed;
a blank or whitespace-only answer returns null as cancellation. The generated
wrapper has no default or validator. Add these deliberately if the application
needs them, and decide how a default affects cancellation.

The wrapper's null-on-blank behavior differs from direct `ClixInput`, which
returns an empty string when there is no default. Do not assume the two
contracts are interchangeable.

### Selector

The constructor requires `List<String> options` in addition to its optional
label. `Future<String?> render()` uses Mamba's line-based `ClixSelector`:

- A displayed number selects that entry and returns its string value.
- Text filters the original choices case-insensitively, then the user chooses
  a number from the displayed results.
- A blank answer or an empty options list returns null.

This is a numbered line-input interaction, not a native raw-key menu. Its result
is a selected value, not a list index.

### Picker

`Future<String?> render()` uses Mamba's line-based `ClixDirectoryPicker`.
It starts at the process's current directory and offers the current directory,
its parent, and sorted child directories. Selecting the current directory
returns its absolute path; a blank answer returns null.

It chooses directories, not files. The generated wrapper exposes only its
label; use or adapt the underlying adapter when a different start directory
is needed.

### Indicator

`Future<T> render<T>(Future<T> Function() work)` runs work behind a spinner
and returns the work's result. Its
`spinner({SpinnerType type = SpinnerType.dots})` method constructs and starts
the spinner. Mamba's `whileRunning` extension completes it on success, reports
failure and rethrows on failure, and always stops it.

`SpinnerType.line` uses ASCII frames. Calling `spinner()` directly starts an
indicator without the wrapper's work/cleanup lifecycle; the caller then owns
its completion and cleanup.

## Underlying toolkit and documentation

These components use **Clix**, Mamba's prompting and progress toolkit. Read the
[Clix API documentation](https://pub.dev/documentation/clix/latest/clix/) for
individual component contracts and the
[Clix package guide](https://pub.dev/packages/clix) for its broader feature set.
The behavior notes below are checked against Clix 1.2.0; its
[versioned API documentation](https://pub.dev/documentation/clix/1.2.0/clix/)
helps distinguish that behavior from newer examples. Check the consuming
application's resolved version before adopting an upstream signature or behavior.

Mamba intentionally re-exports Clix from `package:mamba/mamba.dart`; these
exports need no separate toolkit dependency or import. Clix's text prompt is
named `ClixInput` there, preserving `Input` for Mamba's typed argv declarations.
Other prompt types retain their toolkit names. The toolkit's parsing/config
utilities are not Mamba's command parser or application configuration loader.

## Additional prompt choices

Use the generated components when their contracts fit. For needs beyond those
wrappers, inspect the installed toolkit API before choosing another prompt:

| Component | Purpose and result |
| --- | --- |
| `ClixInput` | Text as `String`, with optional default and validator. A validator returns null to accept or an error message to display before retrying. Enter uses the default, or returns an empty string without one. |
| `Confirm` | Yes/no as `bool`. In Clix 1.2, trimmed case-insensitive `y`/`yes` mean yes; Enter uses a supplied default; other answers mean no rather than retrying. Prefer an explicit false default for potentially destructive actions. |
| `Number` / `Decimal` | Typed numeric answers as `int` / `double`, with optional bounds and validation. These are interactive values, not registered Mamba numeric options. |
| `Select` / `MultiSelect` | Native raw-key menus returning a zero-based index / list of indices. Resolve those indices against the offered choices; unlike Mamba's selector, they do not return selected strings. |
| `Search` | Searchable choices returning an index. Inspect result-index mapping, dynamic-source behavior, and cancellation in the installed version; they do not share the generated selector's null-on-blank contract. |
| `Password` | Concealed input as `String`, with optional validation and confirmation. Treat the returned value as sensitive; concealment is not permission to log or include it in command output. |

Direct prompts use async `.interact([CliIO?, CliTheme?])`, not the generated
wrappers' `render()`. Native raw-key prompts are not drop-in substitutes for
line-based Mamba adapters: they have different terminal requirements, result
types, and cancellation behavior. In Clix 1.2, `Select`, `MultiSelect`,
`Password`, and parts of `Search` access process stdin directly, so passing a
`CliIO` alone does not isolate their terminal reads.

For progress beyond the generated indicator, Clix also exports `Progress` and
`MultiSpinner`. Inspect their update, completion, output, and cleanup contracts
rather than assuming they inherit Mamba's `whileRunning` guarantee.

## Interaction and automation boundaries

Generated wrappers use default console I/O; their `render()` methods do not
accept a `CliIO`. The underlying text/confirmation prompts and Mamba's line-based
adapters can accept explicit I/O through `.interact()` when adapted or used
directly. Preserve the generated wrapper's documented cancellation semantics
when changing its internals.

Prompting is application-owned behavior. Gate it explicitly for interactive
workflows, and keep scripts deterministic without prompts. A selected answer
or confirmation is not a substitute for argv validation or application business
rules. Keep prompt/progress output from contaminating machine-readable output.
Line-based interaction can still emit styled confirmations and ANSI sequences.

`Executor.fake()` neither answers prompts nor suppresses progress or other
component effects; see the [executor ownership boundary](../SKILL.md#own-dependencies-and-shared-state)
and [Testing](testing.md). Tests must control the application's prompt boundary;
providing `standardInput` to a fake executor only supplies buffered input to a
command pre-hook, not answers to terminal prompts.

Do not generalize Mamba's scaffolding setup EOF handling to arbitrary prompts:
Clix 1.2's default console I/O turns EOF into an empty string, which a component
may interpret as a default, cancellation, or retry. Applications that need a
distinct closed-input failure must handle that at their own I/O boundary.
