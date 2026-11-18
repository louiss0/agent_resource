import 'package:agent_resource/src/context/context_types.dart';
import 'package:test/test.dart';

void main() {
  group('context', () {
    group('template names', () {
      for (final name in [
        'a',
        '0',
        'context-team_rules',
        'a${'b' * 63}',
        'console',
        'com10',
        'trailing-',
        'trailing_',
      ]) {
        test('accepts portable name $name', () {
          expect(isValidContextTemplateName(name), isTrue);
        });
      }

      for (final name in [
        '',
        'A',
        'Uppercase',
        '-leading',
        '_leading',
        'has.dot',
        'has/slash',
        'has space',
        'name.md',
        '../escape',
        'a${'b' * 64}',
      ]) {
        test(
          'refuses non-portable name ${name.isEmpty ? '<empty>' : name}',
          () {
            expect(isValidContextTemplateName(name), isFalse);
          },
        );
      }

      for (final name in [
        'con',
        'prn',
        'aux',
        'nul',
        'com1',
        'com9',
        'lpt1',
        'lpt9',
      ]) {
        test('refuses Windows reserved device name $name', () {
          expect(contextTemplateNamePattern.hasMatch(name), isTrue);
          expect(isValidContextTemplateName(name), isFalse);
        });
      }
    });

    group('wire names', () {
      test('context harness members use their CLI spellings', () {
        expect(
          ContextHarness.values.map((value) => value.name).toList(),
          equals(['claude', 'codex', 'pi']),
        );
      });

      test('context scope members use their CLI spellings', () {
        expect(
          ContextScope.values.map((value) => value.name).toList(),
          equals(['project', 'user']),
        );
      });

      test('context variants expose the documented wire names', () {
        expect(
          ContextVariant.values.map((value) => value.wireName).toList(),
          equals(['standard', 'local', 'override', 'dot-claude']),
        );
      });

      test('combine actions use their CLI spellings', () {
        expect(
          ContextCombineAction.values.map((value) => value.name).toList(),
          equals(['create', 'append', 'replace']),
        );
      });
    });

    group('template metadata', () {
      test('serializes the documented read fields', () {
        const metadata = ContextTemplateMetadata(
          name: 'team-rules',
          path: '/state/context-templates/team-rules.md',
          byteLength: 12,
          sha256: 'abc123',
        );

        expect(metadata.isEmpty, isFalse);
        expect(
          metadata.toJson(),
          equals(<String, Object?>{
            'name': 'team-rules',
            'path': '/state/context-templates/team-rules.md',
            'byteLength': 12,
            'isEmpty': false,
            'sha256': 'abc123',
          }),
        );
      });

      test('treats a zero-byte template as empty', () {
        const metadata = ContextTemplateMetadata(
          name: 'blank',
          path: '/state/context-templates/blank.md',
          byteLength: 0,
          sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        );

        expect(metadata.isEmpty, isTrue);
        expect(metadata.toJson()['isEmpty'], isTrue);
      });
    });
  });
}
