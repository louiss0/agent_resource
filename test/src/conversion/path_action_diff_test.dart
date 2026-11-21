import 'package:agent_resource/src/conversion/path_action_diff.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('same path kind change keeps separately typed old and new kinds', () {
    final actions = PathActionDiff(p.Context(style: p.Style.posix)).compare(
      oldPaths: [(path: '/old/item', kind: OldArtifactKind.skillCopy)],
      newPaths: [(path: '/old/./item', kind: NewArtifactKind.agentFile)],
      occupiedPaths: ['/old/item'],
    );

    expect(actions, [
      (
        path: '/old/item',
        oldKind: OldArtifactKind.skillCopy,
        newKind: NewArtifactKind.agentFile,
      ),
    ]);
  });

  test('cross-root move emits removal and addition', () {
    final actions = PathActionDiff(p.Context(style: p.Style.posix)).compare(
      oldPaths: [(path: '/first/item', kind: OldArtifactKind.skillCopy)],
      newPaths: [(path: '/second/item', kind: NewArtifactKind.skillLink)],
      occupiedPaths: ['/first/item'],
    );
    expect(actions, [
      (path: '/first/item', oldKind: OldArtifactKind.skillCopy, newKind: null),
      (path: '/second/item', oldKind: null, newKind: NewArtifactKind.skillLink),
    ]);
  });

  test('refuses an occupied unowned new path', () {
    expect(
      () => PathActionDiff(p.Context(style: p.Style.posix)).compare(
        oldPaths: [(path: '/first/item', kind: OldArtifactKind.skillCopy)],
        newPaths: [(path: '/second/item', kind: NewArtifactKind.skillLink)],
        occupiedPaths: ['/second/./item'],
      ),
      throwsArgumentError,
    );
  });

  test('rejects duplicates after normalization in each input', () {
    final diff = PathActionDiff(p.Context(style: p.Style.windows));
    expect(
      () => diff.compare(
        oldPaths: [
          (path: r'C:\A\item', kind: OldArtifactKind.skillCopy),
          (path: r'c:\a\.\ITEM', kind: OldArtifactKind.agentFile),
        ],
        newPaths: [],
        occupiedPaths: [],
      ),
      throwsArgumentError,
    );
    expect(
      () => diff.compare(
        oldPaths: [],
        newPaths: [
          (path: r'C:\A\item', kind: NewArtifactKind.skillCopy),
          (path: r'c:\a\ITEM', kind: NewArtifactKind.agentFile),
        ],
        occupiedPaths: [],
      ),
      throwsArgumentError,
    );
    expect(
      () => diff.compare(
        oldPaths: [],
        newPaths: [],
        occupiedPaths: [r'C:\A\item', r'c:\a\ITEM'],
      ),
      throwsArgumentError,
    );
  });

  test('requires absolute paths and includes unchanged ownership', () {
    final diff = PathActionDiff(p.Context(style: p.Style.posix));
    expect(
      () =>
          diff.compare(oldPaths: [], newPaths: [], occupiedPaths: ['relative']),
      throwsArgumentError,
    );
    expect(
      diff.compare(
        oldPaths: [(path: '/a', kind: OldArtifactKind.skillCopy)],
        newPaths: [(path: '/a', kind: NewArtifactKind.skillCopy)],
        occupiedPaths: ['/a'],
      ),
      [
        (
          path: '/a',
          oldKind: OldArtifactKind.skillCopy,
          newKind: NewArtifactKind.skillCopy,
        ),
      ],
    );
  });
}
