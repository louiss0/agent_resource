import 'package:agent_resource/src/pack/release_policy.dart';
import 'package:test/test.dart';

void main() {
  group(SemanticVersion, () {
    test('parses strict SemVer and preserves its components', () {
      final version = SemanticVersion.parse('v1.2.3-alpha.1+build.5');

      expect(version.major, 1);
      expect(version.minor, 2);
      expect(version.patch, 3);
      expect(version.prerelease, ['alpha', '1']);
      expect(version.build, ['build', '5']);
      expect(version.isPrerelease, isTrue);
    });

    test('accepts only one optional lowercase v', () {
      expect(SemanticVersion.parse('1.2.3').major, 1);
      expect(SemanticVersion.parse('v1.2.3').major, 1);

      for (final literal in ['V1.2.3', 'vv1.2.3', ' v1.2.3', 'v1.2.3 ']) {
        expect(() => SemanticVersion.parse(literal), throwsFormatException);
      }
    });

    test('rejects malformed numeric, prerelease, and build identifiers', () {
      final invalid = [
        '1.2',
        '1.2.3.4',
        '01.2.3',
        '1.02.3',
        '1.2.03',
        '1.2.3-',
        '1.2.3-alpha..1',
        '1.2.3-01',
        '1.2.3+',
        '1.2.3+build..1',
        '1.2.3-alpha_1',
        '1.2.3+build_1',
      ];

      for (final literal in invalid) {
        expect(
          () => SemanticVersion.parse(literal),
          throwsFormatException,
          reason: literal,
        );
      }
    });

    test('orders prereleases by SemVer precedence', () {
      final ordered = [
        '1.0.0-alpha',
        '1.0.0-alpha.1',
        '1.0.0-alpha.beta',
        '1.0.0-beta',
        '1.0.0-beta.2',
        '1.0.0-beta.11',
        '1.0.0-rc.1',
        '1.0.0',
      ].map(SemanticVersion.parse).toList();

      for (var index = 1; index < ordered.length; index++) {
        expect(ordered[index - 1].compareTo(ordered[index]), lessThan(0));
      }
    });

    test('ignores build metadata for precedence', () {
      final first = SemanticVersion.parse('1.2.3+first');
      final second = SemanticVersion.parse('v1.2.3+second');

      expect(first.compareTo(second), 0);
    });
  });

  group(ReleasePolicy, () {
    const policy = ReleasePolicy(bump: ReleaseBump.minor);
    final current = release('1.2.3');

    test('requires exact literal selection for first installation', () {
      expect(
        () => policy.select(candidates: [release('2.0.0')]),
        throwsA(isA<ReleaseSelectionException>()),
      );

      final selected = policy.select(
        candidates: [release('2.0.0')],
        exactTag: '2.0.0',
      );
      expect(selected.literalTag, '2.0.0');
    });

    test('requires exact selection for a non-SemVer current release', () {
      expect(
        () => policy.select(
          current: release('2026-10-30'),
          candidates: [release('2.0.0')],
        ),
        throwsA(isA<ReleaseSelectionException>()),
      );
    });

    test('selects only higher versions within the bump range', () {
      final selected = policy.select(
        current: current,
        candidates: [
          release('1.2.4'),
          release('1.3.0'),
          release('1.4.0'),
          release('2.0.0'),
          release('1.2.3'),
          release('1.1.9'),
        ],
      );

      expect(selected.literalTag, '1.4.0');
    });

    test('patch keeps major and minor fixed', () {
      const patch = ReleasePolicy(bump: ReleaseBump.patch);

      final selected = patch.select(
        current: current,
        candidates: [release('1.2.4'), release('1.3.0'), release('2.0.0')],
      );

      expect(selected.literalTag, '1.2.4');
    });

    test('major allows any strictly higher version including zero major', () {
      const major = ReleasePolicy(bump: ReleaseBump.major);

      final selected = major.select(
        current: release('0.2.3'),
        candidates: [release('0.2.4'), release('0.3.0'), release('1.0.0')],
      );

      expect(selected.literalTag, '1.0.0');
    });

    test(
      'excludes prereleases unless either prerelease signal is opted in',
      () {
        final candidates = [
          release('1.3.0'),
          release('1.4.0-rc.1'),
          release('1.5.0', prerelease: true),
        ];

        expect(
          policy.select(current: current, candidates: candidates).literalTag,
          '1.3.0',
        );

        const included = ReleasePolicy(
          bump: ReleaseBump.minor,
          includePrerelease: true,
        );
        expect(
          included.select(current: current, candidates: candidates).literalTag,
          '1.5.0',
        );
      },
    );

    test('never automatically selects drafts but allows exact drafts', () {
      final draft = release('1.4.0', draft: true);

      expect(
        () => policy.select(current: current, candidates: [draft]),
        throwsA(isA<ReleaseSelectionException>()),
      );
      expect(
        policy.select(current: current, candidates: [draft], exactTag: '1.4.0'),
        same(draft),
      );
    });

    test('exact selection is literal and permits non-SemVer releases', () {
      final candidates = [
        release('v1.3.0'),
        release('1.3.0'),
        release('daily'),
      ];

      expect(
        policy
            .select(
              current: current,
              candidates: candidates,
              exactTag: 'v1.3.0',
            )
            .literalTag,
        'v1.3.0',
      );
      expect(
        policy
            .select(current: current, candidates: candidates, exactTag: 'daily')
            .literalTag,
        'daily',
      );
      expect(
        () => policy.select(
          current: current,
          candidates: candidates,
          exactTag: 'V1.3.0',
        ),
        throwsA(isA<ReleaseSelectionException>()),
      );
    });

    test('exact selection does not bypass no-downgrade policy', () {
      expect(
        () => policy.select(
          current: current,
          candidates: [release('1.2.2')],
          exactTag: '1.2.2',
        ),
        throwsA(isA<ReleaseSelectionException>()),
      );
    });

    test('refuses equal-precedence ambiguity instead of using input order', () {
      final candidates = [release('1.4.0+one'), release('v1.4.0+two')];

      expect(
        () => policy.select(current: current, candidates: candidates),
        throwsA(isA<ReleaseSelectionException>()),
      );
      expect(
        policy
            .select(
              current: current,
              candidates: candidates,
              exactTag: 'v1.4.0+two',
            )
            .literalTag,
        'v1.4.0+two',
      );
    });

    test('retains safe release identity and digest fields', () {
      final candidate = release(
        '1.3.0',
        id: 'release-123',
        digest: 'sha256:abc',
      );

      expect(candidate.id, 'release-123');
      expect(candidate.digest, 'sha256:abc');
    });
  });
}

ReleaseCandidate release(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  String? id,
  String? digest,
}) => ReleaseCandidate(
  literalTag: tag,
  isDraft: draft,
  isPrerelease: prerelease,
  id: id,
  digest: digest,
);
