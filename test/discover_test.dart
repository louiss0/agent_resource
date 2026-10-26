import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<MambaExecutionResult> _list(List<String> args) =>
    createExecutor().fake().execute(['skill', 'list', ...args]);

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
    group('skill', () {
      group('list', () {
        test(
          'project inventory retains every native destination without writes',
          () async {
            final sandbox = await Directory.systemTemp.createTemp(
              'skill-list-',
            );
            try {
              final project = Directory(p.join(sandbox.path, 'project'))
                ..createSync();
              final work = Directory(p.join(project.path, 'work'))
                ..createSync();
              final home = Directory(p.join(sandbox.path, 'home'))
                ..createSync();
              for (final destination in ['claude', 'codex', 'shared']) {
                final harness = destination == 'shared'
                    ? '.agents'
                    : '.$destination';
                final skill = Directory(
                  p.join(project.path, harness, 'skills', 'alpha'),
                )..createSync(recursive: true);
                File(p.join(skill.path, 'SKILL.md'))
                    .writeAsStringSync('not validated');
              }
              final before = project.listSync(recursive: true).length;
              final separator = Platform.pathSeparator;
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
                ]),
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
                Directory(p.join(project.path, '.agent-resource')).existsSync(),
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
            final sandbox = await Directory.systemTemp.createTemp(
              'skill-managed-list-',
            );
            try {
              final project = Directory(p.join(sandbox.path, 'project'))
                ..createSync();
              final home = Directory(p.join(sandbox.path, 'home'))
                ..createSync();
              final source = Directory(p.join(sandbox.path, 'source'))
                ..createSync();
              final marker = File(p.join(source.path, 'SKILL.md'))
                ..writeAsStringSync(
                  '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
                );
              final service = SkillLifecycleService();
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
              final separator = Platform.pathSeparator;
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
              final unchanged = _occurrences(_successReport(await _list(args)))
                  .single;
              expect(
                unchanged['installationId'],
                installed.data['installationId'],
              );
              expect(unchanged['management'], 'managed');
              expect(unchanged['modification'], 'unchanged');

              File(
                p.join(project.path, '.claude', 'skills', 'review', 'SKILL.md'),
              ).writeAsStringSync('user edit');
              final changed = _occurrences(_successReport(await _list(args)))
                  .single;
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
            final sandbox = await Directory.systemTemp.createTemp(
              'skill-filter-',
            );
            try {
              final project = Directory(p.join(sandbox.path, 'project'))
                ..createSync();
              final home = Directory(p.join(sandbox.path, 'home'))
                ..createSync();
              Directory(p.join(project.path, '.codex', 'skills', 'codex-only'))
                  .createSync(recursive: true);
              Directory(
                p.join(project.path, '.claude', 'skills', 'claude-only'),
              ).createSync(recursive: true);
              final separator = Platform.pathSeparator;
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
                ]),
              );
              expect(_occurrences(report).single['destination'], 'codex');
              expect(
                Directory(p.join(project.path, '.agent-resource')).existsSync(),
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
