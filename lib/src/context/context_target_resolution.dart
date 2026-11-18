import 'package:file/file.dart' as fslib;
import 'package:mamba/mamba.dart';

import 'context_types.dart';
import '../services/lifecycle_state_service.dart';

/// One deduplicated context file target and the harnesses that consume it.
final class const ContextTargetResolution({
  required final String path,
  required final List<ContextHarness> harnesses,
  required final ContextScope scope,
  required final ContextVariant variant,
  required final String targetDirectory,
}) {
  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'harnesses': <String>[for (final harness in harnesses) harness.name],
    'scope': scope.name,
    'variant': variant.wireName,
    'targetDirectory': targetDirectory,
  };
}

/// Resolves the strict harness/scope/variant matrix into unique target paths.
final class ContextTargetResolver {
  const ContextTargetResolver({required this.fileSystem});

  final fslib.FileSystem fileSystem;

  /// Returns targets in deterministic harness order, deduplicated by path.
  List<ContextTargetResolution> resolve({
    required LifecycleContext context,
    required Iterable<ContextHarness> harnesses,
    required ContextScope scope,
    required ContextVariant variant,
    required String targetDirectory,
  }) {
    final resolved = <String, ContextTargetResolution>{};
    for (final harness in ContextHarness.values) {
      if (!harnesses.contains(harness)) continue;
      final path = fileSystem.path.normalize(
        resolveContextTargetPath(
          context: context,
          harness: harness,
          scope: scope,
          variant: variant,
          projectTargetDir: targetDirectory,
        ),
      );
      final existing = resolved[path];
      if (existing == null) {
        resolved[path] = ContextTargetResolution(
          path: path,
          harnesses: <ContextHarness>[harness],
          scope: scope,
          variant: variant,
          targetDirectory: targetDirectory,
        );
      } else {
        resolved[path] = ContextTargetResolution(
          path: existing.path,
          harnesses: <ContextHarness>[...existing.harnesses, harness],
          scope: scope,
          variant: variant,
          targetDirectory: targetDirectory,
        );
      }
    }
    return resolved.values.toList(growable: false);
  }
}

/// Resolves one supported `(harness, scope, variant)` tuple to a path.
///
/// Every unsupported tuple refuses the whole invocation with exit code 4.
String resolveContextTargetPath({
  required LifecycleContext context,
  required ContextHarness harness,
  required ContextScope scope,
  required ContextVariant variant,
  required String projectTargetDir,
}) {
  final p = context.fs.path;
  return switch ((harness, scope, variant)) {
    (ContextHarness.claude, ContextScope.project, ContextVariant.standard) =>
      p.join(projectTargetDir, 'CLAUDE.md'),
    (ContextHarness.claude, ContextScope.project, ContextVariant.local) =>
      p.join(projectTargetDir, 'CLAUDE.local.md'),
    (ContextHarness.claude, ContextScope.project, ContextVariant.dotClaude) =>
      p.join(projectTargetDir, '.claude', 'CLAUDE.md'),
    (ContextHarness.claude, ContextScope.user, ContextVariant.standard) =>
      p.join(context.claudeConfigRoot(), 'CLAUDE.md'),
    (ContextHarness.codex, ContextScope.project, ContextVariant.standard) =>
      p.join(projectTargetDir, 'AGENTS.md'),
    (ContextHarness.codex, ContextScope.project, ContextVariant.override) =>
      p.join(projectTargetDir, 'AGENTS.override.md'),
    (ContextHarness.codex, ContextScope.user, ContextVariant.standard) =>
      p.join(context.codexRoot(), 'AGENTS.md'),
    (ContextHarness.codex, ContextScope.user, ContextVariant.override) =>
      p.join(context.codexRoot(), 'AGENTS.override.md'),
    (ContextHarness.pi, ContextScope.project, ContextVariant.standard) =>
      p.join(projectTargetDir, 'AGENTS.md'),
    (ContextHarness.pi, ContextScope.project, ContextVariant.override) =>
      p.join(projectTargetDir, 'AGENTS.override.md'),
    (ContextHarness.pi, ContextScope.user, ContextVariant.standard) => p.join(
      context.piAgentRoot(),
      'AGENTS.md',
    ),
    (ContextHarness.pi, ContextScope.user, ContextVariant.override) => p.join(
      context.piAgentRoot(),
      'AGENTS.override.md',
    ),
    _ => throw MambaException(
      'UNSUPPORTED_CONTEXT_VARIANT: Variant "${variant.wireName}" is not '
      'supported for harness "${harness.name}" at ${scope.name} scope.',
      exitCode: 4,
    ),
  };
}
