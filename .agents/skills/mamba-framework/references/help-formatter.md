# Help formatter inspection

Use this reference to inspect an application's help renderer before changing
it, or to review a proposed replacement. Establish the existing behavior and
its design intent first; this is an inspection workflow, not an implementation
template.

## Philosophy: replace presentation, preserve meaning

An application-owned formatter replaces the default help formatter's
presentation mechanics. Its layout, usage notation, section organization,
spacing, and styling should express the application's own design. Adding a
brand heading around unchanged default output does not replace those mechanics.

Preserve the meaning of the registered CLI, not the default renderer's exact
symbols, palette, or layout. A reader must still distinguish required from
optional input, repeated from single values, all-or-nothing pairs from
independently selectable members, and exclusive alternatives from both.
Different notation is appropriate when those distinctions remain clear.

Apply the help-design philosophy consistently:

- **Theme colors express product identity.** Use them for presentation roles
  such as headings, borders, and emphasis that fits the application's theme.
- **Semantic colors express input roles.** Required, optional, paired, and
  alternative inputs must retain consistent meanings throughout the output.
  A theme accent is not a reason to collapse these distinctions into one color.
- **Meaning survives without color.** Notation, labels, and grouping must carry
  the same information when ANSI styling is unavailable. Color reinforces
  meaning rather than being its only carrier.
- **The selected registry defines the CLI.** Presentation may change; accepted
  spellings, input types, cardinality, defaults, and relationships do not change
  merely because the help layout does.

## 1. Locate the active rendering boundary

Inspect the relevant application entry point and its `Executor` configuration.
Identify its `helpFormatter`, or establish that it uses `MambaHelpFormatter`
by default. Follow the installed formatter's definition rather than assuming a
class with a help-related name is actually wired in. For multiple executables,
trace the one affected by the task.

Record:

- which formatter instance the executor uses;
- its `format(CommandRegistry)` and
  `formatLongDescription(StringBuffer, String)` behavior;
- any rendering helpers it overrides, inherits, or delegates to; and
- the existing help tests and the application's documented presentation intent.

`format` receives the selected registry and returns the complete help string.
Mamba does not append omitted sections or input declarations to a custom
formatter's result. `formatLongDescription` is part of the formatter contract;
inspect how the custom `format` actually uses it.

`HelpFormatter` is the customization boundary. `MambaHelpFormatter` is the final
default implementation, not a superclass for application formatters. Relevant
imports are `package:mamba/mamba.dart` for the formatter API,
`package:mamba/registry.dart` when naming `CommandRegistry`, and
`package:mamba/parser.dart` for intrinsic control metadata.

## 2. Trace which mechanics still come from the default

Inspect the installed Mamba version's `HelpFormatter` and `MambaHelpFormatter`
alongside the application's formatter. In an application repository these are
dependency sources, not necessarily files in the application's own `lib/`.
This is source inspection, not a reason to import private implementation APIs.

Compare the application's intended design with the rendering path it actually
uses:

| Inspect | Determine |
| --- | --- |
| `format` | Who owns layout, section order, spacing, usage notation, and command-path rendering? |
| `formatLongDescription` | Does long help follow the same design, or retain the default separators and styling? |
| `formatIntoRequiredString` / `formatIntoOptionalString` | Are requiredness notation and styling application-owned or inherited unchanged? |
| `formatIntoPairString`, `formatIntoOrString`, `formatIntoSelectionString` | Do relationship symbols and colors distinguish the declaration's actual semantics? |
| `formatIntoSectionTitle` / `formatIntoEntryDescription` | Do headings and descriptions follow the application's theme and information hierarchy? |
| Styled fragment types and `MambaColors` | Are default delimiters, palette choices, or ANSI assumptions still embedded in output? |
| Delegation to `MambaHelpFormatter` | Is the renderer merely decorating default output instead of replacing its mechanics? |

Extending `HelpFormatter` alone does not establish an independent presentation:
its concrete helpers already contain default styling and notation. Replace or
override the mechanics that conflict with the intended design; retaining a
helper is a deliberate compatibility with that design, not an automatic
requirement. The styled fragment types also encode behavior: for example,
`RequiredString` and `OptionalString` supply delimiters, and `FormattedString`
requires ANSI SGR content. Inspect these dependencies before assuming that
recoloring one method or supplying plain text changes the whole renderer.

Report the specific inherited/delegated mechanics and the visible mismatch.
Use the default implementation as a behavioral comparison, not a template that
the replacement must reproduce.

## 3. Inspect semantic coverage against declarations

Trace rendered information back to the selected registry. Inspect effective
inputs, not just locally declared lists; root and propagated inputs can apply
to a nested command. Avoid changing declarations or parser behavior to make a
presentation-only change easier.

Check every family used by the application:

- **Identity and navigation:** the selected canonical path, descriptions,
  command names/aliases, child commands, and relevant default-command guidance.
- **Positionals and trailing arguments:** registration order, requiredness,
  bounded repetition, choices, and the separate `--` channel. A maximum `max`
  is not an exact count; trailing arguments do not satisfy positionals.
- **Flags:** valueless boolean/count behavior, short spellings, and generated
  negations where supported. Prepared flags appear only when registered.
- **Options:** value-taking syntax, required/optional/defaulted forms,
  repetition, choices, ranges, and uniqueness where relevant. File/folder/URL
  declarations are value inputs, not switches.
- **Relationships:** paired all-or-nothing groups, independently selected
  members, at-least-one/exactly-one requirements, and explicit-occurrence
  conflicts. Default values are not explicit occurrences.
- **Accessors:** dotted leaf paths, nested visibility, and independently
  required/optional/defaulted leaves.
- **Visibility and safe display:** hidden declarations stay out of help while
  remaining parseable; URL defaults remain redacted rather than exposing
  `.original` or `.uri` secrets. File suffix hints are completion metadata,
  not an advertised restriction on manually supplied extensions.
- **Intrinsic controls:** help/version come from `Parser.controlFlags`, not the
  registry's ordinary declared flags. A replacement must account for them.

Choose the amount and placement of detail for readability, while keeping the
application's supported invocation shapes discoverable and truthful. Empty
sections should not obscure the sections that contain useful information.

## 4. Inspect rendered output at each scope

Capture actual help through the application's configured executor, using
`fake()` for structured assertions without Mamba's process delivery. Inspect
what a reader sees as well as what assertions happen to match. Locate cases
under the owning command-tree groups as described in [Testing](testing.md).

Use the application's available declarations to exercise:

- explicit root help and root fallback help when there is no root default;
- group and leaf help, including alias invocation and scopes with defaults;
- inherited inputs, hidden inputs, relationships, accessors, repetition, and
  long descriptions where present;
- scopes without optional sections, to reveal empty headings or excess spacing;
- styled output and output with color disabled, including helper behavior that
  assumes ANSI-styled fragments; and
- version/help controls without supplying the command's ordinary required input.

Help must describe the explicitly requested scope instead of silently showing
its default child's help. Explicit help bypasses command behavior and hooks;
formatting should not introduce domain effects or depend on those hooks having
initialized application state.

Distinguish two comparisons: compare old and new help to catch lost information,
then compare the new output to the intended design to catch default mechanics
that survived accidentally. A snapshot of the default output is not the design
specification for its replacement.

## Inspection result

An inspection is complete when it identifies the active formatter and its
rendering dependencies, checks every declaration family the application uses,
and supplies root/group/leaf output evidence for the philosophy above. Report
any gaps as concrete findings: the affected scope, observed output, lost or
misrepresented meaning, and the default mechanic or custom decision responsible.
If a change is requested, use those findings to bound it rather than starting
with a generic formatter implementation.
