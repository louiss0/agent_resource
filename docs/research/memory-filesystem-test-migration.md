# Memory filesystem test migration

## Decision

Most tests whose only external effect is creating, reading, changing, or deleting
ordinary files should use `package:file` with `MemoryFileSystem`. Tests that
assert operating-system behavior must continue to use the host filesystem.

The production seam is an injected `FileSystem` whose default is
`LocalFileSystem`. Tests receive a `MemoryFileSystem`; production commands keep
the local default. Native links and child processes remain separate capabilities
instead of being hidden behind an in-memory approximation.

## Why this migration is needed

The current tests create hundreds of temporary directories through `dart:io`.
That makes logically pure tests depend on the host path syntax, cleanup, file
locking, antivirus/indexing, Windows path behavior, and filesystem speed. It
also makes it difficult to simulate failure and state transitions without
leaving real artifacts.

An in-memory filesystem provides:

- deterministic isolated trees per test
- faster setup and teardown
- no dependency on `Directory.systemTemp`
- direct control over missing files and competing occupants
- portable path behavior when a test chooses an explicit filesystem style
- clearer separation between application behavior and platform integration

It does **not** prove native link, permission, process, or atomic host-filesystem
semantics. Those remain real integration tests.

## Production seams to migrate

### Foundation

| Production area | Required change |
| --- | --- |
| `pubspec.yaml` | Add `package:file` |
| Shared test support | Provide memory and local filesystem fixtures |
| Executor/service composition | Share one injected `FileSystem`, defaulting to `LocalFileSystem` |

### High-value leaf readers and state writers

| Production file | Behavior suitable for memory FS |
| --- | --- |
| `lib/src/installation/resource_catalog.dart` | Bounded configuration reads and catalog parsing |
| `lib/src/pack/pack_configuration.dart` | Pack configuration discovery and reads |
| `lib/src/pack/pack_state.dart` | State JSON, selections, records, retained snapshots, ordinary copies and digests |
| `lib/src/services/lifecycle_state_service.dart` | Installation registry, transaction journal, backups, quarantine/staging state |
| `lib/src/services/parent_config_service.dart` | Managed parent configuration reads, writes, backup, and rollback |
| `lib/src/skill_files.dart` | Entity typing, bounded reads, and ordinary traversal |

### Services that should receive the same filesystem later

- `skill_source_discovery.dart`
- `skill_root_markdown_migration.dart`
- `skill_admission.dart`
- `agent_inventory.dart`
- `agent_inspection.dart`
- `agent_graph_service.dart`
- `agent_authoring_service.dart`
- `agent_conversion_service.dart`
- `agent_installation_service.dart`
- `skill_installation_service.dart`
- `agent_lifecycle_service.dart`
- `skill_lifecycle_service.dart`
- ordinary portions of `pack_lifecycle_service.dart`

Acquisition remains mixed: local-copy behavior can eventually use the injected
filesystem, while Git, HTTP, archives, and process execution remain integration
adapters.

## Tests that should migrate

### Direct memory-filesystem candidates

These tests primarily exercise content, parsing, state transitions, and ordinary
writes:

- `test/src/installation/resource_catalog_test.dart`
- ordinary file-loading cases in `test/src/pack/pack_configuration_test.dart`
- serialization and ordinary snapshot cases in `test/src/pack/pack_state_test.dart`
- ordinary registry/backup/transaction cases in
  `test/src/services/lifecycle_state_service_test.dart`
- most of `test/src/services/parent_config_service_test.dart`
- ordinary authoring/conversion cases in:
  - `agent_authoring_service_test.dart`
  - `agent_conversion_service_test.dart`
  - `bound_role_service_test.dart`
- ordinary inventory/graph cases in:
  - `agent_graph_service_test.dart`
  - `agent_installation_service_test.dart`
- ordinary copy/install cases in:
  - `skill_installation_service_test.dart`
  - `agent_lifecycle_service_test.dart`
  - `skill_lifecycle_service_test.dart`
  - `pack_lifecycle_service_test.dart`
- ordinary command fixtures in:
  - `agent_create_command_test.dart`
  - `agent_clone_test.dart`
  - `agent_compose_test.dart`
  - `agent_convert_test.dart`
  - `agent_edit_test.dart`
  - `agent_install_test.dart`
  - `bound_role_command_test.dart`
  - `skill_install_test.dart`

### Mixed suites that should be split

These files contain many memory candidates but also genuine platform tests:

- `test/agent_test.dart`
- `test/agent_list_test.dart`
- `test/discover_test.dart`
- `test/discover_user_test.dart`
- `test/inspect_test.dart`
- `test/validate_test.dart`
- `test/lifecycle_test.dart`
- `test/src/services/acquisition_service_test.dart`
- `test/src/services/resource_unit_transaction_test.dart`
- `test/src/services/skill_lifecycle_service_test.dart`
- `test/src/services/pack_lifecycle_service_test.dart`
- `test/src/pack/skill_admission_test.dart`

The split should be visible in test names or groups: ordinary application
behavior uses the memory fixture; host-capability behavior uses the local
fixture.

## Tests that must remain on the real filesystem

### Native links and symlinks

Keep real, capability-gated tests for:

- `test/src/services/native_link_service_test.dart`
- symlink/reparse-point portions of `agent_test.dart`, `agent_list_test.dart`,
  `inspect_test.dart`, `validate_test.dart`, and `installation_request_test.dart`
- link adoption, exposure, rollback, and restoration portions of
  `skill_lifecycle_service_test.dart`, `pack_lifecycle_service_test.dart`,
  `lifecycle_test.dart`, and `skill_install_test.dart`
- the escape-link case in `skill_admission_test.dart`

`MemoryFileSystem` can model an abstract link, but it cannot prove Windows
reparse-point classification, privilege behavior, link target semantics, or the
exact refusal behavior of native APIs. Converting these tests would reduce
confidence rather than improve it.

### Permissions and file locking

Keep real tests that use chmod, unreadable files/directories, read-only flags,
exclusive locks, or atomic host renames. Memory implementations do not reproduce
all platform error modes.

### Processes, Git, HTTP, and archives

Keep real integration coverage for:

- `test/cli_process_test.dart`
- Git/process portions of `acquisition_service_test.dart`
- local HTTP server, timeout, redirect, and streaming portions of
  `acquisition_service_test.dart`
- archive extraction and unsafe archive-entry integration cases
- release qualification helpers that spawn the compiled CLI

A filesystem abstraction must not pretend to replace process, socket, Git, or
archive integration.

## Path policy

Memory tests should use `MemoryFileSystem(style: FileSystemStyle.posix)` and the
filesystem's own path context. Tests should not use the host-global
`package:path` context to build virtual paths on Windows. Production continues
to use `LocalFileSystem`, whose path context follows the host.

This makes tests deterministic and prevents a Windows backslash path from being
fed into a POSIX memory filesystem.

## Migration order

1. Add `package:file` and shared test fixtures.
2. Convert bounded readers and configuration loading.
3. Convert state registries, transactions, and ordinary backups.
4. Thread the filesystem through lifecycle/install/authoring services.
5. Convert ordinary command suites.
6. Split mixed suites and leave explicit local integration groups.
7. Run native Windows, Linux, and macOS CI to retain confidence in the local
   adapters.

## Completion criteria

The migration is complete when:

- ordinary unit/service tests no longer create `Directory.systemTemp` sandboxes
- one injected filesystem instance reaches all cooperating services in a test
- memory tests use the virtual filesystem path context
- native-link, permission, process, Git, HTTP, archive, and atomic-local tests
  remain visibly real integration tests
- the complete suite passes locally and in native CI
