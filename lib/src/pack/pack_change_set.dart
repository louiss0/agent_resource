import '../services/lifecycle_state_service.dart';
import 'pack_models.dart';

/// Computes the complete path-level review between two installation baselines.
final class const PackChangeSet() {
  static List<PackChangedPath> between(
    ArtifactBaseline? before,
    ArtifactBaseline? after,
  ) {
    final previous = <String, BaselineEntry>{
      for (final entry in before?.entries ?? const <BaselineEntry>[])
        if (entry.type != 'directory') entry.path: entry,
    };
    final next = <String, BaselineEntry>{
      for (final entry in after?.entries ?? const <BaselineEntry>[])
        if (entry.type != 'directory') entry.path: entry,
    };
    final changes = <PackChangedPath>[];
    for (final path in {...previous.keys, ...next.keys}.toList()..sort()) {
      final old = previous[path];
      final current = next[path];
      if (old == null) {
        changes.add(PackChangedPath(path: path, change: 'added'));
        continue;
      }
      if (current == null) {
        changes.add(PackChangedPath(path: path, change: 'removed'));
        continue;
      }
      if (old.type != current.type ||
          old.length != current.length ||
          old.sha256 != current.sha256 ||
          old.executable != current.executable ||
          old.readOnly != current.readOnly ||
          old.target != current.target ||
          old.nativeKind != current.nativeKind) {
        changes.add(PackChangedPath(path: path, change: 'modified'));
      }
    }
    return List<PackChangedPath>.unmodifiable(changes);
  }
}
