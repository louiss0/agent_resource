# Agent Resource CLI foundation

> **Research-audit amendment — historical milestone and current command tree.** The original foundation intentionally specified an empty root command list; that milestone history remains intact, but its root-level hierarchy is superseded by later implemented features. Current production exposes `skill` and `agent` groups under `agent_resource`. The `skill` group has `discover`, `inspect`, and `validate` children with no root-level aliases; the Agent checkpoint adds its own inspection children. Root help lists both groups; `agent_resource skill --help` lists the Skill child commands. Existing foundation tests remain under `test/` and current process assertions initialize all working, home, configuration, and temporary directories before snapshots. Compare names, types, and bytes rather than access timestamps: read-only behavior does not claim that SDK/filesystem reads cause no physical access-time updates.
>
> The later skill specifications also narrow their filesystem claims using the research audit: product destination labels are not universal harness discovery, precedence, or runtime-visibility claims, and trusted stable local roots are assumed without hostile concurrent-race guarantees.

## Problem Statement

Agent Resource is intended to manage resources consumed by AI coding harnesses while preserving their native formats and compatibility differences. Today its executable is an empty Mamba scaffold with a generic description and no application tests. A user cannot distinguish the intended product from a generated example, and contributors have no verified command-entry baseline on which to add resource workflows.

The immediate problem is establishing a truthful, runnable, tested starting point—not promising resource operations or harness support that do not exist.

## Solution

Deliver a minimal Agent Resource CLI foundation. Users can invoke the executable, identify its purpose and version, request help, and receive a clear failure for unsupported invocations. The CLI does not discover or mutate resources in this milestone. Contributors have a shared application composition point and command-level regression tests ready for subsequent features.

## User Stories

1. As a CLI user, I want root help to identify Agent Resource, so that I know which application I invoked.
2. As a CLI user, I want the description to explain that the application manages resources consumed by AI coding harnesses, so that I understand its purpose.
3. As a CLI user, I want invoking the application without arguments to display help successfully, so that I can find its available controls.
4. As a CLI user, I want `--help` to display root help successfully, so that I can discover supported invocations.
5. As a CLI user, I want `-h` to provide the same help behavior, so that I can use the conventional short control.
6. As a CLI user, I want `--version` to report the application version successfully, so that I can identify the build when reporting issues.
7. As a CLI user, I want `-v` to provide the same version behavior, so that I can use the framework's conventional short control.
8. As a CLI user, I want unknown commands to fail with a useful diagnostic, so that I do not mistake an unsupported operation for success.
9. As a CLI user, I want unknown options to fail with a useful diagnostic, so that typing mistakes are visible.
10. As a CLI user, I want successful help and version requests to use standard output, so that I can inspect or capture them normally.
11. As a CLI user, I want rejected invocations to use standard error and a nonzero exit status, so that shell scripts can detect failure.
12. As a CLI user, I want informational invocations to leave my resources and harness configuration unchanged, so that exploring the application is safe.
13. As a CLI user, I want help to avoid advertising unimplemented resource operations, so that I can trust the interface.
14. As a CLI user, I want help to avoid unsupported compatibility claims, so that I do not confuse product intent with documentation-targeted or runtime-verified support.
15. As a contributor, I want production and tests to share the same executor configuration, so that tests exercise the application actually shipped.
16. As a contributor, I want command-level tests for supported and rejected invocations, so that future changes preserve the entry-point contract.
17. As a contributor, I want tests that assert behavior rather than internal construction details, so that implementation refactoring remains possible.
18. As a contributor, I want concise local run and verification instructions, so that I can reproduce the baseline before adding features.

## Implementation Decisions

- Keep Mamba as the command framework and preserve the existing executable identity `agent_resource` and version `0.0.0`. This milestone introduces no rename, release automation, or version-source synchronization mechanism.
- Replace the generated description with: "Manage resources consumed by AI coding harnesses."
- Introduce an application-owned composition function returning a newly configured executor. The production executable and tests use this same function; do not duplicate metadata or command registration in tests.
- Keep process-facing delivery in the executable through Mamba's production adapter. Use Mamba's fake adapter only in tests.
- **Historical foundation state:** Keep the root command list empty for this milestone. Later feature specifications supersede that state for current production with the `skill` and `agent` groups; do not add root-level aliases or advertise child workflows directly at the root.
- Use Mamba's built-in help, version, parsing, and error delivery. Do not build a second argument parser or custom help renderer.
- With no selected command, render root help. Support intrinsic `-h`/`--help` and `-v`/`--version` controls.
- Unsupported commands and options are rejected, not returned as successful explanatory strings.
- Help must describe only implemented capabilities. Product purpose is not a claim of support for any particular harness, resource format, or lifecycle operation.
- Do not read resource directories, create management records, access the network, or write harness configuration during these invocations.
- Provide concise contributor-facing instructions for dependency installation, running help/version, static analysis, formatting checks, and tests.
- Preserve unrelated existing checkout content. This specification does not authorize committing all pre-existing untracked files indiscriminately.

## Testing Decisions

- Prefer one primary seam: execute argument lists through the shared application executor's fake adapter. This is the highest application seam available without invoking a process.
- Assert complete observable results: success/failure variant, exit status, and output or diagnostic as applicable. Do not assert private fields, constructor structure, or how Mamba internally parses arguments.
- Cover no arguments, both help controls, both version controls, an unknown command, and an unknown option as individually named or parameterized cases.
- Help assertions verify application identity, the product description, intrinsic controls, and absence of advertised resource-management commands. Avoid snapshots of decorative whitespace and framework formatting.
- Version assertions verify the configured version and successful result, without inventing a new version-output format.
- Rejection assertions require a nonzero result and a diagnostic identifying the unsupported token; do not couple tests to unrelated framework prose.
- Use a small process-boundary smoke check for successful help/version and a rejected invocation to verify production stream delivery and exit status. This checks adapter wiring, not a second implementation of command behavior.
- Run process checks in an isolated temporary working directory and verify no application-owned files are created there. No resource filesystem abstraction is needed for this milestone because no resource operations exist.
### Feature 1: Product identity and root help — 15 acceptance tests

1. No arguments returns a successful result with exit status zero.
2. No arguments produces nonempty root help, rather than silent success.
3. `--help` returns a successful result with exit status zero.
4. `-h` returns a successful result with exit status zero.
5. No arguments and `--help` produce equivalent root-help content.
6. `-h` and `--help` produce equivalent root-help content.
7. Root help identifies the executable as `agent_resource`.
8. Root help includes the exact product description specified above.
9. Root help does not contain the generated description `This is a CLI app`.
10. Root help exposes the long help control `--help`.
11. Root help exposes the short help control `-h`.
12. Root help exposes the long version control `--version`.
13. Root help exposes the short version control `-v`.
14. **Historical foundation check:** Root help does not advertise unimplemented discovery, validation, installation, or adoption commands at this milestone. Current production help is governed by the amendment above: root help lists `skill`, and `skill --help` lists `discover`, `inspect`, and `validate`; assert command paths rather than preserving this old empty-root expectation for later features.
15. Running help repeatedly through one fake adapter produces equivalent successful results, with no accumulated output or changed application identity.

### Feature 2: Version reporting — 15 acceptance tests

1. `--version` returns the success result variant.
2. `--version` reports exit status zero.
3. `--version` produces nonempty output containing the version token `0.0.0`.
4. `-v` returns the success result variant.
5. `-v` reports exit status zero.
6. `-v` produces nonempty output containing the version token `0.0.0`.
7. Long and short version controls produce equivalent output.
8. Version output does not include the root-help usage section; match the framework's actual usage marker rather than assuming capitalization.
9. Version output does not contain the generated description `This is a CLI app`.
10. Two successive version requests through one adapter return equivalent results.
11. A help request followed by a version request leaves the version result unchanged.
12. A version request followed by a help request leaves the help result unchanged.
13. A rejected invocation followed by a version request still returns a successful version result.
14. Two freshly composed executors report the same version, preventing test and production configuration drift.
15. The production executable's version output agrees with the fake adapter's version output after normalizing terminal color and trailing line endings only.

### Feature 3: Safe process boundary and rejected invocations — 15 acceptance tests

1. An unknown command returns the failure result variant.
2. An unknown command produces a nonzero exit status.
3. An unknown command's diagnostic identifies the rejected command token.
4. An unknown long option returns the failure result variant.
5. An unknown long option produces a nonzero exit status.
6. An unknown long option's diagnostic identifies the rejected option token.
7. An unknown short option is rejected with a nonzero status and a diagnostic identifying that token.
8. An unknown option with an attached value, such as `--unsupported=value`, is rejected rather than accepted or ignored.
9. Repeating a rejected invocation through one fake adapter produces equivalent failure results rather than stale success output.
10. A rejected invocation followed by a help request still returns successful root help.
11. Production `--help` exits zero, writes help to stdout, and leaves stderr empty.
12. Production `--version` exits zero, writes version output to stdout, and leaves stderr empty.
13. A production unknown-command invocation exits nonzero, writes its diagnostic to stderr, and leaves stdout empty.
14. A production unknown-option invocation exits nonzero, writes its diagnostic to stderr, and leaves stdout empty.
15. A sequence of production no-argument, help, version, and rejected invocations leaves the complete isolated sandbox unchanged, including working, home, configuration, and temporary directories, nested file contents, and link entries if present.

### Test implementation and isolation details

- These are 15 acceptance checks per feature, not a requirement to create 45 separate test functions. Closely related assertions should share one invocation; use parameterized cases where that improves failure reporting. Do not inflate counts with duplicate subprocess tests.
- For help controls and unsupported-token checks, match rendered controls or diagnostic tokens with boundaries so `-h` is not accidentally satisfied only by a substring in `--help`.
- Normalize ANSI escape sequences and platform line endings where presentation is irrelevant. Do not trim away meaningful diagnostic content or weaken exit-status assertions.
- Use deliberately unsupported command and option names that cannot collide with intrinsic controls. Do not test combinations of help/version and invalid tokens unless a later product requirement specifies precedence; this milestone adopts Mamba's behavior without redefining it.
- Construct fresh executors by default. Reuse an adapter only in the explicitly described sequence tests. Never invoke production `main` inside a unit test, because it owns process streams and process exit status.
- Process tests invoke the real executable using the current Dart SDK and an absolute entry-point path, with the package configuration explicitly resolved when the working directory is temporary. Use argument arrays, not a shell command string.
- Isolate relevant home/configuration environment variables for subprocesses. Initialize the working, home, configuration, and process-temp directories before taking a full sandbox snapshot. Preserve only what the Dart runtime needs; never point tests at the developer's actual harness directories. The isolation contract concerns application effects, not SDK caches outside the sandbox.
- Seed each isolated directory with a sentinel ordinary file and a nested configuration file before the no-mutation test. Compare names, entry types, and bytes before and after. Do not compare access timestamps: reads can change them, and read-only behavior does not claim that SDK/filesystem reads cause no physical access-time updates.
- Each subprocess gets a finite timeout. On timeout, terminate it, collect available stdout/stderr, and fail the test with the invocation and diagnostic context. Clean temporary directories in teardown even when assertions fail.
- Windows is a supported environment for this baseline. Use platform path APIs, avoid assumptions about `/tmp`, POSIX permissions, shell escaping, or symlink privileges, and do not require network access after dependencies have been resolved.
- The absence-of-effects test does not prove universal filesystem or network isolation. Keep the implementation free of resource I/O, management-record creation, and network clients; review this directly rather than adding speculative dependency abstractions.
- There are no existing application tests. Follow the installed Mamba skill's executor-testing conventions as prior art, rather than inventing framework mocks.
- Run focused tests during implementation, static analysis regularly, and the complete test suite plus formatting checks before completion. Any unavailable toolchain checks must be reported explicitly.

## Out of Scope

- Resource discovery, inspection, validation, linting, installation, adoption, replacement, removal, or recovery.
- Resource origins, download clients, registries, caches, management manifests, installation baselines, and mutation-plan persistence.
- Any harness profile or documentation-targeted/runtime-verified compatibility claim.
- Skill destination or installation-scope selection.
- Agent definition composition, agent role bindings, parent configuration changes, or runtime orchestration.
- Interactive prompts, completion generation, custom output formats, and custom help rendering.
- Publishing packages, release pipelines, automatic updates, and global installation management.
- Refactoring project-wide agent instructions or silently incorporating unrelated untracked setup work.

## Further Notes

This is a deliberately narrow first milestone synthesized from the existing scaffold and domain glossary. The conversation supplies no selected resource workflow, supported harness baseline, or lifecycle safety contract; this spec does not pretend those decisions were made. Later resource features require separate specifications with concrete acceptance criteria. The later research audit preserves this milestone as history while superseding its empty-root hierarchy with the `skill` group and explicitly refusing native precedence/runtime-visibility claims.

The command-level testing seam was proposed in the conversation. The user subsequently directed specification creation without further interviewing; there was no separate explicit seam approval.

After implementation, perform a code review and commit only the milestone's intended changes to the current branch, following the user's implementation instructions. Use `openai/gpt-5.6-luna` for any subagents.
