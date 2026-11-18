import 'dart:convert';
import 'dart:io' show FileSystemEntityType;

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../authoring/authoring_transaction.dart';
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
  final String? receiptId,
  final String? recoveryPath,
}) {
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
    if (receiptId != null) 'receiptId': receiptId,
    if (recoveryPath != null) 'recoveryPath': recoveryPath,
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
    final templateBytes = utf8.encode(template.content);
    final proposedDigest = sha256.convert(templateBytes).toString();
    final targets = <ContextInjectionTarget>[];
    for (final target in resolved) {
      final observed = _observe(target.path);
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
          proposedSha256: proposedDigest,
          proposedByteLength: templateBytes.length,
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

  ({bool exists, String? sha256, int byteLength}) _observe(String path) {
    final type = fileSystem.typeSync(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw MambaException(
        'SYMLINK_REFUSED: Context file is a link: $path',
        exitCode: 4,
      );
    }
    if (type == FileSystemEntityType.notFound) {
      return (exists: false, sha256: null, byteLength: 0);
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
    );
  }
}
