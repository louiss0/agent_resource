import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group('parseAuthoringInputs', () {
    test('selects one body input and rejects a second one', () {
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        bodyText: 'Body',
        fields: const <String, Object?>{'name': 'demo'},
      );
      expect(inputs.body?.kind, BodyInputKind.literal);
      expect(inputs.body?.text, 'Body');
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          bodyText: 'Body',
          bodyFile: 'body.md',
          fields: const <String, Object?>{'name': 'demo'},
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('exactly one body input'),
          ),
        ),
      );
    });

    test('keeps multiline literal text exactly as supplied', () {
      const body = 'First line\n\n  indented line\nLast line\n';
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.pi,
        bodyText: body,
        fields: const <String, Object?>{
          'name': 'review',
          'description': 'Review staged changes',
        },
      );
      expect(inputs.body?.text, body);
    });

    test('rejects a source path combined with an installation', () {
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.edit,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          sourcePath: '/work/demo',
          installationId: 'ins_0123456789abcdef0123456789abcdef',
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('not both'),
          ),
        ),
      );
    });

    test('clone refuses a body changing input', () {
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.clone,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          sourcePath: '/work/demo',
          bodyText: 'Changed body',
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('Clone preserves the source instructions'),
          ),
        ),
      );
    });

    test('compose requires an explicit body combination choice', () {
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.compose,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          sourcePath: '/work/demo',
          bodyText: 'New body',
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('append, replace or retain'),
          ),
        ),
      );
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.compose,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          sourcePath: '/work/demo',
          bodyText: 'New body',
          composition: CompositionMode.retain,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('retain cannot be combined'),
          ),
        ),
      );
      final appended = parseAuthoringInputs(
        operation: AuthoringOperation.compose,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        sourcePath: '/work/demo',
        bodyText: 'New body',
        composition: CompositionMode.append,
      );
      expect(appended.composition, CompositionMode.append);
    });

    test('a conversion preserves the source body and needs a direction', () {
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.convert,
          kind: AuthoringKind.prompt,
          profile: AuthoringProfile.claude,
          sourcePath: '/work/demo',
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('explicit supported direction'),
          ),
        ),
      );
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.convert,
          kind: AuthoringKind.prompt,
          profile: AuthoringProfile.claude,
          sourcePath: '/work/demo',
          bodyText: 'Rewritten body',
          conversion: ConversionDirection.skillToPrompt,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('preserves the source instructions'),
          ),
        ),
      );
      final conversion = parseAuthoringInputs(
        operation: AuthoringOperation.convert,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.claude,
        sourcePath: '/work/demo',
        conversion: ConversionDirection.skillToPrompt,
      );
      expect(conversion.conversion, ConversionDirection.skillToPrompt);
    });

    test('a Prompt to Skill reclassification has no supported direction', () {
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.convert,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          sourcePath: '/work/demo',
          conversion: ConversionDirection.skillToPrompt,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('targets the prompt kind'),
          ),
        ),
      );
    });

    test('a global profile applies to prompts only', () {
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.global,
          bodyText: 'Body',
          fields: const <String, Object?>{'name': 'demo'},
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('applies to prompts only'),
          ),
        ),
      );
      final prompt = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.global,
        bodyText: 'Body',
        fields: const <String, Object?>{'name': 'demo'},
      );
      expect(prompt.profile, AuthoringProfile.global);
    });

    test('an unsupported native field names the supported fields', () {
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.codex,
          bodyText: 'Body',
          fields: const <String, Object?>{
            'name': 'demo',
            'disallowed-tools': <String>['Bash'],
          },
        ),
        throwsA(
          isA<MambaException>()
              .having(
                (error) => error.message,
                'message',
                contains('does not support the disallowed-tools field'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('allowed-tools'),
              ),
        ),
      );
    });

    test('a supplied list replaces the whole native field', () {
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        bodyText: 'Body',
        fields: const <String, Object?>{
          'name': 'demo',
          'description': 'Demo skill',
          'allowed-tools': <String>['Read'],
        },
      );
      final value = inputs.fields['allowed-tools'];
      expect(value, isA<ListFieldValue>());
      expect((value! as ListFieldValue).values, <String>['Read']);
    });

    test('clearing and inheriting require a supported field', () {
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          bodyText: 'Body',
          fields: const <String, Object?>{
            'name': 'demo',
            'description': 'Demo skill',
            'allowed-tools': ClearedFieldValue(),
          },
        ),
        returnsNormally,
      );
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          bodyText: 'Body',
          fields: const <String, Object?>{
            'name': 'demo',
            'description': 'Demo skill',
            'name ': ClearedFieldValue(),
          },
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('does not support'),
          ),
        ),
      );
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          bodyText: 'Body',
          fields: const <String, Object?>{
            'name': ClearedFieldValue(),
            'description': 'Demo skill',
          },
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('cannot be cleared'),
          ),
        ),
      );
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.create,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          bodyText: 'Body',
          fields: const <String, Object?>{
            'name': 'demo',
            'description': 'Demo skill',
            'license': InheritedFieldValue(),
          },
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('cannot inherit'),
          ),
        ),
      );
    });

    test('a composition choice is valid for a compose operation only', () {
      expect(
        () => parseAuthoringInputs(
          operation: AuthoringOperation.edit,
          kind: AuthoringKind.skill,
          profile: AuthoringProfile.claude,
          sourcePath: '/work/demo',
          bodyText: 'New body',
          composition: CompositionMode.append,
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('valid for a compose operation only'),
          ),
        ),
      );
    });

    test('a required field is named by the profile matrix', () {
      final matrix = NativeFieldMatrix.forKind(
        AuthoringKind.agent,
        AuthoringProfile.pi,
      );
      expect(matrix.specFor('model')?.required, isTrue);
      expect(matrix.specFor('tools')?.required, isTrue);
      expect(
        NativeFieldMatrix.forKind(
          AuthoringKind.agent,
          AuthoringProfile.claude,
        ).specFor('model')?.required,
        isFalse,
      );
    });

    test('the scope and management request are retained', () {
      final inputs = parseAuthoringInputs(
        operation: AuthoringOperation.create,
        kind: AuthoringKind.skill,
        profile: AuthoringProfile.claude,
        scope: LifecycleScope.user,
        manage: true,
        bodyText: 'Body',
        fields: const <String, Object?>{'name': 'demo'},
      );
      expect(inputs.scope, LifecycleScope.user);
      expect(inputs.manage, isTrue);
    });
  });
}
