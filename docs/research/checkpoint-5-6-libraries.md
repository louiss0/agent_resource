# Checkpoints 5–6: Dart library recommendations

Retrieved **2026-10-26 UTC**. Scope: true directory symlinks with entry-only ownership; selected-unit native JSON/TOML patches and private recovery. Supplements [filesystem safety](dart-filesystem-safety.md) and [parent configuration](agent-parent-configuration.md), not a replacement safety/authority specification. **Recommendation ≠ implemented or proven guarantee.** SDK observations below pin Dart 3.13.2 commit `60a57cd42d64dc03e9f07aa60a2e250755c1ef28`; package observations use published version archives. No web/search-enabling tool was exposed; primary sources were retrieved directly over HTTPS. No dependencies installed, application code changed, native mutation probes run, or real user configuration read.

## Practical decision

- **Recommended:** retain `dart:io`, `path`, `crypto`, existing bounded reads/coordination/recovery primitives. They do not provide persisted native identity, exact Windows reparse classification, or portable ACL controls.
- **Conditional, needed for those stronger checks:** a narrow OS adapter using `dart:ffi` / `package:ffi`; optionally `win32` for its verified Windows coverage. Do not treat adding a package as completing the safety proof.
- **Recommended:** retain `toml` for syntax/semantic validation only. No verified drop-in lossless Dart TOML editor emerged. Build selected-unit source-range patches, preserving untouched source; investigate the already locked `petitparser` token API before writing a second TOML grammar.
- **Recommended:** duplicate-key-aware, bounded JSON parsing **with source ranges**, building on the existing parser concepts rather than replacing them with `jsonDecode` → map → whole-file `jsonEncode`. `source_span`/`string_scanner` are optional implementation helpers, not editors or security limits.
- **Rejected:** junction/copy fallback for failed symlink creation; treating target contents as link ownership; `toml` AST printing as lossless editing; Dart `json_ast` 1.0.6 on this SDK; assuming Rust `toml_edit` is a Dart package; `yaml_edit` for JSON/TOML.

## Existing work to reuse—not recommend again as new dependencies

Read `pubspec.yaml`, `pubspec.lock`, `lib/src/skill_files.dart`, `agent_inspection.dart`, and the filesystem/management portions of `services/{lifecycle_state,skill_lifecycle,agent_lifecycle}_service.dart`, including dirty/untracked work in progress.

- Locked direct packages include `path` **1.9.1**, `crypto` **3.0.7**, `toml` **0.18.0**, `yaml` **3.1.4**. Already transitive: `ffi` **2.2.0**, `source_span` **1.10.2**, `string_scanner` **1.4.1**, `petitparser` **7.1.0**. Declare direct dependencies if application code imports them; none were changed here.
- `skillEntityType` confirms ambiguous SDK `notFound` observations against parent listings; `readBoundedSkillMarker` reads cap+1 bytes; directory listings disable link following. These are observations under stable-root assumptions, not native no-follow handles or reservations.
- `LifecycleIO` already provides a test seam for type/list/read/copy/rename/delete/write. The state service provides whole-copy manifests, SHA-256, staged writes, journals/backups, in-process and cooperating-process coordination. Its artifact kinds are currently `skill-copy`/`agent-file`; manifests reject links. Do **not** route entry-only links or selected parent units through unchanged whole-artifact ownership logic.
- `_BoundedJsonParser` already checks duplicate decoded keys, depth 32 and 100,000 nodes during parsing, behind 8 MiB reads and aggregate metadata accounting. It returns values, not edit ranges. Agent request JSON also has a lexical duplicate/depth guard. Native TOML inspection uses `TomlDocument.parse(...).toMap()` and measures depth/nodes **after parsing**: useful existing validation, not a parser-time recursion bound.
- `_makePrivate` currently creates directories then invokes `chmod 700` or `icacls`, with mode/text checks. This is not private-at-creation native ACL verification. Native binding work should fill this gap, not introduce another transaction engine.

## 5. True directory symlinks and filesystem evidence

### SDK: use where its contract suffices

**Verified:** `Link.create` creates true Windows symlinks, not junctions. Windows infers file/directory kind from the **existing target**; a missing target creates a **file** symlink, permanently, not a future directory symlink. Relative-target inference is relative to the link's parent. The implementation calls `CreateSymbolicLinkW` with the directory flag when inferred and requests unprivileged creation; its old-Windows retry removes only that flag, **not** a junction fallback. Privilege/Developer Mode failures remain failures. POSIX creation uses `symlink`/`symlinkat`, storing the target string; the referent need not exist. [S1][S2][S4][W1][P1]

**Practical choice:** SDK creation is sufficient when an existing verified directory target is required. If creation/restoration must support an already broken Windows **directory** link, use explicit `CreateSymbolicLinkW(..., SYMBOLIC_LINK_FLAG_DIRECTORY)` through the adapter; do not let absent-target inference silently recreate a file link. Recheck actual created subtype. This is different from unlinking an existing broken link, which must not require a readable/existing target. [S1][W1]

**Entry-only ownership:** `type(followLinks: false)` and `Link.target` are useful but insufficient as a strong persisted fingerprint:

- Windows SDK classification is broadly `link` for reparse points (with an AF_UNIX exception), not proof of `IO_REPARSE_TAG_SYMLINK` plus directory attribute. `Link.target` accepts symlink and mount-point tags, extracts the **substitute name**, strips a leading `\??\`, and returns a decoded string. It does not expose tag, print name, relative flag or the complete raw record. POSIX `readlink` returns link contents, not canonical target identity. Store/disclose supplied text separately from native observed representation; do not normalize the latter into a resolved-target ownership key. [S2][P2]
- `FileStat` follows the final link and exposes neither inode/device/link count nor Windows tag/file ID/ACL. `FileSystemEntity.identical(a,b)` compares two **current entries** (final links not followed), but returns no ID to persist; SDK Windows uses the older volume serial + 64-bit file index. [S2][S3][S4]
- `Link.delete(recursive: false)` is the SDK entry-unlink primitive. POSIX unlink removes the final symlink, not the referent. Windows SDK selects **RemoveDirectoryW for directory reparse entries**, **DeleteFileW for file links**. Microsoft documents deletion of the symbolic link rather than its target, and explicitly describes target-preserving junction removal. Neither these operations nor prechecks are identity-conditional deletion or no-follow ancestor traversal. No recursive target deletion is authorized. [S1][S2][P3][W1][W2]

**Recommended native evidence:** POSIX `lstat`/`fstatat(AT_SYMLINK_NOFOLLOW)` for entry type, device/inode and link count; bounded `readlink`/`readlinkat` for target representation; `symlinkat`/`unlinkat` where descriptor-relative operations are needed. On Windows, open the entry with `CreateFileW` using `FILE_FLAG_OPEN_REPARSE_POINT` and directory-compatible `FILE_FLAG_BACKUP_SEMANTICS`; inspect `FSCTL_GET_REPARSE_POINT`, require symlink tag plus directory attribute, and distinguish junction/unknown tags. Bound and validate returned byte lengths, offsets and relative flags; do not traverse unknown reparse forms. Those flags alone do not establish protection against linked ancestors. [P1–P4][W3][W4]

For Windows identity, `GetFileInformationByHandle` supplies volume/file index and hard-link count; use `GetFileInformationByHandleEx(FileIdInfo)`/`FILE_ID_INFO` if supporting filesystems requiring 128-bit IDs. Microsoft explicitly says the old 64-bit ID is **not guaranteed unique on ReFS** and IDs can be reused over time. IDs are evidence, not eternal ownership tokens. POSIX device/inode similarly needs an explicit lifetime/reuse policy. Hard-link aliases share content; path normalization and hashes cannot establish absence of unknown aliases. Never use hard links as independent backups, and avoid in-place native-config writes through a possibly aliased entry. [W5][P4]; alias/lifetime limits also detailed in the prior filesystem note.

### Native libraries: exact coverage, not marketing

| Candidate | Published version / SDK constraint | Recommendation and verified scope |
| --- | --- | --- |
| `dart:io`, `dart:ffi` | SDK libraries | **Recommended** IO baseline; **conditional** FFI for OS gaps. FFI calls C APIs; it does not supply cross-platform filesystem policy, ABI-independent `stat` layouts, ACLs or transactions. [S1–S4][F] |
| `ffi` | **2.2.0**, `>=3.7.0 <4.0.0`; already locked transitively | **Conditional/reuse.** Allocation, arenas, UTF-8/UTF-16 helpers; **not POSIX syscall bindings**. Native signatures/layouts/error and lifetime handling remain application-owned. [A1] |
| `win32` | **6.4.0**, `^3.10.0`, Windows; not locked | **Conditional**, not necessary merely to create an existing-target SDK link. Published `lib/src/win32/kernel32.g.dart` includes `CreateSymbolicLink` (W export), `CreateFile`, `DeviceIoControl`, `GetFileInformationByHandle`, `RemoveDirectory`, `DeleteFile`, `CreateDirectory`; `structs.g.dart` includes `BY_HANDLE_FILE_INFORMATION`/`SECURITY_ATTRIBUTES`; constants include `FSCTL_GET_REPARSE_POINT`. **Absent from this archive:** `GetFileInformationByHandleEx`, `FILE_ID_INFO`, `FILE_ATTRIBUTE_TAG_INFO`, `REPARSE_DATA_BUFFER`, `GetSecurityInfo`, `SetSecurityInfo`, and `ConvertStringSecurityDescriptorToSecurityDescriptor`. Enum names such as `FileIdInfo` are not callable bindings. Supplemental FFI or a small native shim is still needed for that scope. [A2] |

All listed SDK constraints admit Dart **3.13.2**. This is metadata compatibility, **not** a tested full dependency resolution or ABI/runtime certification. `win32` additionally declares `ffi ^2.1.4`, `ffi_leak_tracker ^0.1.1`, `meta ^1.17.0`; do not assume it is dependency-free. [A2]

### Permissions/private recovery: shared checkpoint 5/6 obligation

**Recommended:** establish an owner-verified private recovery parent **before writing sensitive bytes**. On POSIX, create with restrictive mode (`mkdir` 0700, new files via exclusive `open` 0600), verify ownership/type and effective permissions, and assess ACL behavior per supported OS/filesystem; `umask` is process-wide, not a per-operation privacy API. Linux default ACL inheritance has explicit rules interacting with requested mode; it must not be generalized to every POSIX-like ACL implementation. On Windows, use explicit security attributes/protected DACL with resolved SIDs at creation and inspect the actual security descriptor; a default/inherited ACL, account-name environment variable, or localized `icacls` text is not equivalent evidence. `CreateDirectoryW`/`CreateFileW` accept security attributes; `GetSecurityInfo` is a documented descriptor-reading API, but is missing from the examined `win32` archive. [P5][W3][W6]

This does not promise confidentiality from administrators/the same user's hostile processes, perfect metadata preservation, hostile-writer resistance or power-loss durability. Follow the already chosen trusted-local-root/cooperative-operation envelope in the prior filesystem note. Native IDs/handles do not make multi-object commits atomic.

## 6. Source-preserving selected-unit JSON/TOML patches

Parent authorization remains exactly as researched: eligible explicitly reviewed user/project writes only, managed/system/session authority inspect-only; ordinary Agent edits do not implicitly authorize parent changes. Claude settings/MCP JSON and Codex TOML have different unit/precedence contracts. A parser is not a scope resolver. [parent configuration](agent-parent-configuration.md)

| Candidate | Availability / declared SDK | Decision from primary source |
| --- | --- | --- |
| `toml` | **0.18.0**, `>=3.8.0 <4.0.0`; locked | **Recommended validation only; rejected as lossless printer.** `TomlDocument.parser` filters comment/blank expressions out; `TomlExpression` trims whitespace/skips comments; arrays discard separators/comments. `TomlNode.toString` invokes a pretty printer. Its AST retains ordered expressions and some syntactic distinctions, but has no attached original source ranges/trivia. `toMap` is still less suitable for preservation. [A3] |
| `toml_edit` | Pub API **404** on retrieval | **Rejected as a Dart dependency recommendation.** The real Rust crate documents formatting/comment-preserving TOML editing, but is not a Dart package. Rust FFI/helper integration would be a separate build/deployment decision, not a drop-in replacement. No such integration recommended here. [N1] |
| `petitparser` | **7.1.0**, `^3.13.0`; locked transitively | **Conditional practical TOML seam.** `Parser.token()` returns `Token` with original buffer/start/stop and `input = buffer.substring(start, stop)`. `toml` publicly exposes `TomlExpression.parser`, `TomlKey.parser`, `TomlValue.parser` and whitespace parsers. Instrument/wrap relevant grammar boundaries to retain raw slices; whole-expression tokens alone do not identify every nested selected unit. This is a source-supported building block, **not an existing lossless editor**. [A3][A4] |
| `source_span` | **1.10.2**, `^3.1.0`; locked transitively | **Optional recommended helper** for ranges/diagnostics, not parsing/editing. Use `SourceFile.fromString`, whose offsets use Dart UTF-16 code units; the deprecated default constructor uses runes and can mismatch `substring` offsets. Neither is a UTF-8 byte-offset API. [A5] |
| `string_scanner` | **1.4.1**, `^3.1.0`; locked transitively | **Optional helper**: position, pattern matching, code-unit reads and span-aware errors. No JSON/TOML semantics, lossless editor or automatic resource budgets. Do not add merely to replace an adequate existing scanner. [A6] |
| `json_ast` | **1.0.6**, `>=2.12.0 <3.0.0` | **Rejected for current SDK.** Real Dart package with AST/location APIs, but published SDK upper bound excludes Dart 3.13.2. Do not recommend installing with constraint overrides or assume that a fork's editor/budget behavior is proven. [A7] |

The compatible packages' declared SDK constraints admit 3.13.2; no solver or behavior test was run. Their published source establishes the capabilities above, not complete TOML-language coverage for a new patch adapter. `source_span` is not a source-edit engine. Pub lookups for the plausible names `json_edit`, `source_edit`, `jsonc_parser` returned 404; this is **not** a claim that no lossless Dart editor can exist. A speculative new dependency is less practical than extending the existing duplicate-aware parser.

### Recommended patch contract (engineering inference, not supplied by any package)

1. **Retain original source, patch ranges, not regenerated maps.** Strict JSON does not permit comments; reject them in Claude strict-JSON files rather than quietly accepting JSONC. Preserve TOML comments and all unselected order/whitespace/unknown keys by leaving those source slices unchanged. Preserve newline style/terminal newline and have an explicit BOM/encoding policy. Keep UTF-16 parser offsets separate from UTF-8 byte bounds; reject unsupported encodings rather than lossy rewriting. JSON duplicate names cause interoperability problems; refuse duplicates after escape decoding (`"a"` and `"\u0061"` collide), not only duplicate raw spellings. [J][A4–A6]
2. **JSON:** extend the bounded, duplicate-aware parser concept to record object-member/key/value/container ranges and separators while enforcing limits. `jsonDecode` can validate a bounded scalar/replacement, but alone returns values without preservation evidence. Add/delete operations must own precisely the required comma/whitespace span; zero edits must reproduce the input exactly. Whole-object replacement is authorized only when that whole object is the reviewed selected unit.
3. **TOML:** keep `toml` validation and prototype range capture using its public grammar plus `petitparser` tokens. Select by decoded key segments, not lines/regex or a flattened dotted string. Handle quoted/dotted keys, implicit/explicit tables, inline tables, arrays of tables, multiline strings and interleaved subtables. A semantic unit need not be one contiguous table block. Define comment/separator ownership on deletion. Refuse ambiguous/unsupported shapes rather than reformatting the file. No verified drop-in lossless alternative was found; a range adapter still needs implementation/proof. [A3][A4]
4. **Bound before/during parse.** Reuse cap+1 reads, strict decoding and aggregate accounting. Enforce nesting, nodes/tokens, scalar lengths, and work bounds before recursive parsers allocate unbounded structure. Existing TOML post-parse depth/node measurement is not enough. A lexical preflight must understand strings/comments/multiline TOML, not count raw brackets. Token wrappers alone add no recursion bound. Reparse output and verify selected-unit semantics plus untouched slices; budget exhaustion is refusal, not repair.
5. **Separate logical ownership from physical publication.** Publishing a freshly composed whole file may be necessary, but does not grant ownership over unrelated settings. Re-read/revalidate the current source and reviewed preconditions under existing coordination; refuse observed drift. Recovery should compare the selected unit's current postimage before applying an inverse patch, preserving unrelated newer edits. Never blindly restore an old whole parent file over unrelated user changes. Any whole-file preimage/temporary/journal may contain credentials: private storage first, restricted diagnostics, bounded retention, no raw values in ordinary reports. No helper/MCP/auth commands are executed by parsing.

## Release proof obligations—not answered by dependency choice

- Qualify actual supported SDK/OS/local filesystems. Test true Windows directory symlinks, privilege failure with **no fallback**, relative/absolute targets, broken-target restore/unlink, junction/unknown-tag refusal and raw-vs-decoded representation. Check identity across entry backup/restore and ID reuse assumptions; define refusal/representation for POSIX link bytes not representable by the application's string/encoding policy. Relative entry backups must not silently change referents by moving to another parent.
- Verify native ABI layouts, byte counts, error reporting and handle/allocation cleanup; POSIX `stat` is not one portable FFI struct. Establish Windows ID width/filesystem support and hard-link detection policy. Entry verification and unlink remain separate operations under the bounded writer assumptions.
- Prove private recovery creation and actual permissions/ACLs on each supported platform **before secret bytes**, including inherited ACLs and failures. The current shell-based restriction routine is not that proof. Decide which permissions/metadata must be preserved on replacement; no portable exact-fidelity claim.
- Golden fixtures for no-op equality and selected-unit-only edits: escaped/duplicate JSON keys, unknown fields, number lexemes, Unicode/non-BMP text, CRLF, final newline; TOML dotted/quoted keys, inline/nested tables, arrays of tables and multiline/comment edge cases. Test deep/large/malformed input rejection **during parsing**, not just after it.
- Inject publish/journal/permission/recovery failures. Demonstrate unrelated post-write changes survive selected-unit recovery and colliding/changed units refuse. Retain truthful partial/indeterminate outcomes. No package establishes atomic joint config+ledger publication or power-loss durability.

## Primary sources

Package links below are **exact published source archives** (inspect the named files above); version metadata includes SDK/dependency constraints. These are stronger evidence than package descriptions.

[A1]: https://pub.dev/api/archives/ffi-2.2.0.tar.gz
[A2]: https://pub.dev/api/archives/win32-6.4.0.tar.gz
[A3]: https://pub.dev/api/archives/toml-0.18.0.tar.gz
[A4]: https://pub.dev/api/archives/petitparser-7.1.0.tar.gz
[A5]: https://pub.dev/api/archives/source_span-1.10.2.tar.gz
[A6]: https://pub.dev/api/archives/string_scanner-1.4.1.tar.gz
[A7]: https://pub.dev/api/archives/json_ast-1.0.6.tar.gz
[N1]: https://pub.dev/api/packages/toml_edit

- **A1–A7:** [ffi][A1] (`lib/ffi.dart`), [win32][A2] (generated APIs/structs), [toml][A3] (`lib/src/ast/{document,expression,node}.dart`, `ast/value/array.dart`), [petitparser][A4] (`lib/src/parser/action/token.dart`, `lib/src/core/token.dart`), [source_span][A5] (`lib/src/{file,span}.dart`), [string_scanner][A6] (`lib/src/string_scanner.dart`), [json_ast][A7] (`pubspec.yaml`, `lib/json_ast.dart`). Metadata: `https://pub.dev/api/packages/<name>/versions/<version>` for each table row; constraints checked against those responses and archive pubspecs.
- **N1:** [Dart package lookup: toml_edit](https://pub.dev/api/packages/toml_edit) (404); [actual Rust toml_edit documentation](https://docs.rs/toml_edit/latest/toml_edit/).
- **F:** [Dart C interoperability](https://dart.dev/interop/c-interop).

[S1]: https://github.com/dart-lang/sdk/blob/60a57cd42d64dc03e9f07aa60a2e250755c1ef28/sdk/lib/io/link.dart
[S2]: https://github.com/dart-lang/sdk/blob/60a57cd42d64dc03e9f07aa60a2e250755c1ef28/runtime/bin/file_win.cc
[S3]: https://github.com/dart-lang/sdk/blob/60a57cd42d64dc03e9f07aa60a2e250755c1ef28/sdk/lib/io/file_system_entity.dart
[S4]: https://github.com/dart-lang/sdk/blob/60a57cd42d64dc03e9f07aa60a2e250755c1ef28/runtime/bin/file_linux.cc
[F]: https://dart.dev/interop/c-interop
[P1]: https://pubs.opengroup.org/onlinepubs/9799919799/functions/symlink.html
[P2]: https://pubs.opengroup.org/onlinepubs/9799919799/functions/readlink.html
[P3]: https://pubs.opengroup.org/onlinepubs/9799919799/functions/unlink.html
[P4]: https://pubs.opengroup.org/onlinepubs/9799919799/functions/fstatat.html
[P5]: https://pubs.opengroup.org/onlinepubs/9799919799/functions/open.html
[W1]: https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createsymboliclinkw
[W2]: https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-deletefilew
[W3]: https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew
[W4]: https://learn.microsoft.com/en-us/windows/win32/api/winioctl/ni-winioctl-fsctl_get_reparse_point
[W5]: https://learn.microsoft.com/en-us/windows/win32/api/fileapi/ns-fileapi-by_handle_file_information
[W6]: https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo
[J]: https://www.rfc-editor.org/rfc/rfc8259.html

- **S1–S4:** SDK [Link][S1]; Windows [CreateLink, DeleteLinkHelper, LinkTarget, GetTypeAndAttributes, AreIdentical][S2]; [FileStat/FileSystemEntity][S3]; Linux [CreateLink/LinkTarget/AreIdentical][S4]. macOS source and broader rename/lock/recovery evidence remain indexed in the prior filesystem note.
- **W1–W6:** Microsoft [CreateSymbolicLinkW][W1], [DeleteFileW][W2], [RemoveDirectoryW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-removedirectoryw), [CreateFileW][W3], [FSCTL_GET_REPARSE_POINT][W4], [REPARSE_DATA_BUFFER](https://learn.microsoft.com/en-us/windows-hardware/drivers/ddi/ntifs/ns-ntifs-_reparse_data_buffer), [BY_HANDLE_FILE_INFORMATION][W5], [GetFileInformationByHandleEx](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-getfileinformationbyhandleex), [FILE_ID_INFO](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info), [CreateDirectoryW](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createdirectoryw), [GetSecurityInfo][W6], [security descriptor creation example](https://learn.microsoft.com/en-us/windows/win32/secauthz/creating-a-security-descriptor-for-a-new-object-in-c--) (mechanism, **not** the example's access policy).
- **P1–P5:** POSIX.1-2024 [symlink/symlinkat][P1], [readlink/readlinkat][P2], [unlink/unlinkat][P3], [stat/fstatat/lstat][P4], [open/openat][P5], [mkdir](https://pubs.opengroup.org/onlinepubs/9799919799/functions/mkdir.html); Linux man-pages [ACL inheritance/mode interaction](https://man7.org/linux/man-pages/man5/acl.5.html) (Linux-specific ACL model).
- **J:** [RFC 8259 §§2, 4, 8][J]: JSON grammar, duplicate-name interoperability, encoding.
