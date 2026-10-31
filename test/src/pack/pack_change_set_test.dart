import 'package:agent_resource/src/pack/pack_change_set.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:test/test.dart';

BaselineEntry entry(
  String path,
  String digest, {
  int length = 1,
  bool executable = false,
}) => BaselineEntry(
  path: path,
  type: 'file',
  length: length,
  sha256: digest,
  executable: executable,
  readOnly: false,
);

void main() {
  group(PackChangeSet, () {
    test('reports additions, modifications, removals, and attributes', () {
      final before = ArtifactBaseline([
        entry('removed.txt', 'a'),
        entry('changed.txt', 'b'),
        entry('mode.txt', 'c'),
        entry('unchanged.txt', 'd'),
      ]);
      final after = ArtifactBaseline([
        entry('added.txt', 'e'),
        entry('changed.txt', 'f'),
        entry('mode.txt', 'c', executable: true),
        entry('unchanged.txt', 'd'),
      ]);

      final changes = PackChangeSet.between(before, after);

      expect(changes.map((change) => (change.path, change.change)), [
        ('added.txt', 'added'),
        ('changed.txt', 'modified'),
        ('mode.txt', 'modified'),
        ('removed.txt', 'removed'),
      ]);
    });
  });
}
