import 'dart:convert';
import 'dart:io' show FileSystemEntityType;

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../authoring/authoring_receipt.dart';
import '../authoring/authoring_transaction.dart';
import '../context/context_combine.dart';
import '../context/context_target_resolution.dart';
import '../context/context_template_store.dart';
import '../context/context_types.dart';
import 'instruction_draft_service.dart';
import 'lifecycle_state_service.dart';

/// The observed and proposed state of one deduplicated injection target.
final class const ContextInjectionTarget({
  required final String path,
  required final List<ContextHarness> harnesses,
  required final ContextVariant variant,
  required final ContextCombineAction action,
  required final bool existingExists,
  required final String? existingSha256,
  required final int existingByteLength,
  required final String proposedSha256,
  required final int proposedByteLength,
  required final String existingContent,
  required final String proposedContent,
  final String? receiptId,
  final String? recoveryPath,
}) {
  ContextInjectionTarget withEvidence({
    required String receiptId,
    required String? recoveryPath,
  }) => ContextInjectionTarget(
    path: path,
    harnesses: harnesses,
    variant: variant,
    action: action,
    existingExists: existingExists,
    existingSha256: existingSha256,
    existingByteLength: existingByteLength,
    proposedSha256: proposedSha256,
    proposedByteLength: proposedByteLength,
    existingContent: existingContent,
    proposedContent: proposedContent,
    receiptId: receiptId,
    recoveryPath: recoveryPath,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'harnesses': <String>[for (final harness in harnesses) harness.name],
    'variant': variant.wireName,
    'action': action.name,
    'existingExists': existingExists,
    'existingSha256': existingSha256,
    'existingByteLength': existingByteLength,
    'proposedSha256': proposedSha256,
    'proposedByteLength': proposedByteLength,
    'receiptId': receiptId,
    'recoveryPath': recoveryPath,
  };
}

/// The reviewed injection request and its deduplicated target evidence.
final class const ContextInjectionPlan({
  required final String planId,
  required final String templateName,
  required final ContextTemplateMetadata template,
  required final String targetDirectory,
  required final ContextScope scope,
  required final List<ContextHarness> harnesses,
  required final ContextVariant variant,
  required final bool replace,
  required final List<ContextInjectionTarget> targets,
  final String? content,
}) {
  ContextInjectionPlan withEvidence(
    List<ContextInjectionTarget> publishedTargets,
  ) => ContextInjectionPlan(
    planId: planId,
    templateName: templateName,
    template: template,
    targetDirectory: targetDirectory,
    scope: scope,
    harnesses: harnesses,
    variant: variant,
    replace: replace,
    targets: publishedTargets,
    content: content,
  );

  Map<String, Object?> toData() => <String, Object?>{
    'planId': planId,
    'templateName': templateName,
    'template': template.toJson(),
    'targetDirectory': targetDirectory,
    'scope': scope.name,
    'harnesses': <String>[for (final harness in harnesses) harness.name],
    'variant': variant.wireName,
    'replace': replace,
    'targets': <Object?>[for (final target in targets) target.toJson()],
    if (content != null) 'content': content,
  };
}

/// Plans and publishes raw Markdown context-file injections.
final class ContextInjectionService {
  ContextInjectionService({
    fslib.FileSystem? fileSystem,
    ContextTemplateStore? templates,
  }) : fileSystem = fileSystem ?? const local.LocalFileSystem(),
       _templates =
           templates ??
           ContextTemplateStore(
             fileSystem: fileSystem ?? const local.LocalFileSystem(),
           );

  final fslib.FileSystem fileSystem;
  final ContextTemplateStore _templates;
  late final ContextTargetResolver _resolver = ContextTargetResolver(
    fileSystem: fileSystem,
  );

  /// Observes the template and every target without changing the filesystem.
  ContextInjectionPlan plan({
    required LifecycleOptions options,
    required String templateName,
    required List<ContextHarness> harnesses,
    required ContextScope scope,
    required ContextVariant variant,
    required String? folder,
    required bool replace,
    bool showInstructions = false,
  }) {
    final context = LifecycleContext.resolve(options, fileSystem: fileSystem);
    final targetDirectory = _targetDirectory(context, scope, folder);
    final resolved = _resolver.resolve(
      context: context,
      harnesses: harnesses,
      scope: scope,
      variant: variant,
      targetDirectory: targetDirectory,
    );
    final template = _templates.inspect(options, templateName);
    final targets = <ContextInjectionTarget>[];
    for (final target in resolved) {
      final observed = _observe(target.path);
      final proposed = const ContextCombine().call(
        existingContent: observed.content,
        content: template.content,
        replace: replace,
      );
      final proposedBytes = utf8.encode(proposed);
      targets.add(
        ContextInjectionTarget(
          path: target.path,
          harnesses: target.harnesses,
          variant: variant,
          action: !observed.exists
              ? ContextCombineAction.create
              : replace
              ? ContextCombineAction.replace
              : ContextCombineAction.append,
          existingExists: observed.exists,
          existingSha256: observed.sha256,
          existingByteLength: observed.byteLength,
          proposedSha256: sha256.convert(proposedBytes).toString(),
          proposedByteLength: proposedBytes.length,
          existingContent: observed.content ?? '',
          proposedContent: proposed,
        ),
      );
    }
    final request = <String, Object?>{
      'templateName': templateName,
      'scope': scope.name,
      'targetDirectory': targetDirectory,
      'harnesses': <String>[
        for (final harness in ContextHarness.values)
          if (harnesses.contains(harness)) harness.name,
      ],
      'variant': variant.wireName,
      'replace': replace,
      'source': <String, Object?>{
        'sha256': template.metadata.sha256,
        'byteLength': template.metadata.byteLength,
      },
      'targets': <Object?>[for (final target in targets) target.toJson()],
    };
    final digest = sha256.convert(
      utf8.encode(jsonEncode(canonicalAuthoringJson(request))),
    );
    return ContextInjectionPlan(
      planId: 'pln_$digest',
      templateName: templateName,
      template: template.metadata,
      targetDirectory: targetDirectory,
      scope: scope,
      harnesses: harnesses,
      variant: variant,
      replace: replace,
      targets: targets,
      content: showInstructions ? template.content : null,
    );
  }

  /// Re-observes the plan and publishes each reviewed target atomically.
  ContextInjectionPlan publish({
    required LifecycleOptions options,
    required ContextInjectionPlan reviewed,
    required String? suppliedPlanId,
  }) {
    final current = plan(
      options: options,
      templateName: reviewed.templateName,
      harnesses: reviewed.harnesses,
      scope: reviewed.scope,
      variant: reviewed.variant,
      folder: reviewed.scope == ContextScope.project
          ? reviewed.targetDirectory
          : null,
      replace: reviewed.replace,
      showInstructions: reviewed.content != null,
    );
    if (current.planId != reviewed.planId) {
      throw MambaException(
        'CONTEXT_PLAN_DRIFT: The template or a target changed after the '
        'plan was reviewed.',
        exitCode: 4,
      );
    }
    if (suppliedPlanId != null && suppliedPlanId != current.planId) {
      throw MambaException(
        'STALE_CONTEXT_PLAN: The supplied plan id does not match the '
        'current request.',
        exitCode: 4,
      );
    }
    _requireSameEvidence(reviewed, current);

    final context = LifecycleContext.resolve(options, fileSystem: fileSystem);
    final stateRoot = context.stateRoot(LifecycleScope.user);
    final state = LifecycleStateService(io: LifecycleIO(fs: fileSystem));
    final published = <ContextInjectionTarget>[];
    for (final target in current.targets) {
      final key = sha256.convert(utf8.encode(target.path)).toString();
      final recoveryPath = target.action == ContextCombineAction.create
          ? null
          : fileSystem.path.join(
              stateRoot,
              authoringRecoveryDirectoryName,
              reviewed.planId,
              '$key.md',
            );
      if (recoveryPath != null) {
        state.writeProtectedDocument(
          recoveryPath,
          utf8.encode(target.existingContent),
        );
      }
      final staged = fileSystem.path.join(
        stateRoot,
        authoringStagingDirectoryName,
        reviewed.planId,
        '$key.candidate',
      );
      state.io.createDirectory(fileSystem.path.dirname(staged));
      final bytes = utf8.encode(target.proposedContent);
      state.io.write(staged, bytes);
      final stagedBytes = state.io.read(staged, bytes.length + 1);
      if (sha256.convert(stagedBytes).toString() != target.proposedSha256) {
        throw MambaException(
          'STAGING_DIGEST_MISMATCH: Staged bytes do not match the reviewed '
          'plan.',
          exitCode: 4,
        );
      }
      state.io.createDirectory(fileSystem.path.dirname(target.path));
      state.io.rename(staged, target.path);
      final receiptId = authoringReceiptId(reviewed.planId, target.path);
      writeAuthoringReceipt(
        state: state,
        stateRoot: stateRoot,
        document: authoringReceiptDocument(
          receiptId: receiptId,
          planId: reviewed.planId,
          operation: 'contextInject',
          kind: 'contextFile',
          profile: target.variant.wireName,
          target: target.path,
          root: reviewed.scope.name,
          form: fileSystem.path.basename(target.path),
        ),
      );
      published.add(
        target.withEvidence(receiptId: receiptId, recoveryPath: recoveryPath),
      );
    }
    return current.withEvidence(published);
  }

  void _requireSameEvidence(
    ContextInjectionPlan reviewed,
    ContextInjectionPlan current,
  ) {
    if (reviewed.template.sha256 != current.template.sha256 ||
        reviewed.template.byteLength != current.template.byteLength) {
      throw MambaException(
        'CONTEXT_PLAN_DRIFT: The context template changed after planning.',
        exitCode: 4,
      );
    }
    if (reviewed.targets.length != current.targets.length) {
      throw MambaException(
        'CONTEXT_PLAN_DRIFT: The reviewed target set changed.',
        exitCode: 4,
      );
    }
    for (var index = 0; index < reviewed.targets.length; index++) {
      final before = reviewed.targets[index];
      final after = current.targets[index];
      if (before.path != after.path ||
          before.action != after.action ||
          before.existingSha256 != after.existingSha256 ||
          before.existingByteLength != after.existingByteLength ||
          before.proposedSha256 != after.proposedSha256 ||
          before.proposedByteLength != after.proposedByteLength) {
        throw MambaException(
          'CONTEXT_PLAN_DRIFT: Target ${after.path} changed after planning.',
          exitCode: 4,
        );
      }
    }
  }

  String _decode(List<int> bytes, String path) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw MambaException(
        'INVALID_TARGET_UTF8: Context file is not UTF-8: $path',
        exitCode: 4,
      );
    }
  }

  String _targetDirectory(
    LifecycleContext context,
    ContextScope scope,
    String? folder,
  ) {
    if (folder == null) {
      return scope == ContextScope.project
          ? context.projectRoot
          : context.stateRoot(LifecycleScope.user);
    }
    if (scope != ContextScope.project) {
      throw MambaException(
        'FOLDER_SCOPE_CONFLICT: --folder is only valid with --scope project.',
        exitCode: 4,
      );
    }
    final root = context.projectRoot;
    final candidate = context.resolvePath(folder);
    if (candidate != root && !fileSystem.path.isWithin(root, candidate)) {
      throw MambaException(
        'FOLDER_OUTSIDE_PROJECT: Folder escapes the project root: $candidate',
        exitCode: 4,
      );
    }
    final relative = fileSystem.path.relative(candidate, from: root);
    var current = root;
    for (final segment in relative.split(fileSystem.path.separator)) {
      if (segment.isEmpty || segment == '.') continue;
      current = fileSystem.path.join(current, segment);
      final type = fileSystem.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw MambaException(
          'SYMLINK_REFUSED: Folder path traverses a link: $current',
          exitCode: 4,
        );
      }
      if (type == FileSystemEntityType.notFound) {
        throw MambaException(
          'FOLDER_NOT_FOUND: Folder does not exist: $current',
          exitCode: 4,
        );
      }
      if (type != FileSystemEntityType.directory) {
        throw MambaException(
          'FOLDER_NOT_DIRECTORY: Folder path is not a directory: $current',
          exitCode: 4,
        );
      }
    }
    return candidate;
  }

  ({bool exists, String? sha256, int byteLength, String? content}) _observe(
    String path,
  ) {
    final type = fileSystem.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw MambaException(
        'SYMLINK_REFUSED: Context file is a link: $path',
        exitCode: 4,
      );
    }
    if (type == FileSystemEntityType.notFound) {
      return (exists: false, sha256: null, byteLength: 0, content: null);
    }
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'NON_REGULAR_TARGET_REFUSED: Context file is not a regular file: $path',
        exitCode: 4,
      );
    }
    final bytes = LifecycleIO(fs: fileSystem)
        .read(path, maxInstructionDraftBodyBytes);
    if (bytes.length > maxInstructionDraftBodyBytes) {
      throw MambaException(
        'TARGET_TOO_LARGE: Context file exceeds the 1 MiB limit: $path',
        exitCode: 4,
      );
    }
    return (
      exists: true,
      sha256: sha256.convert(bytes).toString(),
      byteLength: bytes.length,
      content: _decode(bytes, path),
    );
  }
}
