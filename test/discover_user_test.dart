import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/services/skill_lifecycle_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    late fslib.FileSystem fs;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
    });
    group('skill', () {
      group('list', () {
        test(
          'user is the default scope and native home overrides are isolated',
          () async {
            final sandbox = (fs.directory('/sandbox')..createSync());
            try {
              final project = fs.directory(
                fs.path.join(sandbox.path, 'project'),
              )..createSync();
              final home = fs.directory(fs.path.join(sandbox.path, 'home'))
                ..createSync();
              final claude = fs.directory(
                fs.path.join(sandbox.path, 'claude-config'),
              )..createSync();
              final codex = fs.directory(
                fs.path.join(sandbox.path, 'codex-home'),
              )..createSync();
              final state = fs.directory(fs.path.join(sandbox.path, 'state'));
              for (final (root, name) in [
                (fs.path.join(claude.path, 'skills'), 'from-claude'),
                (fs.path.join(codex.path, 'skills'), 'from-codex'),
                (fs.path.join(home.path, '.agents', 'skills'), 'from-shared'),
              ]) {
                fs
                    .directory(fs.path.join(root, name))
                    .createSync(recursive: true);
              }
              final separator = fs.path.separator;
              final result =
                  await createExecutor(
                    skillLifecycle: SkillLifecycleService(fileSystem: fs),
                  ).fake().execute([
                    'skill',
                    'list',
                    '--cwd',
                    '${project.path}$separator',
                    '--project-root',
                    '${project.path}$separator',
                    '--home',
                    '${home.path}$separator',
                    '--claude-config-dir',
                    '${claude.path}$separator',
                    '--codex-home',
                    '${codex.path}$separator',
                    '--state-dir',
                    '${state.path}$separator',
                    '--format',
                    'json',
                  ]);
              expect(
                result,
                isA<MambaSuccessResult>()
                    .having((value) => value.exitCode, 'exit code', 0)
                    .having((value) => value.output, 'output', isNotNull),
                reason: result is MambaFailureResult ? result.message : null,
              );
              final report = jsonDecode(
                (result as MambaSuccessResult).output!,
              ) as Map<String, Object?>;
              final data = report['data']! as Map<String, Object?>;
              expect(data['scope'], 'user');
              final occurrences = data['occurrences']! as List<Object?>;
              expect(occurrences, hasLength(3));
              for (final occurrence
                  in occurrences.cast<Map<String, Object?>>()) {
                expect(occurrence['installationScope'], 'user');
                expect(occurrence['management'], 'unmanaged');
              }
              expect(state.existsSync(), isFalse);
            } finally {
              await sandbox.delete(recursive: true);
            }
          },
        );

        test('user and all are distinguished from project inventory', () async {
          final sandbox = (fs.directory('/sandbox')..createSync());
          try {
            final project = fs.directory(fs.path.join(sandbox.path, 'project'))
              ..createSync();
            final home = fs.directory(fs.path.join(sandbox.path, 'home'))
              ..createSync();
            final state = fs.path.join(sandbox.path, 'state');
            fs
                .directory(
                  fs.path.join(
                    project.path,
                    '.claude',
                    'skills',
                    'project-skill',
                  ),
                )
                .createSync(recursive: true);
            fs
                .directory(
                  fs.path.join(home.path, '.agents', 'skills', 'user-skill'),
                )
                .createSync(recursive: true);
            final separator = fs.path.separator;
            Future<Map<String, Object?>> inventory(String scope) async {
              final result =
                  await createExecutor(
                    skillLifecycle: SkillLifecycleService(fileSystem: fs),
                  ).fake().execute([
                    'skill',
                    'list',
                    '--scope',
                    scope,
                    '--cwd',
                    '${project.path}$separator',
                    '--project-root',
                    '${project.path}$separator',
                    '--home',
                    '${home.path}$separator',
                    '--state-dir',
                    '$state$separator',
                    '--format',
                    'json',
                  ]);
              expect(result, isA<MambaSuccessResult>());
              return jsonDecode((result as MambaSuccessResult).output!)
                  as Map<String, Object?>;
            }

            final projectData =
                (await inventory('project'))['data'] as Map<String, Object?>;
            final userData =
                (await inventory('user'))['data'] as Map<String, Object?>;
            final allData =
                (await inventory('all'))['data'] as Map<String, Object?>;
            expect(projectData['occurrences'], hasLength(1));
            expect(userData['occurrences'], hasLength(1));
            expect(allData['occurrences'], hasLength(2));
          } finally {
            await sandbox.delete(recursive: true);
          }
        });

        test(
          'invalid user home input is a handled failure with no stdout',
          () async {
            final result =
                await createExecutor(
                  skillLifecycle: SkillLifecycleService(fileSystem: fs),
                ).fake().execute([
                  'skill',
                  'list',
                  '--home',
                  'missing-separator',
                  '--format',
                  'json',
                ]);
            expect(
              result,
              isA<MambaFailureResult>()
                  .having((value) => value.exitCode, 'exit code', isNonZero)
                  .having((value) => value.output, 'output', isNull)
                  .having((value) => value.message, 'message', isNotEmpty)
                  .having(
                    (value) => value.error.phase,
                    'phase',
                    MambaExecutionPhase.parse,
                  )
                  .having((value) => value.error.commandPath, 'command path', [
                    'agent_resource',
                    'skill',
                    'list',
                  ]),
            );
          },
        );
      });
    });
  });
}
