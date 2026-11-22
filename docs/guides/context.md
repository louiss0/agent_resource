# Context injection

`context` manages reusable local context templates and injects them into
native harness context destinations — Claude `CLAUDE.md`-style files, Codex
instructions, Pi prompt roots, and Antigravity rules depending on the
selected target.

## Templates

```text
agent-resource context create --name <name> [--body-file <file>|--body-stdin|--body-text <text>] [--editor <cmd>]
agent-resource context edit --name <name> [--body-file <file>|--body-stdin|--body-text <text>]
agent-resource context list [--format text|json]
agent-resource context inspect --name <name>
agent-resource context delete --name <name> [--yes]
```

Templates are ordinary local files under the context state area. Create and
edit validate the template at write time; there is no standalone `context
validate`. Templates are not adopted, replaced, backed up, or recovered
through a managed ledger.

## Inject — one-shot publication

```text
agent-resource context inject [<name>] [--harness claude|codex|pi|antigravity ...] [--scope project|user] [--folder <folder>] [--variant <variant>] [--dry-run] [--yes]
```

Injection renders the selected template into each requested harness's
context destination for the scope. It is a **one-shot publication**: the
destination file is a copy, not a tracked synchronization. Editing the
template afterward does not update destinations it was previously injected
into — inject again to publish the new content.

## Safety rules

- Injection may request confirmation before rendering its destination and
  change report.
- A destination occupied by foreign or locally modified content is not
  silently overwritten; changed or unrecognized destination content is
  retained and reported rather than replaced.
- Multi-target injection publishes targets sequentially; a late failure can
  leave earlier targets changed, and the report names exactly what was
  published and what was not.
- `--dry-run` renders the destination plan and change report without
  writing.
