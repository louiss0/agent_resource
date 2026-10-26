## Problem Statement

A developer maintaining a local Skill must currently reinstall a copied installation to expose source changes to a consuming harness. A linked installation should let the developer work on one source tree without granting Agent Resource ownership of that source. The dangerous failure is treating a directory link like a copied directory: removing, replacing, backing up, restoring, or cleaning an installation must never recursively change its user-owned target.

This is roadmap **checkpoint 5: required Skill links**. It extends verified copied-installation behavior; it does not assume the current uncommitted checkpoint-4 implementation is complete or safe.

## Solution

Support explicit top-level directory-symlink installation and adoption for eligible Claude, Codex, and Shared Skill destinations in project and user scopes. Keep the existing Skill command paths and user-scope default. Installation defaults to copy; explicit link mode installs a true native directory symlink. Existing installations can change between copy and link only through reviewed managed replacement at the same location.

Manage only the linked installation's entry. Present target location and target-validation observations separately from management ownership. Safely unlink an unchanged owned entry even when its target later changes, disappears, or becomes inaccessible. Retain verifiable entry-only backups and evidence-backed recovery without claiming target-content history.

## User Stories

1. As a Skill author, I want to install a link to my local Skill source, so that source edits become available without repeated copies.
2. As a CLI user, I want copy to remain the default, so that existing installation behavior does not change unexpectedly.
3. As a CLI user, I want to select copy or link explicitly during installation, so that the ownership model is intentional.
4. As a user with an existing directory symlink, I want explicit adoption, so that I can bring its entry under management without rewriting the link or target.
5. As a source owner, I want management ownership limited to the link entry, so that my source never becomes a deletion or overwrite target.
6. As a Claude user, I want project and user linked installations, so that I can choose the appropriate installation scope.
7. As a Codex user, I want the supported native destinations and explicit configuration-home context respected, so that links are not silently routed elsewhere.
8. As a Shared-destination user, I want one physical management identity, so that multiple consuming harnesses cannot acquire competing ownership.
9. As a CLI user, I want scope and destination kept independent, so that Shared does not silently mean user-global.
10. As a user, I want installation to validate the disclosed content target, so that malformed or incompatible Skills are not installed through a link loophole.
11. As a user, I want internal links and unsupported entry kinds refused, so that one permitted target traversal does not authorize arbitrary filesystem access.
12. As a user, I want name conflicts checked across required visible candidates, so that link installation does not introduce forbidden shadowing.
13. As a user, I want incomplete required inventory to block affected writes, so that uncertainty is not presented as uniqueness.
14. As a user, I want occupied unmanaged destinations preserved, so that installation never becomes implicit adoption or takeover.
15. As a user, I want dry-run to show destination, link kind, target, ownership, and consumer effects without creating artifacts, so that I can review before applying.
16. As a user, I want linked-installation verification separated from target-content observations, so that edits to my source are not confused with edits to the owned entry.
17. As a user, I want changed or unverifiable owned links refused for replacement or removal, so that management never guesses ownership.
18. As a user, I want to remove an unchanged link whose target has changed, so that normal source editing does not trap the installation.
19. As a user, I want to remove an unchanged broken or inaccessible-target link without reading its target, so that cleanup remains possible and bounded.
20. As a user, I want ordinary removal to leave all source bytes and permissions untouched, so that uninstall cannot destroy my work.
21. As a user, I want replacement without an explicit mode to retain the existing mode, so that a link cannot silently become a copy.
22. As a user, I want explicit copy-to-link and link-to-copy replacement, so that I can intentionally change ownership models at the same managed location.
23. As a user, I want replacement and restore to retain installation identity, so that history remains tied to the recorded location.
24. As a user, I want a fresh installation after completed removal to get a new identity, so that unrelated installations are not conflated.
25. As a user, I want link backups to retain native kind, target representation, and original parent semantics, so that relative links can be restored correctly.
26. As a user, I want backup reports to state that target contents are not historical snapshots, so that I do not mistake link recovery for source version history.
27. As a user, I want normal restore to recheck current target validation and safety, so that old evidence cannot bypass current installation rules.
28. As a user recovering a failed transaction, I want a provable prior link entry restored even if its target later broke, so that rollback need not acquire target ownership.
29. As a user, I want backup cleanup to remove only verified manager-owned evidence, so that relocated relative links never cause target traversal or deletion.
30. As a Windows user, I want true directory symlinks and actionable privilege diagnostics, so that unsupported creation does not silently become a junction or copy.
31. As a Windows user, I want broken directory links to retain their directory-link kind during recovery, so that reconstruction does not accidentally create a file link.
32. As a user, I want existing junctions and unknown reparse forms reported but refused as mutation targets, so that coarse link classification is not treated as sufficient authority.
33. As a user, I want interrupted operations to preserve protected evidence and truthful failure states, so that recovery cannot overwrite a new occupant or erase later edits.
34. As a CLI user, I want success-only JSON and meaningful nonzero failures, so that automation distinguishes a plan, installation, failed restoration, and recovery requirement.
35. As a maintainer, I want each concrete command to own its retained inputs, so that I can understand one command without tracing a generic resource/operation factory.
36. As a maintainer, I want native Windows, macOS, and Linux workflow evidence, so that support claims reflect real link behavior rather than skipped or mocked capabilities.

## Implementation Decisions

### Command and module boundaries

- Extend the existing Skill install, adopt, replace, remove, list, backup, and recover paths. Do not add a command named lifecycle or a parallel link-management command tree.
- Use matching Mamba generators when introducing concrete commands or other supported declarations, wire every generated command into the production tree, and replace starter tests with behavior coverage. Only the production entry point uses Executor.create; command tests use Executor.fake.
- Each concrete command owns its private retained Mamba declarations, registers those exact handles, and reads them through valueOf. Eliminate the generic resource/operation-dispatched command factories for affected commands. Shared domain services may implement actual common operations; do not build another universal command class, input registry, or ResourceManager.
- Installation supports mode copy or link and defaults to copy. Replacement omission retains recorded mode; an explicit mode change is reviewed replacement, not migration or re-adoption. Adoption infers supported existing entry kind and never converts it. Reject a mode selector where the operation does not support it.
- Preserve user-default Skill scope, explicit destination on install/adopt, separator-terminated typed directory inputs, context overrides, and success-only output semantics. Relative operation paths resolve against selected cwd. No implicit shell expansion, elevation, prompts, or source execution.

### Entry-only ownership and native links

- Introduce a distinct linked-installation artifact with an entry baseline containing recorded location, supported native directory-link kind, observable target representation, and original parent context. Keep target validity/content observations separate from this owned baseline. Modification verification reports the owned entry and does not silently claim a target-content snapshot.
- New links point to the normalized absolute selected source location; no new relative-target CLI option is introduced. Adoption preserves an existing supported relative or absolute representation. Resolve relative targets using the original installation parent, including during backup verification and reconstruction.
- Support true POSIX directory symlinks and true Windows directory symlinks only. Establish the Windows reparse subtype and directory-link representation when required. Junctions, unknown reparse forms, linked native roots, internal links, ambiguous aliases/case authority, unsupported filesystems, and unverifiable physical ownership refuse affected writes. Do not infer physical identity from lowercased path strings.
- The authorized target traversal for install/adopt and applicable replacement/normal restore is read-only and bounded to the disclosed content tree. It does not authorize internal links, arbitrary recorded paths, or target mutation. Validate source/target identity and applicable native profiles; explicit Shared compatibility profiles remain independent of destination and consuming relationships.
- Recheck relevant name uniqueness, paths, ownership, and source observations before publication. Installation never merges with an occupied destination. Explicit copy/link conversion preserves location, scope, name, and installation ID; show the ownership change and retain the correct outgoing artifact backup. No conversion may overwrite either external target.
- Removal compares the owned link entry only. An unchanged broken, inaccessible, or content-drifted target is not a reason to read or delete it. Changed, missing, or unverifiable owned entries do not become successful removals. Required checks must be artifact-appropriate and cannot reintroduce target validation as a prerequisite to safe unlink.

### Records, backup, and recovery

- Version new artifact/record variants explicitly. Preserve reading of supported existing copied-Skill and regular-file Agent records. Unknown or incompatible schemas refuse without resetting ownership, coercing artifact kinds, or discarding evidence. Keep installation, occurrence, backup, transaction, and plan identities distinct and scope-safe.
- A retained link backup preserves entry kind and target representation with original-context evidence, not source bytes. Never follow a relocated saved relative link to validate or clean its target. If the required kind/representation cannot be reconstructed faithfully, refuse and preserve evidence.
- Normal restore returns the artifact to its original recorded location/identity, verifies backup/current owned state and current validation/uniqueness gates, and preserves outgoing state under artifact-appropriate rules. A new occupant is never overwritten. Failed-transaction rollback is distinct: it may restore a provable previous entry without target validation when the target has since drifted or broken.
- Use stable cooperating coordination, private same-filesystem preparation outside discovery roots, bounded intent records flushed before live mutation, safe quarantine/publication, observed-result verification, and evidence-backed recovery. No recursive link removal, cross-volume copy-delete fallback, rename-only claim of independent copied-content backup, or automatic backup pruning.
- Destructive replacement/removal/restore/cleanup/recovery require explicit approval; dry-run never does. Preserve outcomes 0 successful operation/plan, 1 invocation/general failure, 2 blocking correctness, 3 incomplete required work, 4 safety/ownership/approval refusal, 5 failed but restored, 6 recovery required or required cleanup pending, and 7 explicit cancellation. Handled failures use stderr without success JSON/stdout.
- Retain independent limits: Skill trees 10,000 entries/depth 32/64 MiB per ordinary file/256 MiB aggregate; discovery 64 ancestors/depth 16/20,000 entries/2,000 directories/64 MiB metadata; existing smaller Skill parser limits; management documents 8 MiB/depth 32/100,000 nodes and 64 MiB aggregate processed per transaction. Enforce during processing, never after unlimited allocation.

### Library recommendations

- **Reuse first:** Mamba for concrete command declarations and invocation; package:path for lexical path operations only; package:crypto for content/evidence hashes; package:test for acceptance and fault cases. These are already dependencies. Lexical paths and hashes are not physical authority or transaction guarantees.
- **Use dart:io where its contract is sufficient:** bounded ordinary IO, non-following enumeration, supported link operations, and cooperating file locks. Its coarse link type and Windows target-kind inference are not sufficient proof for every reparse, broken-link reconstruction, privacy, or path-identity requirement.
- **Conditional native adapter:** evaluate package:win32 6.4.0 with package:ffi 2.2.0 for the Windows operations actually needed. The examined win32 archive includes directory-symlink creation and reparse-control entry points, but not all required reparse structures, extended file-ID APIs, or ACL/security-descriptor APIs; supplemental focused FFI or a small native shim may be necessary. An absent target makes the SDK infer a Windows file link, so broken directory-link reconstruction needs explicit directory-kind creation and verification. Use dart:ffi/package:ffi for the small POSIX operations actually required, with OS-specific ABI/layout checks. Bind only proven missing capabilities; do not introduce a broad platform abstraction or make persisted OS IDs into eternal ownership tokens.
- Dependency additions are recommendations, not installations or support certification. Before adoption, pin compatible versions, inspect the exact APIs/source and licence, update the lockfile, and test the resulting artifact on every required native OS. SDK-only or package-based implementations must meet the same observed behavior; missing capability refuses or blocks qualification, never weakens the contract.

## Testing Decisions

- The user confirmed the seams: the production command tree through Executor.fake is the main acceptance boundary, using real isolated temporary filesystems. Add focused public-operation tests only for deterministic exceptional IO/forbidden-read assertions, and built-production executable smoke tests for actual wiring, streams, statuses, and platform behavior. Do not create a new testing framework or test private helper structure.
- Prior art is the existing concrete Agent inspection/validation command tests, Skill management public-operation fixtures, deterministic publication/journal/rollback failure tests, and isolated process support. Existing test presence or a capability skip is not evidence these new workflows work.
- Test all supported destinations by both scopes; copy default, explicit link installation, native relative-link adoption, separate target observations, mode-preserving replacement, both conversion directions, identity continuity, unchanged broken-link removal, and source preservation. Assert independently known bytes, entry kinds/target text, permissions where required, native state, management records, and untouched external sentinels.
- Test direct-child eligibility, linked/internal roots, Windows junction/unknown reparse refusal, aliases/case conflicts, occupied unmanaged entries, wrong-scope IDs, drift, corrupt/unsupported records, incomplete inventory, and budget boundaries. Controlled IO observations must prove forbidden target reads did not occur; unchanged target bytes alone do not prove no reads.
- Test relative-link backup/restore using original-parent semantics; source deletion and target drift; native directory-kind preservation for broken Windows links; backup tampering; normal restore validation refusal versus safe failed-transaction rollback; repeated recovery; partial cleanup; and new occupants. Backup existence alone never proves restoration.
- Inject deterministic failures before/after staging, intent flush, backup, quarantine, publication, verification, record commit, restoration, and cleanup. Assert truthful no-live-change, failed-restored, recovery-required, committed-cleanup-pending, and normal-retention outcomes; reconstruction must use persisted evidence, not process memory.
- Through the real command tree, assert complete result variant/code/output or diagnostic/phase/canonical path, accepted/rejected inputs, help without domain effects, approval/cancellation, JSON/interactivity conflicts, and reuse without leaked operation state. No direct command.run tests.
- Run native Windows/macOS/Linux jobs on the selected release Dart SDK with the committed lockfile. Each requires positive true-directory-link workflows plus measured capability/refusal cases and actual built-executable positive/refusal smoke; junction fallback, WSL/emulation, source-script-only smoke, or green skips cannot substitute. Rare real statuses 5/6 may be demonstrated on capable native jobs; release evidence still covers real statuses 0–7 overall. Do not execute resources or native harnesses.
- Completion requires behavior-to-test traceability, formatting, analysis, focused/full suites, and retained revision/SDK/dependency/OS/filesystem/capability/job evidence. Missing mandatory positives/privacy/link capability evidence or unresolved safety/flaky cases blocks support/release claims.

## Out of Scope

Agent link installation; linked native/configuration roots; junction support or automatic link-to-copy fallback; recursive target ownership; source version history; remote acquisition/updates; automatic elevation; broad rebaseline/migration; parent-configuration mutation; composition/conversion; resource or harness execution; hostile-writer resistance; guaranteed power-loss durability; universal metadata cloning or secure erasure.

## Further Notes

- Companion specification: [checkpoint 6 — parent setting units and bound-role mutations](https://github.com/louiss0/agent_resource/issues/31). Parent-unit ownership is separate from entry-only Skill-link ownership; shared guards do not imply a universal ownership model.
- This request authorizes preparing and publishing a specification, not starting application implementation or claiming previous work is verified. Verify and reconcile the prerequisite copy/adoption/backup/recovery baseline without discarding unrelated dirty work. The prior generic command factories are not the required architecture.
- Recorded requirement sources: [roadmap checkpoint 5](https://github.com/louiss0/agent_resource/issues/9#issuecomment-6372825515), [Skill safety](https://github.com/louiss0/agent_resource/issues/6#issuecomment-6355083836), [Skills CLI](https://github.com/louiss0/agent_resource/issues/7#issuecomment-6355388745), and [integrated acceptance](https://github.com/louiss0/agent_resource/issues/8#issuecomment-6372675309). These are traceability references, not independent proof of unrecorded conversations or implementation authorization.
- Library primary sources: [pinned SDK Link API](https://github.com/dart-lang/sdk/blob/60a57cd42d64dc03e9f07aa60a2e250755c1ef28/sdk/lib/io/link.dart), [Windows SDK implementation](https://github.com/dart-lang/sdk/blob/60a57cd42d64dc03e9f07aa60a2e250755c1ef28/runtime/bin/file_win.cc), [win32 6.4.0 published source](https://pub.dev/api/archives/win32-6.4.0.tar.gz), [ffi 2.2.0 source](https://pub.dev/api/archives/ffi-2.2.0.tar.gz), [Windows directory-symlink creation](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createsymboliclinkw), and [POSIX symlink contract](https://pubs.opengroup.org/onlinepubs/9799919799/functions/symlink.html). Research was retrieved 2026-10-26. Declared SDK compatibility is not dependency-resolution or native-runtime proof. The separate checkpoint library research note records exact coverage and gaps.
