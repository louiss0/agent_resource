# Context template storage, editing, and injection across coding harnesses

## Problem Statement

A developer who drives Claude Code, Codex, and native Pi across one or more repositories repeatedly maintains the same reusable project or subdirectory instructions—coding conventions, architecture rules, testing guidelines, or domain vocabulary—by hand across different harness-specific **Context files** (`CLAUDE.md`, `.claude/CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, and `AGENTS.override.md`). Today, Agent Resource has no surface for storing named, reusable **Context templates** at user scope, creating an empty named template to populate later, editing stored templates safely through the protected **Instruction draft** and **Editor interaction** machinery, or injecting a stored template into target **Context files** at the project root (by default), a chosen project subfolder, or user-global scope. As a result, users copy and paste raw Markdown manually across repositories and subdirectories, risk accidentally double-appending when multiple harnesses share `AGENTS.md` in the same folder, or overwrite existing instructions without drift protection or recovery backups.

## Solution

Agent Resource introduces a singular `context` top-level CLI command group (`create`, `edit`, `list`, `inspect`, `delete`, and `inject`) that manages user-scoped, harness-neutral **Context templates** stored as plain UTF-8 Markdown files (`<userStateRoot>/context-templates/<name>.md`) and injects them into target **Context files** for Claude Code, Codex, and native Pi. Every **Context template** is created with a mandatory portable name (`^[a-z0-9][a-z0-9_-]{0,63}$`), either as an explicit 0-byte empty template (`--empty`) or populated through text flags (`--body-file`, `--body-text`, `--body-stdin`) or an interactive **Editor interaction** over a protected user-scope **Instruction draft**. Template creation, template editing, and target **Context file** injection all use Agent Resource's two-phase, digest-bound `--plan-id` / `--apply` review discipline integrated with user-scope `instruction-drafts`, `authoring-transactions`, `authoring-recovery`, and `authoring-receipts`. Injection defaults to the project root (`projectRoot`), supports choosing an existing subfolder within `projectRoot` via `--folder` or targeting user-global harness roots via `--scope user`, validates explicit native variants (`standard`, `local`, `override`, `dot-claude`), deduplicates shared target paths (such as `<targetDir>/AGENTS.md` when both Codex and native Pi are selected), and either creates missing **Context files**, appends with a normalized blank-line separator (`\n\n`), or overwrites when `--replace` is selected.

## User Stories

1. As a developer, I want to create a named **Context template** stored at user scope, so that I can reuse the same instructions across any project or folder on my machine.
2. As a developer, I want every **Context template** to require a portable name matching `^[a-z0-9][a-z0-9_-]{0,63}$`, so that template names map cleanly to regular `.md` files without path traversal, extension ambiguity, or OS-reserved device name hazards.
3. As a developer, I want to create an empty named **Context template** using `--empty`, so that I can reserve a named template as a 0-byte file without opening an editor and populate or inject it later.
4. As a developer, I want to create a named **Context template** interactively in my configured text editor (`--editor`, `VISUAL`, `EDITOR`, or platform default) over a protected **Instruction draft**, so that I can author multiline Markdown instructions comfortably.
5. As a developer, I want `context create` in interactive mode to prompt me for the template name when I omit `<name>` and `--name`, so that I am guided through template creation without memorizing flags.
6. As a developer, I want `context create` and `context edit` to reject an empty or whitespace-only body when `--empty` was not explicitly requested, so that an accidental blank save in my editor never creates an unintended blank template or wipes out an existing template.
7. As a developer, I want `context create` and `context edit` to support `--body-file`, `--body-text`, and `--body-stdin`, so that scripts and pipelines can plan and publish **Context templates** deterministically in unattended mode.
8. As a developer, I want `context create` to refuse an already-existing template name during planning and publication, so that creating a template never silently clobbers an existing **Context template**.
9. As a developer, I want `context edit` in interactive editor mode to seed a protected **Instruction draft** with the current UTF-8 bytes of the stored **Context template**, so that I edit my existing template text in place rather than starting from an empty buffer.
10. As a developer, I want `context edit` in interactive mode to present a numbered selector of existing **Context templates** when I omit `<name>` and `--name`, so that I can pick which template to edit quickly.
11. As a developer, I want `context create` and `context edit` to use two-phase `--plan-id` and `--apply` publication with source-digest verification, so that concurrent edits to a template file invalidate stale plans before any overwrite occurs.
12. As a developer, I want `context edit --apply` to preserve the previous bytes of the edited **Context template** in a protected **Authoring recovery copy**, so that prior template content is retained as evidence if a replacement needs to be audited or recovered.
13. As a developer, I want interrupted or cancelled `context create` and `context edit` editor sessions to retain their protected **Instruction draft** at user scope and report `draftId` and `draftPath`, so that I can inspect, resume, or discard the draft through `authoring draft`.
14. As a developer, I want `context list` to enumerate all stored **Context templates** in deterministic lexicographical order with `name`, `path`, `byteLength`, `isEmpty`, and `sha256`, so that I can see which templates exist and whether any are empty.
15. As a developer, I want `context inspect` to display both the metadata (`name`, `path`, `byteLength`, `isEmpty`, `sha256`) and the full UTF-8 Markdown `content` of a selected **Context template** without requiring `--show-instructions`, so that I can read a stored template immediately.
16. As a developer, I want `context delete` to remove a stored **Context template** after interactive confirmation (or `--yes` in unattended mode) and support `--dry-run`, so that I can retire obsolete templates safely.
17. As a developer, I want to inject a named **Context template** into the project root by default (`--scope project` with no `--folder`), so that common project-wide instructions land in the root **Context file** with minimal flags.
18. As a developer, I want to inject a named **Context template** into a chosen subfolder inside `projectRoot` using `--folder <path>`, so that subtree-specific instructions can be placed where Claude Code (on-demand subtree loading), Codex, or native Pi (cwd-to-ancestor loading) consume them.
19. As a developer, I want `context inject` to reject any `--folder` that escapes `projectRoot`, does not exist, is not a regular directory, traverses a symlink, or is combined with `--scope user`, so that folder injection never writes outside the project boundary.
20. As a developer, I want to inject a named **Context template** into user-global **Context files** using `--scope user`, so that personal cross-project instructions can be written to `<claudeConfigRoot>/CLAUDE.md`, `<codexRoot>/AGENTS.md`, or `<piAgentRoot>/AGENTS.md`.
21. As a developer, I want to select one or more target harnesses (`claude`, `codex`, `pi`) via repeatable `--harness` options or an interactive multi-select prompt, so that I can inject a **Context template** into all of my active harnesses in one command.
22. As a developer, I want `context inject` to deduplicate target paths when multiple selected harnesses resolve to the same canonical file (such as `<targetDir>/AGENTS.md` or `<targetDir>/AGENTS.override.md` for `codex` and `pi`), so that the template is written or appended once instead of being duplicated in `AGENTS.md`.
23. As a developer, I want `context inject` to default to the `standard` variant (`CLAUDE.md` for Claude Code; `AGENTS.md` for Codex and native Pi) and support explicit `--variant` values (`standard`, `local`, `override`, `dot-claude`), so that I can also target `CLAUDE.local.md`, `AGENTS.override.md`, or `.claude/CLAUDE.md` when needed.
24. As a developer, I want `context inject` to fail closed when a requested `(harness, scope, variant)` combination is not natively supported by every selected harness and scope, so that invalid placements (such as `local` for Codex/Pi, `override` for Claude, or `dot-claude` at `--scope user`) are refused with clear diagnostics.
25. As a developer, I want `context inject` to create a missing target **Context file** or append to an existing non-empty target **Context file** separated by exactly one blank line (`\n\n`), so that injecting a template into an existing project preserves the file's existing instructions.
26. As a developer, I want `context inject --replace` to overwrite the target **Context file** with the template's content instead of appending, so that I can reset a target **Context file** to match a template when desired.
27. As a developer, I want injecting an empty (0-byte) **Context template** to succeed when creating a missing target **Context file** or when `--replace` is passed, and to fail closed (`EMPTY_TEMPLATE_APPEND_REFUSED`) when appending to an existing non-empty target **Context file** without `--replace`, so that I can initialize a 0-byte target **Context file** from an empty template without ever appending stray blank lines to a populated file.
28. As a developer, I want `context inject` to follow the two-phase `--plan-id` / `--apply` contract binding both the source template's SHA-256 digest and every deduplicated target file's observed state (`exists`, `sha256`, `byteLength`), so that concurrent changes to the template or target files between planning and publication refuse the apply safely.
29. As a developer, I want `context inject --apply` to save a protected **Authoring recovery copy** whenever it modifies (`append` or `replace`) an existing target **Context file** and record an **Authoring receipt** without writing section tracking markers into the target file or creating a **Managed installation** record, so that target **Context files** remain clean, raw Markdown while retaining recovery evidence.
30. As a developer, I want `context inject` to emit non-blocking advisory warnings when a project-scope Codex target exceeds 32,768 bytes (`project_doc_max_bytes` default) or when same-directory files shadow each other across Claude Code, Codex, or native Pi (such as `AGENTS.override.md` shadowing `AGENTS.md`, or `AGENTS.md` shadowing `CLAUDE.md` in native Pi), so that I am aware of harness-specific discovery rules documented in research.
31. As a developer, I want all `context` subcommands to support `--format text` and `--format json` with Agent Resource's standard envelope (`command`, `outcome`, `data`, `diagnostics`) and exit codes (`0` success, `4` validation/refusal, `7` cancellation), so that both interactive terminal sessions and automated scripts behave predictably.

## Implementation Decisions

### 1. Domain Model, Storage Layout, and Naming Contract

- **Glossary Alignment**:
  - **Context file**: Persistent project, folder, or user instructions placed at a harness-recognized location (such as `AGENTS.md` or `CLAUDE.md`) and consumed by a coding harness.
  - **Context template**: A named, reusable body of context instructions stored and managed by Agent Resource for editing and injection into target context files.
- **User-Scope Template Storage**:
  - Stored **Context templates** are harness-neutral and always reside at user scope in `<userStateRoot>/context-templates/<name>.md`, where `<userStateRoot>` is resolved via `LifecycleContext.stateRoot(LifecycleScope.user)` (honoring `--state-dir`, `--home`, and OS defaults).
  - Register `'context-templates'` in `_privateStateDirectories` inside `LifecycleStateService` so state-root hygiene checks recognize the directory alongside `'instruction-drafts'`, `'authoring-transactions'`, `'authoring-recovery'`, `'authoring-staging'`, and `'authoring-receipts'`.
  - Each template file is a plain UTF-8 regular file with no YAML frontmatter wrapper or sidecar metadata. Both `<userStateRoot>/context-templates` and every `<name>.md` entry must be regular directories/files (no symlinks, junctions, or reparse points). Maximum template size is `maxInstructionDraftBodyBytes` (1 MiB / `1048576` bytes).
- **Template Naming Rules**:
  - Every **Context template** requires a name matching `^[a-z0-9][a-z0-9_-]{0,63}$` (1–64 ASCII characters; starts with a lowercase letter or digit; contains only lowercase letters, digits, hyphens, and underscores) and must not be a Windows reserved device name (`con`, `prn`, `aux`, `nul`, `com1`–`com9`, `lpt1`–`lpt9`).

```dart
/// Decision example: Context template naming, harness, variant, and combine types.
final RegExp contextTemplateNamePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

const Set<String> _windowsReservedNames = <String>{
  'con', 'prn', 'aux', 'nul',
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

bool isValidContextTemplateName(String value) =>
    contextTemplateNamePattern.hasMatch(value) &&
    !_windowsReservedNames.contains(value);

enum ContextHarness { claude, codex, pi }

enum ContextScope { project, user }

enum ContextVariant {
  standard('standard'),
  local('local'),
  override('override'),
  dotClaude('dot-claude');

  const ContextVariant(this.wireName);
  final String wireName;
}

enum ContextCombineAction { create, append, replace }
```

### 2. Template Creation, Editing, Drafts, and Authoring Recovery (`create` & `edit`)

- **Shared Authoring & Draft Integration**:
  - Extend `AuthoringKind` with `contextTemplate` (or provide a dedicated user-scope authoring adapter wired into `InstructionDraftService` and `AuthoringRecoveryService`) so that editor-led `context create` and `context edit` store protected drafts in `<userStateRoot>/instruction-drafts` (`drf_<32hex>`) and record ordinary authoring transactions and recovery copies in `<userStateRoot>/authoring-transactions` and `<userStateRoot>/authoring-recovery`.
  - If an editor-led `context create` or `context edit` session is cancelled, fails to complete, or fails publication, the retained draft's `draftId` and `draftPath` are included in the error message and report so `authoring draft list`, `authoring draft inspect`, `authoring draft resume`, and `authoring draft discard` can manage it.
- **Empty Template Creation vs. Editor/Body Inputs**:
  - `context create` supports an explicit `--empty` boolean flag (flag-only; no interactive empty-vs-editor prompt).
  - `--empty` conflicts with `--body-file`, `--body-text`, `--body-stdin`, and `--editor`. When `--empty` is set, `context create` skips `InstructionDraftService` and `EditorInteractionService`, planning and publishing a 0-byte `<userStateRoot>/context-templates/<name>.md`.
  - When `--empty` is not set:
    - If `--body-file`, `--body-text`, or `--body-stdin` is supplied, the body is read directly without launching an editor.
    - If no body flag is supplied and the session is interactive (and not `--dry-run`), a protected user-scope **Instruction draft** is prepared (`''` for `create`; seeded with the current UTF-8 bytes of `<userStateRoot>/context-templates/<name>.md` for `edit`) and opened via `EditorInteractionService`.
    - Without `--empty`, an empty or whitespace-only body (whether from a body flag or saved in the editor) is rejected with diagnostic code `BODY_EMPTY` (exit code `4`).
- **Two-Phase Plan/Apply and Drift Protection**:
  - `context create` requires `<userStateRoot>/context-templates/<name>.md` to not exist (`TARGET_OCCUPIED` if present).
  - `context edit` requires `<userStateRoot>/context-templates/<name>.md` to exist as a regular file (`TEMPLATE_NOT_FOUND` if missing; `SYMLINK_REFUSED` if a link).
  - `planId` (`pln_<64hex>`) is a SHA-256 digest of the canonical JSON identity binding the operation (`create` or `edit`), template `name`, target path, `empty` flag, proposed body `sha256` and `byteLength`, and (for `edit`) the existing template file's `sha256` and `byteLength`.
  - On `--apply`, if `--plan-id` was supplied and does not match the current `planId`, or if the target file state drifted, publication fails with exit code `4`. On `edit --apply`, the previous bytes of `<userStateRoot>/context-templates/<name>.md` are written to a protected **Authoring recovery copy** before atomic replacement.

### 3. Template Read and Deletion Operations (`list`, `inspect`, `delete`)

- **`context list`**:
  - Scans `<userStateRoot>/context-templates/` (returning an empty list if the directory does not exist).
  - Refuses symlinks or non-regular entries if encountered.
  - Sorts valid `<name>.md` templates lexicographically by `name` and reports each entry's `name`, `path`, `byteLength`, `isEmpty` (`byteLength == 0`), and `sha256`.
- **`context inspect`**:
  - Resolves `<userStateRoot>/context-templates/<name>.md`, verifies it is a regular file, and always returns both its metadata (`name`, `path`, `byteLength`, `isEmpty`, `sha256`) and its complete UTF-8 Markdown `content` in both text and JSON formats without requiring `--show-instructions`.
- **`context delete`**:
  - Verifies `<userStateRoot>/context-templates/<name>.md` exists as a regular file.
  - With `--dry-run`, reports the template that would be deleted (`outcome: 'planned'`, `deleted: false`) without modifying the filesystem.
  - Without `--dry-run`, requires interactive confirmation (`Confirm` / `InstallationApprovalComponent`) on a usable terminal or `--yes` in unattended mode, then unlinks `<userStateRoot>/context-templates/<name>.md` directly (`outcome: 'deleted'`, `deleted: true`).

### 4. Target Context File Resolution, Variant Matrix, and Path Deduplication (`inject`)

- **Harnesses, Scopes, and Folder Validation**:
  - One or more harnesses from `{ claude, codex, pi }` must be selected via repeatable `--harness` options (or interactive multi-select when omitted in an interactive session).
  - `--scope` accepts `project` (default) or `user`.
  - `--folder <path>` is flag-only (no interactive directory picker) and is valid only when `scope == project`. Combining `--folder` with `--scope user` fails closed with exit code `4`.
  - When `scope == project`, `targetDir` is `context.projectRoot` by default, or `context.resolvePath(folder)` when `--folder` is provided. `targetDir` must be an existing regular directory equal to or inside `context.projectRoot`, with no symlink/reparse-point traversal on `targetDir` or any directory segment between `projectRoot` and `targetDir`.
- **Strict `(harness, scope, variant)` Resolution Matrix**:
  - Every requested `(harness, scope, variant)` tuple is validated before planning; if any selected harness does not support the requested `(scope, variant)`, the command fails closed as a whole with exit code `4` (`UNSUPPORTED_CONTEXT_VARIANT`):

```dart
/// Decision example: Strict target path resolution and multi-harness deduplication.
String resolveContextTargetPath({
  required LifecycleContext context,
  required ContextHarness harness,
  required ContextScope scope,
  required ContextVariant variant,
  required String projectTargetDir,
}) {
  final p = context.fs.path;
  return switch ((harness, scope, variant)) {
    (ContextHarness.claude, ContextScope.project, ContextVariant.standard) =>
      p.join(projectTargetDir, 'CLAUDE.md'),
    (ContextHarness.claude, ContextScope.project, ContextVariant.local) =>
      p.join(projectTargetDir, 'CLAUDE.local.md'),
    (ContextHarness.claude, ContextScope.project, ContextVariant.dotClaude) =>
      p.join(projectTargetDir, '.claude', 'CLAUDE.md'),
    (ContextHarness.claude, ContextScope.user, ContextVariant.standard) =>
      p.join(context.claudeConfigRoot(), 'CLAUDE.md'),
    (ContextHarness.codex, ContextScope.project, ContextVariant.standard) =>
      p.join(projectTargetDir, 'AGENTS.md'),
    (ContextHarness.codex, ContextScope.project, ContextVariant.override) =>
      p.join(projectTargetDir, 'AGENTS.override.md'),
    (ContextHarness.codex, ContextScope.user, ContextVariant.standard) =>
      p.join(context.codexRoot(), 'AGENTS.md'),
    (ContextHarness.codex, ContextScope.user, ContextVariant.override) =>
      p.join(context.codexRoot(), 'AGENTS.override.md'),
    (ContextHarness.pi, ContextScope.project, ContextVariant.standard) =>
      p.join(projectTargetDir, 'AGENTS.md'),
    (ContextHarness.pi, ContextScope.project, ContextVariant.override) =>
      p.join(projectTargetDir, 'AGENTS.override.md'),
    (ContextHarness.pi, ContextScope.user, ContextVariant.standard) =>
      p.join(context.piAgentRoot(), 'AGENTS.md'),
    (ContextHarness.pi, ContextScope.user, ContextVariant.override) =>
      p.join(context.piAgentRoot(), 'AGENTS.override.md'),
    _ => throw MambaException(
      'Variant "${variant.wireName}" is not supported for harness '
      '"${harness.name}" at ${scope.name} scope.',
      exitCode: 4,
    ),
  };
}
```

- **Multi-Harness Path Deduplication**:
  - Resolved paths across the selected harnesses are grouped by normalized path in deterministic order.
  - When both `codex` and `pi` are selected at `scope == project` (for `standard` or `override`), they resolve to the same `<projectTargetDir>/AGENTS.md` (or `AGENTS.override.md`). That deduplicated target entry carries `harnesses: ['codex', 'pi']` and is planned, checked, and written/appended **once**.

### 5. Combine Formatting, Empty Template Injection, Two-Phase Apply, and Advisory Warnings

- **Combine Rules (`create`, `append`, `replace`) and Newline Normalization**:
  - Let `templateBytes` be the UTF-8 content of `<userStateRoot>/context-templates/<name>.md`.
  - If the target file does not exist: action is `create`.
  - If the target file exists as a regular file and `--replace` is set: action is `replace`.
  - If the target file exists as a regular file and `--replace` is not set: action is `append`.
  - If `templateBytes` is empty (`0` bytes):
    - Allowed when `action == create` or `action == replace` (or when `action == append` and the existing target file is `0` bytes), producing a `0`-byte target **Context file**.
    - Refused with diagnostic code `EMPTY_TEMPLATE_APPEND_REFUSED` (exit code `4`) when `action == append` and the existing target file is non-empty (`existingByteLength > 0`).

```dart
/// Decision example: Deterministic byte combination for create, append, and replace.
String combineContextContent({
  required String? existingContent,
  required String templateContent,
  required bool replace,
}) {
  String ensureTrailingNewline(String text) =>
      text.isEmpty ? '' : (text.endsWith('\n') ? text : '$text\n');

  if (existingContent == null || replace || existingContent.isEmpty) {
    return ensureTrailingNewline(templateContent);
  }
  if (templateContent.isEmpty) {
    throw MambaException(
      'Cannot append an empty context template to a non-empty context file; '
      'pass --replace to overwrite or populate the template first.',
      exitCode: 4,
    );
  }
  final trimmedExisting = existingContent.replaceFirst(RegExp(r'[\r\n]+$'), '');
  final trimmedTemplate = templateContent.replaceFirst(RegExp(r'^[\r\n]+'), '');
  return ensureTrailingNewline('$trimmedExisting\n\n$trimmedTemplate');
}
```

- **Two-Phase Plan/Apply for `context inject`**:
  - `planId` binds the canonical request (`templateName`, `scope`, `targetDirectory`, sorted `harnesses`, `variant`, `replace`), the source template's `sha256` and `byteLength`, and each deduplicated target's `path`, `existingExists`, `existingSha256`, `existingByteLength`, `action`, `proposedSha256`, and `proposedByteLength`.
  - Without `--apply` (or with `--dry-run`), `context inject` writes nothing and returns `outcome: 'planned'` with `planId` and the deduplicated `targets` array.
  - With `--apply`, `context inject` verifies `--plan-id` (if supplied) and re-verifies that neither the template nor any target file has drifted, prompts for interactive confirmation on a usable terminal (or requires `--yes` in unattended mode), saves a protected **Authoring recovery copy** for each existing target file that is modified (`append` or `replace`), atomically writes each target file via staging + rename inside the user-scope authoring transaction, and records an **Authoring receipt** (`outcome: 'published'`). No section markers are inserted into the target file and no **Managed installation** ledger entry is created.
- **Advisory Diagnostics (Non-Blocking Warnings)**:
  - `CODEX_BYTE_BUDGET_WARNING`: When `codex` is targeted at `scope == project` and `proposedByteLength > 32768`, emit a warning diagnostic noting Codex's default 32 KiB `project_doc_max_bytes` limit.
  - `CONTEXT_SHADOWING_WARNING`:
    - When writing `AGENTS.md` in a directory that already contains `AGENTS.override.md` (warn that Codex and native Pi prefer `AGENTS.override.md` in that directory).
    - When writing `CLAUDE.md` for Claude Code in a directory that also contains `AGENTS.md` (or vice versa), emit an informational note summarizing that default Claude Code prefers `CLAUDE.md` over `AGENTS.md` while native Pi prefers `AGENTS.md` over `CLAUDE.md` in the same directory.

### 6. CLI Command Surface, Options, Flags, and Output Envelopes

- **Command Registration**:
  - Register `ContextCommand` (`name => 'context'`, `shortDescription => 'Manage reusable context templates and inject context files.'`) in `createExecutor` with six direct children: `create`, `edit`, `list`, `inspect`, `delete`, and `inject`.

```text
agent_resource context create  [<name>] [--name <name>] [--empty | --body-file <file> | --body-text <text> | --body-stdin] [--editor <cmd>] [--plan-id <id>] [--apply] [--yes] [--dry-run] [--interactive | --unattended] [--show-instructions] [--format text|json] [--cwd <dir>] [--home <dir>] [--state-dir <dir>]
agent_resource context edit    [<name>] [--name <name>] [--body-file <file> | --body-text <text> | --body-stdin] [--editor <cmd>] [--plan-id <id>] [--apply] [--yes] [--dry-run] [--interactive | --unattended] [--show-instructions] [--format text|json] [--cwd <dir>] [--home <dir>] [--state-dir <dir>]
agent_resource context list    [--format text|json] [--cwd <dir>] [--home <dir>] [--state-dir <dir>]
agent_resource context inspect [<name>] [--name <name>] [--interactive | --unattended] [--format text|json] [--cwd <dir>] [--home <dir>] [--state-dir <dir>]
agent_resource context delete  [<name>] [--name <name>] [--yes] [--dry-run] [--interactive | --unattended] [--format text|json] [--cwd <dir>] [--home <dir>] [--state-dir <dir>]
agent_resource context inject  [<name>] [--name <name>] [--harness claude|codex|pi]... [--scope project|user] [--folder <dir>] [--variant standard|local|override|dot-claude] [--replace] [--plan-id <id>] [--apply] [--yes] [--dry-run] [--interactive | --unattended] [--show-instructions] [--format text|json] [--cwd <dir>] [--project-root <dir>] [--home <dir>] [--claude-config-dir <dir>] [--codex-home <dir>] [--pi-agent-dir <dir>] [--state-dir <dir>]
```

- **Positional `<name>` vs. `--name` and Interactive Fallback**:
  - `create`, `edit`, `inspect`, `delete`, and `inject` accept an optional positional `<name>` and a `--name` option (conflicting if both are supplied on the same invocation).
  - If neither is supplied:
    - In interactive mode: `create` prompts for the template name (`GuidedValueComponent`); `edit`, `inspect`, `delete`, and `inject` present a line-based selector (`mamba component selector`) over the existing stored template names in `<userStateRoot>/context-templates/` (failing with exit code `4` if no stored templates exist, or exit code `7` if cancelled).
    - In unattended mode (`--unattended`, `--format json`, or no usable terminal): fail with exit code `4` (`MISSING_TEMPLATE_NAME`).
- **Interactive Harness Multi-Selection on `inject`**:
  - On `context inject`, if `--harness` is omitted in interactive mode, present `SkillTargetSelectorComponent` with `['claude', 'codex', 'pi']` (failing with exit code `7` if cancelled or empty selection). In unattended mode, omitting `--harness` fails with exit code `4` (`MISSING_TARGET_HARNESS`).
- **JSON Output Envelopes**:
  - Every `context` subcommand emits `{ "command": "context <subcommand>", "outcome": "<planned|published|listed|inspected|deleted|rejected>", "data": { ... }, "diagnostics": [ ... ] }` when `--format json` is selected.
  - On `context inspect`, `data` always includes `"content": "<utf8-markdown>"` along with `"name"`, `"path"`, `"byteLength"`, `"isEmpty"`, and `"sha256"`.
  - On `context create`, `context edit`, and `context inject`, `data` includes `"planId"`, template metadata, target metadata (`targets` array on `inject` with deduplicated `path`, `harnesses`, `variant`, `action`, `existingExists`, `existingByteLength`, `proposedByteLength`, `receiptId`, `recoveryPath`), and `"content"` when `--show-instructions` is passed.

## Context injection publication and recovery boundary

Injection re-observes the template and all destinations after approval, then
checks each destination again immediately before its write. Parent paths and
final entries must not be links or Windows reparse points. Candidates are
staged beside each destination, so the state directory need not be on the
same volume. An ordinary failure after a target write triggers reverse-order
compensation only while the target still has the bytes just published. The
failure message lists compensated and uncompensated targets, recovery-copy
paths, and staging locations. Inspect retained files and obtain a fresh plan
before retrying; a recovery copy is evidence, not automatic authority to
replace a changed destination. Receipts for safely compensated targets are
removed only when their contents still match the receipt written here.

This is a bounded concurrent-writer contract, not filesystem isolation. The
checks and subsequent rename or delete are separate operations: another writer
with access to these directories can race between them. Coordinate writers and
keep destination and state directories trusted for the duration of publication
and compensation. Process termination or power loss may interrupt compensation;
this workflow does not provide an atomic multi-target transaction or a durable
recovery journal. Inspect destination files, recovery copies and staging
locations after interruption. Filesystem rename and flush durability are also
subject to the underlying platform and filesystem.

## Testing Decisions

A good test exercises external CLI behavior and observable filesystem state, never private helpers or internal data structures: it invokes `createExecutor(...).fake().execute([...])` against an in-memory `MemoryFileSystem(style: FileSystemStyle.posix)`, and asserts the returned `MambaSuccessResult` / `MambaFailureResult` (`exitCode`, JSON or text `output`) alongside the resulting files in `<userStateRoot>/context-templates/`, `<userStateRoot>/instruction-drafts/`, `<userStateRoot>/authoring-recovery/`, and the target project, subfolder, or user-global **Context files**.

- **Single High-Level Seam**:
  - All command, validation, draft, recovery, and injection tests run through `createExecutor(fileSystem: fs, ...).fake().execute(args)` with injected prompt/editor callbacks for interactive sessions. No new seam type is introduced.
- **Modules and Behaviors to Test**:
  - **`context create` & `context edit`**:
    - Valid and invalid template names (`^[a-z0-9][a-z0-9_-]{0,63}$`, path traversal, `.md` suffixes, uppercase characters, Windows reserved names).
    - Explicit `--empty` creation producing a 0-byte `<userStateRoot>/context-templates/<name>.md` without creating an instruction draft or launching an editor; flag conflict between `--empty` and `--body-*` / `--editor`.
    - Editor-led creation and seeded editing over protected user-scope `instruction-drafts`, including rejection of accidental empty/whitespace-only saves when `--empty` is not set (`BODY_EMPTY`), draft retention on editor cancellation/unfinished exit (`exitCode: 7`, `draftId` and `draftPath` reported), and draft cleanup on `--apply`.
    - Two-phase `--plan-id` and `--apply` verification, stale `--plan-id` refusal when a template file is modified concurrently, and creation of a protected **Authoring recovery copy** when `edit --apply` replaces an existing template.
  - **`context list`, `context inspect`, & `context delete`**:
    - Deterministic lexicographical listing with `byteLength`, `isEmpty`, and `sha256`.
    - Always-visible `content` in `context inspect` (both text and JSON) without `--show-instructions`, including 0-byte templates.
    - `context delete` with `--dry-run`, interactive confirmation vs. cancellation (`exitCode: 7`), and unattended `--yes` enforcement (`exitCode: 4` when `--yes` is omitted).
  - **`context inject`**:
    - Default project-root injection (`<projectRoot>/CLAUDE.md`, `<projectRoot>/AGENTS.md`), `--folder <subdir>` injection within `projectRoot`, refusal of `--folder` outside `projectRoot` or symlinked directories, and refusal of `--folder` with `--scope user`.
    - User-global injection (`--scope user`) into `<claudeConfigRoot>/CLAUDE.md`, `<codexRoot>/AGENTS.md`, and `<piAgentRoot>/AGENTS.md`.
    - Explicit `--variant` (`standard`, `local`, `override`, `dot-claude`) across single and multi-harness selections, verifying fail-closed refusal for unsupported combinations.
    - Multi-harness deduplication when `--harness codex --harness pi` (or all three harnesses) are selected in project/folder scope, confirming `<targetDir>/AGENTS.md` is written or appended **once** per apply and reports `harnesses: ['codex', 'pi']`.
    - Blank-line separator (`\n\n`) normalization when appending to an existing non-empty file, direct write when the existing file is 0 bytes, full overwrite when `--replace` is passed, and empty-template injection (succeeding on `create` or `--replace`, failing with `EMPTY_TEMPLATE_APPEND_REFUSED` on `append` to a non-empty file).
    - Two-phase `--plan-id` / `--apply` drift detection when either the source **Context template** or any target **Context file** changes between planning and apply, protected **Authoring recovery copy** creation for modified target files, and advisory warnings (`CODEX_BYTE_BUDGET_WARNING`, `CONTEXT_SHADOWING_WARNING`).
- **Prior Art in the Repository**:
  - `test/skill_create_command_test.dart`, `test/prompt_create_command_test.dart`, and `test/agent_create_command_test.dart` (editor-led and flag-led creation, protected draft retention, terminal gating, and two-phase publication over `MemoryFileSystem`).
  - `test/authoring_draft_test.dart` and `test/authoring_test.dart` (draft lifecycle, transaction recovery, and recovery copies).
  - `test/mcp_lifecycle_test.dart` (singular group command surface, JSON/text envelope assertions, and interactive confirmation via `Executor.fake()`).

## Out of Scope

- Direct CLI editing of target **Context files** (`context edit` edits stored named **Context templates** in `<userStateRoot>/context-templates/` only).
- Inserting HTML/Markdown tracking markers into target **Context files**, maintaining a **Managed installation** ledger for injected sections, or updating/removing previously injected template sections in place (`context inject` is a raw one-shot `create`, `append`, or `replace`).
- Creating a target **Context file** directly without a **Context template** (empty creation via `--empty` applies to named **Context templates**, which can then be injected to initialize a 0-byte target **Context file**).
- Interactive empty-vs-editor prompt on `context create` or interactive directory picker on `context inject` (`--empty` and `--folder` are flag-only controls).
- Discovering or installing **Context templates** or **Context files** from **Packs**, and cross-harness **Context file** conversion commands.
- Harnesses beyond Claude Code, Codex, and native Pi, or modifying enterprise/managed policy files (`managed-settings.json` or system-level `CLAUDE.md`).

## Further Notes

- The harness conventions informing target resolution and advisory diagnostics come from the three Wayfinder research baselines recorded for this effort:
  - Claude Code: `docs/research/claude-code-context.md` (branch `research/claude-code-context`, commit `b79f41c`, [Establish Claude Code context file conventions](https://github.com/louiss0/agent_resource/issues/110)).
  - Codex: `docs/research/codex-context.md` (branch `research/codex-context`, commit `36a59fd`, [Establish Codex context file conventions](https://github.com/louiss0/agent_resource/issues/111)).
  - Native Pi: `docs/research/pi-native-context.md` (branch `research/pi-native-context`, commit `b1db060`, [Establish native Pi context file conventions](https://github.com/louiss0/agent_resource/issues/112)).
- All harness target-resolution claims are documentation-targeted (and static source-verified for Codex and installed Pi 1.5.2), not runtime-verified against live harness processes.
- Wayfinder planning map: [Specify context template storage, editing, and injection across coding harnesses](https://github.com/louiss0/agent_resource/issues/109).
