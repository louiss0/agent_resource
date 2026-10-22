# Issue tracker: GitHub

Issues and specs live at https://github.com/louiss0/agent_resource.
Use the `gh` CLI for all operations.

## Repository targeting

Pass `--repo louiss0/agent_resource` on every `gh issue`, `gh pr`,
and `gh label` command. This checkout has no Git remote.
For API calls, use `repos/louiss0/agent_resource/...`.

## Conventions

The examples below include explicit repository targeting.

- Create: `gh issue create --repo louiss0/agent_resource --title "..." --body "..."`
  For multiline bodies, use `--body-file <path>`.
- Read: `gh issue view <number> --repo louiss0/agent_resource --json number,title,body,labels,comments`
- List: `gh issue list --repo louiss0/agent_resource --state open --json number,title,body,labels,comments`
  Add appropriate `--label` and `--state` filters.
- Comment: `gh issue comment <number> --repo louiss0/agent_resource --body "..."`
- Apply/remove labels: `gh issue edit <number> --repo louiss0/agent_resource --add-label "..."` / `--remove-label "..."`
- Close: `gh issue close <number> --repo louiss0/agent_resource --comment "..."`

## Sub-issues

With gh 2.94+, use `gh issue create --parent <parent> ...` or
`gh issue edit <parent> --add-sub-issue <child>`, with repository targeting.

On older versions:
`gh api --method POST repos/louiss0/agent_resource/issues/<parent>/sub_issues -F sub_issue_id=<child-db-id>`.

The database ID is `.id` from
`gh api repos/louiss0/agent_resource/issues/<number>`, not the issue number or node_id.
If sub-issues are unavailable, use a task list in the parent and put
`Part of #<parent>` at the top of the child body.

## Pull requests as a triage surface

**PRs as a request surface: no.**

GitHub shares a number space across issues and PRs. If a reference might
be either, try `gh pr view <number> --repo louiss0/agent_resource`,
then fall back to `gh issue view`.

## Skill operations

- "Publish to the issue tracker": create a GitHub issue.
- "Fetch the relevant ticket": read the referenced issue.

## Wayfinding operations

Used by `/wayfinder`. The map is one issue with child issues as tickets.

- Map: an issue labelled `wayfinder:map`, containing Notes / Decisions-so-far / Fog.
- Child: a sub-issue of the map, labelled `wayfinder:<type>`
  (`research`, `prototype`, `grilling`, or `task`).
  If sub-issues are unavailable, use the parent task-list fallback above.
- Blocking: use native issue dependencies:
  `gh api --method POST repos/louiss0/agent_resource/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`.
  If unavailable, put `Blocked by: #<n>, #<n>` near the top of the body.
  A ticket is unblocked when all blockers are closed.
- Frontier: list the map's open children, excluding assigned tickets and
  those with open blockers. Check `issue_dependencies_summary.blocked_by`
  or the fallback body references. First in map order wins.
- Claim: assign the ticket to the driving developer before starting work:
  `gh issue edit <n> --repo louiss0/agent_resource --add-assignee @me`.
- Resolve: comment with the answer, close the ticket, then append a
  context pointer (gist + link) to the map's Decisions-so-far.
