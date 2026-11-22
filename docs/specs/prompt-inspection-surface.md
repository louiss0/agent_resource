> **Historical design record** — this document may not describe
> current behavior. See [README.md](../README.md) and
> [docs/guides/](guides/) for current guidance.

# Harness-relative Skill and Prompt inspection

Delivery: [#91](https://github.com/louiss0/agent_resource/issues/91).
Canonical boundaries: [#61](https://github.com/louiss0/agent_resource/issues/61),
[#77](https://github.com/louiss0/agent_resource/issues/77), and
[#79](https://github.com/louiss0/agent_resource/issues/79).

## Public surface

```text
prompt inspect --path <directory-or-template> [--target claude|codex|pi] [--format text|json]
prompt validate --path <directory-or-template> [--target claude|codex|pi] [--format text|json]
prompt list [--scope project|user|all] [--target claude|codex|pi] [--format text|json]
skill inspect --skill <directory> [--target claude|codex|pi] [--content]
skill validate --skill <directory> [--target claude|codex|pi]
```

The existing Prompt conversion commands remain registered. No publication,
installation adapter, adoption, membership, draft, or management write is added.

`PromptReadService` reuses `PromptInspectionService`; it does not add another
native parser. The shared contracts and body-free view projection live under
`lib/src/prompt/`. Pack discovery uses the same public per-harness view model.

## Classification, validity, and context

- Classification and validity belong to a consuming Harness's view, not a source
  universally. A source can be a Claude Prompt and an ordinary Codex Skill.
- Prompt resource-free/path restrictions apply only in Prompt views. The
  inspector still checks native Skill fields in ordinary Skill views. Invalid
  Prompts never become ordinary Skills in that same view.
- Reports without a target expose the separate views. Validation with a target
  checks that view; without a target, every reported view must pass. Prompt
  validation additionally requires Prompt classification, so an ordinary Skill
  cannot pass that command merely because its native form is valid.
- Unknown/malformed controls cannot default to ordinary Skills. Safely verified
  absence can use the inspector's documented native defaults.
- An explicit directory is inspected as a Skill package and a regular file as a
  template. An arbitrary Markdown file is not evidence of a template profile:
  without `--target pi`, its template classification stays unknown. The native
  Pi template inventory root supplies explicit Pi context; a requested other
  target is never silently replaced by Pi.
- Pi manual-only Skills and Pi templates can be recognized and valid while
  `installationSupported` remains false. No Pi Skill/Prompt installer is added.
- Global compatibility, native form, placement, and management stay separate.
  Explicit path reads report unknown placement, because they lack inventory
  context. Native inventory occurrences report the observed project/user
  placement. Neither implies loading, cross-project availability, or activation.

## Bounded native inventory

`prompt list` accepts the existing context overrides (`--cwd`, `--project-root`,
`--home`, `--state-dir`, `--claude-config-dir`, `--codex-home`, `--pi-agent-dir`).
Scope defaults to user.

Project reads observe the bounded cwd-to-project-root ancestor chain (at most
64 ancestors). Each ancestor contributes `.claude/skills`, `.codex/skills`,
`.agents/skills`, `.pi/skills`, and `.pi/prompts`. User reads use the resolved
Claude/Codex/shared Skill roots plus Pi's agent-directory `skills` and `prompts`.
This includes the Pi view of shared Skill sources; destination never assigns
exclusive Harness ownership.

Native roots are streamed with a shared 10,000-entry budget before retaining
entries for deterministic sorting. Only direct package/template entries are
inventory candidates; this is not recursive pack discovery. Hidden entries are
not candidates but count against the budget. Linked roots, linked ancestors,
linked candidates, and linked Skill markers are refused without reading their
targets. The reused inspector applies its own byte/YAML/package budgets.

Each source path is reported once with its views. A selected target filters on
that view, not another Harness's classification. Known ordinary Skills are not
Prompt inventory entries; unknown and invalid Prompt candidates remain
inspectable. Native reads still run before filtering so operational failure
cannot be hidden as a successful partial inventory.

Management is an independent observation (`managed`, `unmanaged`, or
`ownershipUnverified`); reading cannot adopt anything. The existing Skill
inventory retains its missing/link/management-document occurrences. Readable
sources gain native Prompt views; unavailable sources get empty views and an
explicit noninspection reason instead of a fabricated classification.

## Failure and disclosure contracts

Native/product validation errors remain diagnosable invalid views in inspection
and inventory. Selected invalid or unknown validation fails with status 2.
Operational lookup/read/budget failures stop the request at the first failure;
there is no successful partial inventory or swallowed inspection diagnostic.
Ownership-document uncertainty can still be reported independently of a
successfully inspected native source.

| Refusal | Status |
| --- | --- |
| Invalid, unknown, or non-Prompt selected Prompt validation view | 2 |
| Invalid or unknown selected Skill validation view | 2 |
| Source missing, unreadable, unstable, or unsafe for explicit inspection | 1 |
| Native root is not a directory; inventory entry/ancestor budget exceeded | 3 |
| Linked native inventory root, ancestor, candidate, or marker | 4 |
| Invalid target or missing mandatory CLI option | 2 (parser) |

Default reports contain no instruction body. **Compatibility change confirmed
with the user:** `skill inspect` is now body-free by default. `--content`
explicitly selects the old verbatim immediate-marker JSON contract; it is not
validation or a Harness compatibility claim. Combining content and target is
refused. Skill validation now reports native per-Harness validity, rather than
a universal core-profile result. The existing bounded core profile remains
available to its library/mutation callers and retains regression tests.

## Evidence and limitations

The command suites exercise registered help/parsing, mixed/ordinary/invalid
views, target filtering, native Pi template context, Pi/shared user scope,
project ancestors, linked entries/markers/ancestors, budget exhaustion, injected
native read failure, and body nondisclosure. Source-byte/state assertions and
isolated real CLI process tests check read-only effects, successful reporting,
failures without partial stdout, and explicit content opt-in.

Final verification after the review fixes:

- `dart format lib test`: no remaining formatting changes.
- `dart analyze`: no issues found.
- `dart test --concurrency=2 --timeout=2m`: **1,012 passed, four skipped**.
- Final independent Standards and Spec reviews: no remaining actionable findings
  or concrete blockers in the reviewed change.

The final fixes retain failed-validation JSON diagnostics, charge missing-parent
confirmation reads against the inventory budget, and index ownership evidence
once per scope; focused tests cover each behavior. The full-suite result above
was collected after those fixes, not before them.

Tests run locally on Windows; in-memory IO injection is not proof of Windows ACL
behavior. Native symlink capability and unreadable-directory cases retain
platform-dependent limitations in the existing regression suites. No Claude,
Codex, or Pi runtime was exercised; no loading or activation is verified.
