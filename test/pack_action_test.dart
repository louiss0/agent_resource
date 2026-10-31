import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/pack/pack_models.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/pack_lifecycle_service.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

final class RecordingPackService implements PackLifecycleService {
  final requests = <PackLifecycleRequest>[];

  @override
  PackPrompts get prompts => const PackPrompts();

  @override
  Future<PackOperationResult> execute(PackLifecycleRequest request) async {
    requests.add(request);
    return PackOperationResult(
      operation: '${request.resourceType.name}s.${request.operation.name}',
      outcome: request.dryRun ? 'preview' : 'completed',
      context: {'scope': request.scope?.name},
      source: {'pack': request.pack},
      resources: const [
        PackResourceResult(
          type: 'skill',
          name: 'reviewer',
          disposition: 'observed',
        ),
      ],
      dryRun: request.dryRun,
    );
  }
}

void main() {
  group('agent_resource', () {
    group('skills', () {
      group('install', () {
        test(
          'passes repeated native names and context to the lifecycle',
          () async {
            final service = RecordingPackService();
            final result = await createExecutor(packLifecycle: service)
                .fake()
                .execute([
                  'skills',
                  'install',
                  'owner/repository',
                  '--scope',
                  'project',
                  '--only',
                  'reviewer',
                  '--only',
                  'writer',
                  '--method',
                  'copy',
                  '--yes',
                ]);

            expect(
              result,
              isA<MambaSuccessResult>()
                  .having((value) => value.exitCode, 'exit code', 0)
                  .having(
                    (value) => value.output,
                    'output',
                    'skills.install: completed\n'
                        'skill reviewer: observed\n'
                        'summary: 1 resource(s)',
                  ),
            );
            expect(service.requests.single.only, ['reviewer', 'writer']);
            expect(service.requests.single.scope, LifecycleScope.project);
            expect(service.requests.single.method, 'copy');
          },
        );

        test('rejects unknown options before calling the lifecycle', () async {
          final service = RecordingPackService();
          final result = await createExecutor(packLifecycle: service)
              .fake()
              .execute([
                'skills',
                'install',
                'owner/repository',
                '--attachment-accept',
              ]);

          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', isNonZero)
                .having(
                  (value) => value.message,
                  'message',
                  contains('--attachment-accept'),
                )
                .having((value) => value.output, 'output', isNull)
                .having(
                  (value) => value.error.phase,
                  'phase',
                  MambaExecutionPhase.parse,
                )
                .having((value) => value.error.commandPath, 'command path', [
                  'agent_resource',
                  'skills',
                  'install',
                ]),
          );
          expect(service.requests, isEmpty);
        });
      });

      group('update', () {
        test('renders the versioned JSON envelope on success', () async {
          final service = RecordingPackService();
          final result = await createExecutor(packLifecycle: service)
              .fake()
              .execute([
                'skills',
                'update',
                'owner/repository',
                '--format',
                'json',
                '--dry-run',
              ]);

          expect(
            result,
            isA<MambaSuccessResult>()
                .having((value) => value.exitCode, 'exit code', 0)
                .having(
                  (value) => value.output,
                  'output',
                  allOf(
                    contains('"schemaVersion":1'),
                    contains('"outcome":"preview"'),
                    contains('"dryRun":true'),
                  ),
                ),
          );
        });
      });

      group('source', () {
        group('associate', () {
          test('wires the nested source operation', () async {
            final service = RecordingPackService();
            final result = await createExecutor(packLifecycle: service)
                .fake()
                .execute([
                  'skills',
                  'source',
                  'associate',
                  'owner/repository',
                  '--only',
                  'reviewer',
                ]);

            expect(result, isA<MambaSuccessResult>());
            expect(
              service.requests.single.operation,
              PackOperation.sourceAssociate,
            );
          });
        });
      });
    });
  });
}
