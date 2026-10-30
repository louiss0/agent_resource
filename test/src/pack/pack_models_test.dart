import 'package:agent_resource/src/pack/pack_models.dart';
import 'package:test/test.dart';

void main() {
  group('PackProcessStatus', () {
    test('uses stable explicit numeric process codes', () {
      expect(
        {for (final status in PackProcessStatus.values) status: status.code},
        {
          PackProcessStatus.success: 0,
          PackProcessStatus.failure: 1,
          PackProcessStatus.invalidInput: 2,
          PackProcessStatus.cancelled: 3,
          PackProcessStatus.recoveryRequired: 4,
          PackProcessStatus.interrupted: 130,
        },
      );
    });
  });

  group('PackOperationResult', () {
    test('emits the versioned success envelope and summary counts', () {
      final result = PackOperationResult(
        operation: 'skills.update',
        outcome: 'preview',
        context: const {
          'scope': 'project',
          'projectRoot': r'C:\work\demo',
          'target': 'codex',
        },
        source: const {
          'pack': 'owner/repository',
          'kind': 'github',
          'track': 'branch',
        },
        resources: const [
          PackResourceResult(
            type: 'skill',
            name: 'reviewer',
            disposition: 'updated',
            previousSnapshot: 'old',
            snapshot: 'new',
          ),
          PackResourceResult(
            type: 'skill',
            name: 'local',
            disposition: 'keptLocal',
          ),
        ],
        warnings: const [
          PackWarning(id: 'inapplicable-option', message: 'Ignored --bump.'),
        ],
        dryRun: true,
      );

      expect(result.envelope(), {
        'schemaVersion': 1,
        'operation': 'skills.update',
        'outcome': 'preview',
        'context': {
          'scope': 'project',
          'projectRoot': r'C:\work\demo',
          'target': 'codex',
        },
        'source': {
          'pack': 'owner/repository',
          'kind': 'github',
          'track': 'branch',
        },
        'resources': [
          {
            'type': 'skill',
            'name': 'reviewer',
            'disposition': 'updated',
            'previousSnapshot': 'old',
            'snapshot': 'new',
            'linkOnly': false,
          },
          {
            'type': 'skill',
            'name': 'local',
            'disposition': 'keptLocal',
            'linkOnly': false,
          },
        ],
        'warnings': [
          {'id': 'inapplicable-option', 'message': 'Ignored --bump.'},
        ],
        'summary': {'total': 2, 'updated': 1, 'keptLocal': 1},
        'dryRun': true,
      });
    });
  });
}
