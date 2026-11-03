import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

Future<MambaExecutionResult> _list(List<String> args, fslib.FileSystem fs) =>
    createExecutor(skillLifecycle: SkillLifecycleService(fileSystem: fs))
        .fake()
        .execute(['skill', 'list', ...args]);

Map<String, Object?> _successReport(MambaExecutionResult result) {
  expect(
    result,
    isA<MambaSuccessResult>()
        .having((value) => value.exitCode, 'exit code', 0)
        .having((value) => value.output, 'output', isNotNull),
    reason: result is MambaFailureResult ? result.message : null,
  );
  final output = (result as MambaSuccessResult).output!;
  final report = Map<String, Object?>.from(
    jsonDecode(output) as Map<Object?, Object?>,
  );
  expect(output, jsonEncode(report));
  expect(report['schemaVersion'], 1);
  expect(report['command'], 'skill list');
  expect(report['outcome'], 'inventoried');
  return report;
}

List<Map<String, Object?>> _occurrences(Map<String, Object?> report) =>
    ((report['data']! as Map<Object?, Object?>)['occurrences']!
            as List<Object?>)
        .map(
          (value) => Map<String, Object?>.from(value! as Map<Object?, Object?>),
        )
        .toList();

void main() {
  group('agent_resource', () {
    late fslib.FileSystem fs;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
    });
    group('skill', () {
      group('list', () {
        test(
          'project inventory retains every native destination without writes',
          () async {
            final sandbox = (fs.directory('/sandbox')..createSync());
            try {
              final project = fs.directory(
                fs.path.join(sandbox.path, 'project'),
              )..createSync();
              final work = fs.directory(fs.path.join(project.path, 'work'))
                ..createSync();
              final home = fs.directory(fs.path.join(sandbox.path, 'home'))
                ..createSync();
              for (final destination in ['claude', 'codex', 'shared']) {
                final harness = destination == 'shared'
                    ? '.agents'
                    : '.$destination';
                final skill = fs.directory(
                  fs.path.join(project.path, harness, 'skills', 'alpha'),
                )..createSync(recursive: true);
                fs
                    .file(fs.path.join(skill.path, 'SKILL.md'))
                    .writeAsStringSync('not validated');
              }
              final before = project.listSync(recursive: true).length;
              final separator = fs.path.separator;
              final report = _successReport(
                await _list([
                  '--scope',
                  'project',
                  '--cwd',
                  '${work.path}$separator',
                  '--project-root',
                  '${project.path}$separator',
                  '--home',
                  '${home.path}$separator',
                  '--format',
                  'json',
                ], fs),
              );
              final occurrences = _occurrences(report);
              expect(occurrences, hasLength(3));
              expect(
                occurrences
                    .map((occurrence) => occurrence['destination'])
                    .toSet(),
                {'claude', 'codex', 'shared'},
              );
              for (final occurrence in occurrences) {
                expect(occurrence['installationScope'], 'project');
                expect(occurrence['management'], 'unmanaged');
                expect(occurrence['modification'], 'notVerified');
                expect(occurrence['eligibility'], 'direct-child-copy');
                expect(occurrence['occurrenceId'], hasLength(64));
              }
              expect(project.listSync(recursive: true).length, before);
              expect(
                fs
                    .directory(fs.path.join(project.path, '.agent-resource'))
                    .existsSync(),
                isFalse,
              );
            } finally {
              await sandbox.delete(recursive: true);
            }
          },
        );

        test(
          'managed verification distinguishes unchanged and changed',
          () async {
            final sandbox = (fs.directory('/sandbox')..createSync());
            try {
              final project = fs.directory(
                fs.path.join(sandbox.path, 'project'),
              )..createSync();
              final home = fs.directory(fs.path.join(sandbox.path, 'home'))
                ..createSync();
              final source = fs.directory(fs.path.join(sandbox.path, 'source'))
                ..createSync();
              final marker = fs.file(fs.path.join(source.path, 'SKILL.md'))
                ..writeAsStringSync(
                  '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
                );
              final service = SkillLifecycleService(fileSystem: fs);
              LifecycleOptions options() => LifecycleOptions(
                processWorkingDirectory: project.path,
                scope: LifecycleScope.project,
                cwd: project.path,
                projectRoot: project.path,
                home: home.path,
              );
              final installed = await service.install(
                SkillInstallInput(
                  options: options(),
                  source: source.path,
                  destination: SkillDestination.claude,
                ),
              );
              final separator = fs.path.separator;
              final args = [
                '--scope',
                'project',
                '--cwd',
                '${project.path}$separator',
                '--project-root',
                '${project.path}$separator',
                '--home',
                '${home.path}$separator',
                '--verify',
                '--format',
                'json',
              ];
              final unchanged = _occurrences(
                _successReport(await _list(args, fs)),
              ).single;
              expect(
                unchanged['installationId'],
                installed.data['installationId'],
              );
              expect(unchanged['management'], 'managed');
              expect(unchanged['modification'], 'unchanged');

              fs
                  .file(
                    fs.path.join(
                      project.path,
                      '.claude',
                      'skills',
                      'review',
                      'SKILL.md',
                    ),
                  )
                  .writeAsStringSync('user edit');
              final changed = _occurrences(
                _successReport(await _list(args, fs)),
              ).single;
              expect(changed['modification'], 'changed');
              expect(marker.readAsStringSync(), contains('Body.'));
            } finally {
              await sandbox.delete(recursive: true);
            }
          },
        );

        test(
          'destination filter does not alter scope or create state',
          () async {
            final sandbox = (fs.directory('/sandbox')..createSync());
            try {
              final project = fs.directory(
                fs.path.join(sandbox.path, 'project'),
              )..createSync();
              final home = fs.directory(fs.path.join(sandbox.path, 'home'))
                ..createSync();
              fs
                  .directory(
                    fs.path.join(
                      project.path,
                      '.codex',
                      'skills',
                      'codex-only',
                    ),
                  )
                  .createSync(recursive: true);
              fs
                  .directory(
                    fs.path.join(
                      project.path,
                      '.claude',
                      'skills',
                      'claude-only',
                    ),
                  )
                  .createSync(recursive: true);
              final separator = fs.path.separator;
              final report = _successReport(
                await _list([
                  '--scope',
                  'project',
                  '--cwd',
                  '${project.path}$separator',
                  '--project-root',
                  '${project.path}$separator',
                  '--home',
                  '${home.path}$separator',
                  '--destination',
                  'codex',
                  '--format',
                  'json',
                ], fs),
              );
              expect(_occurrences(report).single['destination'], 'codex');
              expect(
                fs
                    .directory(fs.path.join(project.path, '.agent-resource'))
                    .existsSync(),
                isFalse,
              );
            } finally {
              await sandbox.delete(recursive: true);
            }
          },
        );

        test('discover is not retained as a second inventory verb', () async {
          final result = await createExecutor().fake().execute([
            'skill',
            'discover',
          ]);
          expect(
            result,
            isA<MambaFailureResult>()
                .having((value) => value.exitCode, 'exit code', 1)
                .having((value) => value.output, 'output', isNull)
                .having(
                  (value) => value.message,
                  'message',
                  contains('discover'),
                )
                .having(
                  (value) => value.error.phase,
                  'phase',
                  MambaExecutionPhase.parse,
                )
                .having((value) => value.error.commandPath, 'command path', [
                  'agent_resource',
                  'skill',
                ]),
          );
        });
      });
    });
  });
}
