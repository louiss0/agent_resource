import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('agent_resource', () {
    group('skill', () {
      group('list', () {
        test(
          'user is the default scope and native home overrides are isolated',
          () async {
            final sandbox = await Directory.systemTemp.createTemp(
              'skill-user-list-',
            );
            try {
              final project = Directory(p.join(sandbox.path, 'project'))
                ..createSync();
              final home = Directory(p.join(sandbox.path, 'home'))
                ..createSync();
              final claude = Directory(p.join(sandbox.path, 'claude-config'))
                ..createSync();
              final codex = Directory(p.join(sandbox.path, 'codex-home'))
                ..createSync();
              final state = Directory(p.join(sandbox.path, 'state'));
              for (final (root, name) in [
                (p.join(claude.path, 'skills'), 'from-claude'),
                (p.join(codex.path, 'skills'), 'from-codex'),
                (p.join(home.path, '.agents', 'skills'), 'from-shared'),
              ]) {
                Directory(p.join(root, name)).createSync(recursive: true);
              }
              final separator = Platform.pathSeparator;
              final result = await createExecutor().fake().execute([
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
          final sandbox = await Directory.systemTemp.createTemp(
            'skill-scopes-',
          );
          try {
            final project = Directory(p.join(sandbox.path, 'project'))
              ..createSync();
            final home = Directory(p.join(sandbox.path, 'home'))..createSync();
            final state = p.join(sandbox.path, 'state');
            Directory(
              p.join(project.path, '.claude', 'skills', 'project-skill'),
            ).createSync(recursive: true);
            Directory(p.join(home.path, '.agents', 'skills', 'user-skill'))
                .createSync(recursive: true);
            final separator = Platform.pathSeparator;
            Future<Map<String, Object?>> inventory(String scope) async {
              final result = await createExecutor().fake().execute([
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
            final result = await createExecutor().fake().execute([
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
