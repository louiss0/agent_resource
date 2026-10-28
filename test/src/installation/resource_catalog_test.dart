import 'dart:io';

import 'package:agent_resource/src/installation/resource_catalog.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ResourceCatalog', () {
    late Directory sandbox;
    late File config;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('resource-catalog-');
      config = File(p.join(sandbox.path, 'agent-resources.toml'));
    });

    tearDown(() async {
      if (sandbox.existsSync()) await sandbox.delete(recursive: true);
    });

    ResourceCatalog load(
      String source, [
      CatalogResourceType type = CatalogResourceType.skill,
    ]) {
      config.writeAsStringSync(source);
      return ResourceCatalog.load(config.path, type);
    }

    test('loads immutable typed offerings and evidence-backed metadata', () {
      final catalog = load('''
schema_version = 1

[[skills]]
id = "code-review"
path = "skills/code-review"
label = "Code review"

[[skills]]
id = "root-skill"
path = "."

[[agents]]
id = "reviewer-claude"
path = "agents/reviewer.md"
profile = "claude"

[[agents]]
id = "reviewer-codex"
path = "agents/reviewer.toml"
profile = "codex"

[[agents]]
id = "reviewer-pi"
path = "agents/reviewer-pi.md"
profile = "pi-common"
''', CatalogResourceType.agent);

      expect(catalog.schemaVersion, 1);
      expect(catalog.configPath, config.path);
      expect(catalog.configDigest, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(catalog.offerings, hasLength(3));
      expect(catalog.offerings.map((offering) => offering.id), [
        'reviewer-claude',
        'reviewer-codex',
        'reviewer-pi',
      ]);
      expect(
        catalog.offerings.map(
          (offering) => (offering as AgentOffering).profile,
        ),
        [
          NativeAgentProfile.claude,
          NativeAgentProfile.codex,
          NativeAgentProfile.piCommon,
        ],
      );
      expect(
        () => catalog.offerings.add(
          SkillOffering(id: 'other', path: 'other', label: null),
        ),
        throwsUnsupportedError,
      );

      final skills = load(config.readAsStringSync(), CatalogResourceType.skill);
      expect(skills.offerings, hasLength(2));
      expect(skills.offerings.first, isA<SkillOffering>());
      expect(skills.offerings.first.label, 'Code review');
      expect(skills.offerings.last.path, '.');
    });

    test('accepts absent and explicitly empty catalogs', () {
      expect(load('schema_version = 1\n').offerings, isEmpty);
      expect(load('schema_version = 1\nskills = []\n').offerings, isEmpty);
    });

    test('accepts boundary IDs and cross-type ID reuse', () {
      final one = 'a';
      final longest = 'a${'b' * 63}';
      final catalog = load('''
schema_version = 1
[[skills]]
id = "$one"
path = "one"
[[skills]]
id = "$longest"
path = "two"
[[agents]]
id = "$one"
path = "agent.md"
profile = "claude"
''');
      expect(catalog.offerings.map((offering) => offering.id), [one, longest]);
    });

    for (final testCase in <({String name, String id})>[
      (name: 'too long', id: 'a${'b' * 64}'),
      (name: 'uppercase', id: 'Review'),
      (name: 'whitespace', id: ' review'),
      (name: 'non-ASCII', id: 'réview'),
      (name: 'edge hyphen', id: '-review'),
      (name: 'repeated hyphen', id: 'code--review'),
      (name: 'empty', id: ''),
    ]) {
      test('rejects ${testCase.name} IDs without repairing them', () {
        expect(
          () => load('''
schema_version = 1
[[skills]]
id = "${testCase.id}"
path = "skill"
'''),
          throwsA(
            isA<MambaException>()
                .having((error) => error.exitCode, 'status', 1)
                .having((error) => error.message, 'message', contains('id')),
          ),
        );
      });
    }

    test(
      'validates every entry including entries a selector would exclude',
      () {
        expect(
          () => load('''
schema_version = 1
[[skills]]
id = "valid"
path = "valid"
[[skills]]
id = "invalid"
path = "../escape"
'''),
          throwsA(
            isA<MambaException>().having(
              (error) => error.message,
              'message',
              allOf(contains('skills[1]'), contains('path')),
            ),
          ),
        );
      },
    );

    test('isolates semantic catalog errors by requested resource type', () {
      const source = '''
schema_version = 1
[[skills]]
id = "valid"
path = "valid"
[[agents]]
id = "broken"
path = "agent.md"
profile = "unknown"
''';
      expect(load(source).offerings.single.id, 'valid');
      expect(
        () => load(source, CatalogResourceType.agent),
        throwsA(isA<MambaException>()),
      );
    });

    test('root, syntax, and duplicate-key failures block both types', () {
      for (final source in [
        'schema_version = 1\nunknown = true\n',
        'schema_version = "1"\n',
        'schema_version = 2\n',
        'schema_version = 1\nschema_version = 1\n',
        'schema_version = 1\n[[skills]\n',
      ]) {
        for (final type in CatalogResourceType.values) {
          expect(
            () => load(source, type),
            throwsA(isA<MambaException>()),
            reason: '$source ($type)',
          );
        }
      }
    });

    test('rejects duplicate IDs and normalized paths within one type', () {
      for (final source in [
        '''
schema_version = 1
[[skills]]
id = "same"
path = "one"
[[skills]]
id = "same"
path = "two"
''',
        '''
schema_version = 1
[[skills]]
id = "one"
path = "same"
[[skills]]
id = "two"
path = "same"
''',
      ]) {
        expect(() => load(source), throwsA(isA<MambaException>()));
      }
    });

    for (final path in [
      '/absolute',
      'C:/absolute',
      r'\\server\share',
      r'skills\review',
      '../escape',
      'skills/../escape',
      'skills//review',
      'skills/review/',
      './review',
      '',
    ]) {
      test(
        'rejects unsafe catalog path ${path.isEmpty ? '<empty>' : path}',
        () {
          expect(
            () => load('''
schema_version = 1
[[skills]]
id = "review"
path = "$path"
'''),
            throwsA(isA<MambaException>()),
          );
        },
      );
    }

    test(
      'rejects unknown fields and invalid labels without dumping values',
      () {
        expect(
          () => load('''
schema_version = 1
[[skills]]
id = "review"
path = "review"
approval = "secret-approval-value"
'''),
          throwsA(
            isA<MambaException>()
                .having(
                  (error) => error.message,
                  'message',
                  contains('approval'),
                )
                .having(
                  (error) => error.message,
                  'message',
                  isNot(contains('secret-approval-value')),
                ),
          ),
        );
        for (final label in ['', 'two\\nlines', 'bad\\u0001control']) {
          expect(
            () => load('''
schema_version = 1
[[skills]]
id = "review"
path = "review"
label = "$label"
'''),
            throwsA(isA<MambaException>()),
          );
        }
      },
    );

    test('enforces the one MiB config budget during reading', () {
      config.writeAsBytesSync(List<int>.filled(1024 * 1024 + 1, 0x20));
      expect(
        () => ResourceCatalog.load(config.path, CatalogResourceType.skill),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 3)
              .having((error) => error.message, 'message', contains('1 MiB')),
        ),
      );
    });

    test('enforces the requested-catalog budget before selection', () {
      final source = StringBuffer('schema_version = 1\n');
      for (var index = 0; index < 1001; index++) {
        source.writeln('[[skills]]\nid = "item-$index"\npath = "item-$index"');
      }
      expect(
        () => load(source.toString()),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'status', 3)
              .having((error) => error.message, 'message', contains('1,000')),
        ),
      );
    });
  });
}
