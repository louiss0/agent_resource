import 'package:agent_resource/src/conversion/path_action_diff.dart';
import 'package:path/path.dart' as p;

/// The journal-form action rows a real route migration records for the
/// supplied path ownership.
///
/// A journal's `actions[].path` is the diff's normalized key — case-folded
/// on Windows and left verbatim elsewhere — so building rows through the
/// real diff keeps the fixture honest on case-sensitive filesystems
/// instead of folding paths in the test.
List<Map<String, Object?>> journalActions(
  p.Context paths, {
  required Iterable<OldArtifactPath> oldPaths,
  required Iterable<NewArtifactPath> newPaths,
}) => <Map<String, Object?>>[
  for (final action in PathActionDiff(paths).compare(
    oldPaths: oldPaths,
    newPaths: newPaths,
    occupiedPaths: const <String>[],
  ))
    <String, Object?>{
      'path': action.path,
      'oldKind': action.oldKind?.name,
      'newKind': action.newKind?.name,
    },
];
