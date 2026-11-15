import 'package:agent_resource/src/authoring/bound_role_authoring_inputs.dart';
import 'package:agent_resource/src/services/bound_role_service.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group('bound-role authoring inputs', () {
    test('the explicit selections are kept', () {
      final inputs = parseBoundRoleAuthoringInputs(
        roleKey: ' reviewer ',
        configFile: ' /project/.codex/config.toml ',
        ownership: 'both',
        definitionSource: ' /project/draft/reviewer.toml ',
        definitionOutput: ' /project/.codex/agents/reviewer.toml ',
        clientsStopped: true,
      );

      expect(inputs.roleKey, 'reviewer');
      expect(inputs.configFile, '/project/.codex/config.toml');
      expect(inputs.ownership, BoundOwnership.both);
      expect(inputs.definitionSource, '/project/draft/reviewer.toml');
      expect(inputs.definitionOutput, '/project/.codex/agents/reviewer.toml');
      expect(inputs.clientsStopped, isTrue);
      expect(inputs.publishesDefinition, isTrue);
      expect(inputs.registersRole, isTrue);
    });

    test('a definition-only ownership registers no role', () {
      final inputs = parseBoundRoleAuthoringInputs(
        roleKey: 'reviewer',
        configFile: '/project/.codex/config.toml',
        ownership: 'definition',
        definitionSource: '/project/draft/reviewer.toml',
      );

      expect(inputs.ownership, BoundOwnership.definition);
      expect(inputs.publishesDefinition, isTrue);
      expect(inputs.registersRole, isFalse);
      expect(inputs.clientsStopped, isFalse);
    });

    test('a missing role key is refused', () {
      expect(
        () => parseBoundRoleAuthoringInputs(
          roleKey: null,
          configFile: '/project/.codex/config.toml',
          ownership: 'both',
          definitionSource: '/project/draft/reviewer.toml',
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'exit code', 4)
              .having(
                (error) => error.message,
                'message',
                contains('role key'),
              ),
        ),
      );
    });

    test('a blank role key is refused', () {
      expect(
        () => parseBoundRoleAuthoringInputs(
          roleKey: '   ',
          configFile: '/project/.codex/config.toml',
          ownership: 'both',
          definitionSource: '/project/draft/reviewer.toml',
        ),
        throwsA(isA<MambaException>()),
      );
    });

    test('a nested role key is refused', () {
      expect(
        () => parseBoundRoleAuthoringInputs(
          roleKey: 'team.reviewer',
          configFile: '/project/.codex/config.toml',
          ownership: 'both',
          definitionSource: '/project/draft/reviewer.toml',
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('one name segment'),
          ),
        ),
      );
    });

    test('a missing declaring config is refused', () {
      expect(
        () => parseBoundRoleAuthoringInputs(
          roleKey: 'reviewer',
          configFile: null,
          ownership: 'both',
          definitionSource: '/project/draft/reviewer.toml',
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('declaring Codex config'),
          ),
        ),
      );
    });

    test('a missing ownership is refused', () {
      expect(
        () => parseBoundRoleAuthoringInputs(
          roleKey: 'reviewer',
          configFile: '/project/.codex/config.toml',
          ownership: null,
          definitionSource: '/project/draft/reviewer.toml',
        ),
        throwsA(isA<MambaException>()),
      );
    });

    test('an unsupported ownership is refused with the supported values', () {
      expect(
        () => parseBoundRoleAuthoringInputs(
          roleKey: 'reviewer',
          configFile: '/project/.codex/config.toml',
          ownership: 'adopt',
          definitionSource: '/project/draft/reviewer.toml',
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'exit code', 4)
              .having(
                (error) => error.message,
                'message',
                allOf(
                  contains('Unsupported bound-role ownership'),
                  contains('registration, definition, both'),
                ),
              ),
        ),
      );
    });

    test('a registration-only ownership is refused for a create', () {
      expect(
        () => parseBoundRoleAuthoringInputs(
          roleKey: 'reviewer',
          configFile: '/project/.codex/config.toml',
          ownership: 'registration',
          definitionSource: '/project/draft/reviewer.toml',
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('publishes a definition'),
          ),
        ),
      );
    });

    test('a missing definition source is refused', () {
      expect(
        () => parseBoundRoleAuthoringInputs(
          roleKey: 'reviewer',
          configFile: '/project/.codex/config.toml',
          ownership: 'both',
        ),
        throwsA(
          isA<MambaException>().having(
            (error) => error.message,
            'message',
            contains('definition source'),
          ),
        ),
      );
    });

    test('the retired request route names its replacement', () {
      expect(
        boundRoleRequestMigrationGuidance,
        allOf(
          contains('--role-key'),
          contains('--config-file'),
          contains('--ownership'),
          contains('--definition-source'),
        ),
      );
    });
  });
}
