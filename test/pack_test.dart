import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/pack_lifecycle_service.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

import 'pack_action_test.dart' show RecordingPackService;

void main() {
  group('agent_resource', () {
    group('pack', () {
      test('help lists canonical actions without effects', () async {
        final service = RecordingPackService();
        final result = await createExecutor(packLifecycle: service)
            .fake()
            .execute(['pack', '--help']);
        expect(
          result,
          isA<MambaSuccessResult>().having(
            (v) => v.output,
            'output',
            allOf(
              contains('install'),
              contains('validate'),
              contains('source'),
            ),
          ),
        );
        expect(service.requests, isEmpty);
      });
      for (final operation in [
        'install',
        'update',
        'remove',
        'rollback',
        'cleanup',
        'validate',
      ]) {
        group(operation, () {
          test(
            'passes both types by default and preserves item filter',
            () async {
              final service = RecordingPackService();
              await createExecutor(packLifecycle: service).fake().execute([
                'pack',
                operation,
                'owner/repo',
                '--only',
                'reviewer',
                '--yes',
              ]);
              expect(service.requests.single.resourceTypes, [
                PackResourceType.skill,
                PackResourceType.agent,
              ]);
              expect(service.requests.single.only, ['reviewer']);
              expect(service.requests.single.includeNew, isFalse);
            },
          );
        });
      }
      group('update', () {
        test('accepts explicit type and include-new', () async {
          final service = RecordingPackService();
          await createExecutor(packLifecycle: service).fake().execute([
            'pack',
            'update',
            'owner/repo',
            '--type',
            'agent',
            '--include-new',
          ]);
          expect(service.requests.single.resourceTypes, [
            PackResourceType.agent,
          ]);
          expect(service.requests.single.includeNew, isTrue);
        });
        test('rejects conflicting selections before effects', () async {
          final service = RecordingPackService();
          final result = await createExecutor(packLifecycle: service)
              .fake()
              .execute([
                'pack',
                'update',
                'owner/repo',
                '--include-new',
                '--skip-new',
              ]);
          expect(
            result,
            isA<MambaFailureResult>().having(
              (v) => v.message,
              'message',
              contains('--include-new'),
            ),
          );
          expect(service.requests, isEmpty);
        });
        test('rejects invalid type before effects', () async {
          final service = RecordingPackService();
          final result = await createExecutor(packLifecycle: service)
              .fake()
              .execute(['pack', 'update', 'owner/repo', '--type', 'other']);
          expect(result, isA<MambaFailureResult>());
          expect(service.requests, isEmpty);
        });
      });
      group('source', () {
        for (final operation in ['associate', 'change']) {
          group(operation, () {
            test('passes selected kinds', () async {
              final service = RecordingPackService();
              await createExecutor(packLifecycle: service).fake().execute([
                'pack',
                'source',
                operation,
                'owner/repo',
                '--type',
                'skill',
                '--type',
                'agent',
              ]);
              expect(service.requests.single.resourceTypes, [
                PackResourceType.skill,
                PackResourceType.agent,
              ]);
            });
          });
        }
      });
    });
    for (final entry in {
      'skills': PackResourceType.skill,
      'agents': PackResourceType.agent,
    }.entries) {
      group(entry.key, () {
        test('pins type and sends deprecation separately from JSON', () async {
          final service = RecordingPackService();
          final warnings = <String>[];
          final result =
              await createExecutor(
                packLifecycle: service,
                deprecationWarning: warnings.add,
              ).fake().execute([
                entry.key,
                'install',
                'owner/repo',
                '--format',
                'json',
              ]);
          expect(service.requests.single.resourceTypes, [entry.value]);
          expect(warnings.single, contains('deprecated'));
          expect(
            result,
            isA<MambaSuccessResult>().having(
              (v) => v.output,
              'output',
              isNot(contains('deprecated')),
            ),
          );
        });
      });
    }
  });
}
