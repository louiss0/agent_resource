import 'package:path/path.dart' as p;

/// The kind of an artifact owned at an old path.
enum OldArtifactKind {
  skillCopy,
  skillLink,
  skillCanonical,
  agentFile,
  promptTemplate,
}

/// The kind of an artifact proposed at a new path.
enum NewArtifactKind {
  skillCopy,
  skillLink,
  skillCanonical,
  agentFile,
  promptTemplate,
}

typedef OldArtifactPath = ({String path, OldArtifactKind kind});
typedef NewArtifactPath = ({String path, NewArtifactKind kind});

/// A path's old and new ownership; null means no artifact on that side.
typedef PathAction = ({
  String path,
  OldArtifactKind? oldKind,
  NewArtifactKind? newKind,
});

/// Computes lexical path actions from caller-supplied ownership and observations.
///
/// This does not establish ownership, inspect the filesystem, or authorize
/// publication. Inputs must be absolute; keys are normalized lexically and
/// case-folded for Windows. Each occupied new path must also be an old path.
/// Common paths are included even when their kinds match: content is unknown.
final class PathActionDiff(final p.Context paths) {
  List<PathAction> compare({
    required Iterable<OldArtifactPath> oldPaths,
    required Iterable<NewArtifactPath> newPaths,
    required Iterable<String> occupiedPaths,
  }) {
    final old = <String, OldArtifactKind>{};
    final next = <String, NewArtifactKind>{};
    final occupied = <String>{};
    for (final entry in oldPaths) {
      final key = _key(entry.path);
      if (old.containsKey(key)) throw ArgumentError('Duplicate old path: $key');
      old[key] = entry.kind;
    }
    for (final entry in newPaths) {
      final key = _key(entry.path);
      if (next.containsKey(key)) {
        throw ArgumentError('Duplicate new path: $key');
      }
      next[key] = entry.kind;
    }
    for (final path in occupiedPaths) {
      final key = _key(path);
      if (!occupied.add(key)) {
        throw ArgumentError('Duplicate occupied path: $key');
      }
    }
    for (final key in next.keys) {
      if (occupied.contains(key) && !old.containsKey(key)) {
        throw ArgumentError('Occupied new path is not owned: $key');
      }
    }
    return List.unmodifiable([
      for (final key in {...old.keys, ...next.keys})
        (path: key, oldKind: old[key], newKind: next[key]),
    ]);
  }

  String _key(String value) {
    if (!paths.isAbsolute(value)) {
      throw ArgumentError.value(value, 'path', 'Must be absolute');
    }
    final normalized = paths.normalize(value);
    return paths.style == p.Style.windows
        ? normalized.toLowerCase()
        : normalized;
  }
}
