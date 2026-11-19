import 'package:file/file.dart' as fslib;

import '../harness/harness_catalog.dart';
import '../services/lifecycle_state_service.dart';
import 'context_types.dart';

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
/// The `ContextHarnessSpec` facet on the harness's descriptor is the single
/// authority for the path algorithm; an unsupported facet or tuple refuses
/// the whole invocation with exit code 4 before any target is written.
String resolveContextTargetPath({
  required LifecycleContext context,
  required ContextHarness harness,
  required ContextScope scope,
  required ContextVariant variant,
  required String projectTargetDir,
}) {
  final id = HarnessId.fromWire(harness.name);
  final catalog = HarnessCatalog.instance;
  final spec = catalog.byId(id).context;
  if (spec == null) {
    throw catalog.refusal(id, HarnessFacet.context)!.toException();
  }
  return spec.resolveTargetPath(
    context: context,
    scope: scope,
    variant: variant,
    projectTargetDir: projectTargetDir,
  );
}
