import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/pack_action.dart';
import 'package:file/memory.dart';
import 'package:agent_resource/src/pack/pack_discovery.dart';
import 'package:agent_resource/src/pack/pack_models.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/pack_lifecycle_service.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

final class RecordingPackService implements PackLifecycleService {
  final requests = <PackLifecycleRequest>[];
  final discoveries = <PackDiscoveryRequest>[];

  @override
  PackPrompts get prompts => const PackPrompts();

  @override
  String? get operatingSystem => null;

  @override
  Future<PackDiscoveryReport> discover(PackDiscoveryRequest request) async {
    discoveries.add(request);
    return const PackDiscoveryReport(
      pack: 'owner/repository',
      source: {'pack': 'owner/repository'},
      candidates: [],
      types: ['skill', 'agent', 'prompt'],
    );
  }

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
          disposition: PackDisposition.observed,
        ),
      ],
      dryRun: request.dryRun,
    );
  }
}

void main() {
  group('agent_resource', () {
    group('pack', () {
      group('install', () {
        test('offers user scope when project context is unavailable', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          fs.directory('/project').createSync();
          fs.directory('/home').createSync();
          fs.directory('/source/skills/reviewer').createSync(recursive: true);
          fs.file('/source/agent-resources.toml').writeAsStringSync('''
schema_version = 1
[[catalog.skills]]
path = "skills/reviewer"
''');
          fs
              .file('/source/skills/reviewer/SKILL.md')
              .writeAsStringSync(
                '---\nname: reviewer\ndescription: Reviews.\n---\nBody.\n',
              );
          fs.file('/project/agent-resources.toml').writeAsStringSync('''
schema_version = 1
[cli.install]
targets = ["codex"]
skill_method = "copy"
[packs."local/demo".source]
kind = "local"
path = "../source"
[packs."local/demo".update]
track = { kind = "local" }
''');
          var offered = 0;
          final command = PackActionCommand(
            PackResourceType.skill,
            PackOperation.install,
            PackLifecycleService(fileSystem: fs),
            fileSystem: fs,
            stdinIsTerminal: () => true,
            stdoutIsTerminal: () => true,
            offerUserScope: () async {
              offered++;
              return true;
            },
          );
          final result =
              await Executor('agent_resource', 'Test.', '1.0.0', [
                command,
              ]).fake().execute([
                'install',
                'local/demo',
                '--cwd',
                '/project/',
                '--project-root',
                '/missing/',
                '--home',
                '/home/',
                '--config',
                '/project/agent-resources.toml',
                '--target',
                'codex',
                '--method',
                'copy',
                '--dry-run',
              ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          expect(offered, 1);
          expect((result as MambaSuccessResult).output, contains('reviewer'));
          final missingCwd =
              await Executor('agent_resource', 'Test.', '1.0.0', [
                command,
              ]).fake().execute([
                'install',
                'local/demo',
                '--cwd',
                '/missing/',
                '--home',
                '/home/',
                '--config',
                '/project/agent-resources.toml',
                '--target',
                'codex',
                '--method',
                'copy',
                '--dry-run',
              ]);
          expect(
            missingCwd,
            isA<MambaSuccessResult>(),
            reason: missingCwd is MambaFailureResult
                ? missingCwd.message
                : null,
          );
          expect(offered, 2);
        });
        test('does not prompt when stdout is redirected', () async {
          final fs = MemoryFileSystem(style: FileSystemStyle.posix);
          fs.directory('/project').createSync();
          fs.directory('/source').createSync();
          fs.file('/project/agent-resources.toml').writeAsStringSync('''
schema_version = 1
[packs."local/demo".source]
kind = "local"
path = "../source"
[packs."local/demo".update]
track = { kind = "local" }
''');
          final command = PackActionCommand(
            PackResourceType.skill,
            PackOperation.install,
            PackLifecycleService(fileSystem: fs),
            fileSystem: fs,
            stdinIsTerminal: () => true,
            stdoutIsTerminal: () => false,
          );
          final result = await Executor('agent_resource', 'Test.', '1.0.0', [
            command,
          ]).fake().execute(['install', 'local/demo', '--cwd', '/project/']);
          expect(
            result,
            isA<MambaFailureResult>().having(
              (value) => value.message,
              'message',
              contains('Noninteractive mutations require explicit --scope'),
            ),
          );
        });
        test(
          'passes repeated native names and context to the lifecycle',
          () async {
            final service = RecordingPackService();
            final result = await createExecutor(packLifecycle: service)
                .fake()
                .execute([
                  'pack',
                  'install',
                  'owner/repository',
                  '--type',
                  'skill',
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

        test('passes the MCP type and reviewed collision resolution', () async {
          final service = RecordingPackService();
          await createExecutor(packLifecycle: service).fake().execute([
            'pack',
            'install',
            'owner/repository',
            '--type',
            'mcp',
            '--approve-mcp-collision',
            'github',
            '--approve-mcp-collision',
            'build',
            '--yes',
          ]);
          expect(service.requests.single.resourceTypes, [PackResourceType.mcp]);
          expect(service.requests.single.approveMcpCollision, [
            'github',
            'build',
          ]);
        });

        test('rejects unknown options before calling the lifecycle', () async {
          final service = RecordingPackService();
          final result = await createExecutor(packLifecycle: service)
              .fake()
              .execute([
                'pack',
                'install',
                'owner/repository',
                '--type',
                'skill',
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
                  'pack',
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
                'pack',
                'update',
                'owner/repository',
                '--type',
                'skill',
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
                  'pack',
                  'source',
                  'associate',
                  'owner/repository',
                  '--type',
                  'skill',
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
