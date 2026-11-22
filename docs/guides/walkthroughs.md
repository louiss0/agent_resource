# Walkthroughs

Three end-to-end first-success flows. Every command is shown unattended so
it can be pasted as-is; drop `--yes` on an interactive terminal to review
each plan interactively instead.

## 1. Install, update, and migrate a Skill

```text
# Preview the exact Skill from a local source before any write
agent-resource skill install ./my-skills/reviewer --source-kind resource \
  --target claude --scope project --method copy --dry-run

# Install it
agent-resource skill install ./my-skills/reviewer --source-kind resource \
  --target claude --scope project --method copy --yes

# See the managed record and its installation ID
agent-resource skill list

# Re-acquire the source and replay the recorded route
agent-resource skill update <installation-id> --dry-run
agent-resource skill update <installation-id> --yes

# Change the installation method — preview the path diff, then confirm
agent-resource skill migrate <installation-id> --method canonical --dry-run
agent-resource skill migrate <installation-id> --method canonical --yes
```

`skill list` prints the installation IDs used below. `update` replays the
recorded route — same source, scope, targets, and method — inside the same
journaled transaction used at install. `migrate` shows the complete
installation-path diff and revalidates the reviewed plan under the journal
lock before writing. If an update or migration is interrupted, inspect its
evidence with `agent-resource skill recover` and complete or roll back the
named transaction.

## 2. Configure a pack and install its Prompts

Add a pack to `agent-resources.toml` (see
[the configuration guide](configuration.md#pack-configuration)):

```toml
schema_version = 1

[packs."my-team/prompt-pack".source]
kind = "local"
path = "../prompt-pack"

[packs."my-team/prompt-pack".update]
track = { kind = "local" }
```

Then:

```text
# Review the candidates and their admission without writing state
agent-resource pack discover my-team/prompt-pack --type prompt

# Validate: native: problems differ from eligibility: problems
agent-resource pack validate my-team/prompt-pack --type prompt

# Install the Prompts as managed Skills, deriving a Pi template for each
# eligible manual-only Skill
agent-resource pack install my-team/prompt-pack --type prompt \
  --target claude --scope project --method copy \
  --prompt-target pi --yes
```

`--prompt-target pi` writes a derived `.pi/prompts` template per eligible
manual-only Skill, recorded on the parent Skill — updates regenerate it,
migration carries it, and removal deletes it. Later
`agent-resource pack update my-team/prompt-pack` reviews upstream changes;
new resources stay unselected unless included, and removals need
`--approve-removal <name>`.

## 3. Register an MCP server and inject a context template

```text
# Register a stdio MCP server in the project scope
agent-resource mcp register --name search --harness claude --scope project \
  --command npx --args -y --args @acme/search-server \
  --env SEARCH_TOKEN=${SEARCH_TOKEN} --yes

# Static check — schema and references only, never a live connection
agent-resource mcp validate --harness claude --scope project

# Replace it declaratively: omitted fields are removed
agent-resource mcp replace --name search --harness claude --scope project \
  --command npx --args -y --args @acme/search-server@2 \
  --dry-run

# Create and inject a shared context template
agent-resource context create --name team-rules --body-file ./team-rules.md --yes
agent-resource context inject team-rules --harness claude --scope project --yes

# Review and save the preferences you keep repeating
agent-resource config effective
agent-resource config prefer --scope project --set cli.install.targets=claude --apply
```

The `--env` value is a native credential *reference* (`${NAME}`), not a
literal secret; the registration records the reference and no secret is
stored or printed. `mcp validate` confirms the declaration is statically
correct — it does not launch the server or test authentication. Injection
is one-shot: editing `team-rules` later requires another `context inject`
to republish.
