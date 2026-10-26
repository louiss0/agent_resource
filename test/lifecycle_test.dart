import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

MambaSuccessResult _success(MambaExecutionResult result) {
  expect(
    result,
    isA<MambaSuccessResult>()
        .having((value) => value.exitCode, 'exit code', 0)
        .having((value) => value.output, 'output', isNotNull),
    reason: result is MambaFailureResult ? result.message : null,
  );
  return result as MambaSuccessResult;
}

MambaFailureResult _failure(
  MambaExecutionResult result,
  int status,
  String message, {
  required MambaExecutionPhase phase,
  required List<String> commandPath,
}) {
  expect(
    result,
    isA<MambaFailureResult>()
        .having((value) => value.exitCode, 'exit code', status)
        .having((value) => value.message, 'message', contains(message))
        .having((value) => value.output, 'output', isNull)
        .having((value) => value.error.phase, 'phase', phase)
        .having(
          (value) => value.error.commandPath,
          'command path',
          commandPath,
        ),
  );
  return result as MambaFailureResult;
}

void main() {
  group('agent_resource', () {
    group('skill', () {
      test('help lists lifecycle commands and no discover alias', () async {
        final output = _success(
          await createExecutor().fake().execute(['skill', '--help']),
        ).output!;
        for (final command in [
          'list',
          'install',
          'adopt',
          'replace',
          'remove',
          'backup',
          'recover',
          'inspect',
          'validate',
        ]) {
          expect(output, contains(command));
        }
        expect(output, isNot(contains('discover')));
        expect(output, isNot(contains('link')));
      });

      group('install', () {
        test('dry-run is planned and creates no artifacts', () async {
          final sandbox = await Directory.systemTemp.createTemp(
            'lifecycle-cli-',
          );
          try {
            final project = Directory(p.join(sandbox.path, 'project'))
              ..createSync();
            final home = Directory(p.join(sandbox.path, 'home'))..createSync();
            final source = Directory(p.join(sandbox.path, 'source'))
              ..createSync();
            File(p.join(source.path, 'SKILL.md')).writeAsStringSync(
              '---\nname: review\ndescription: Reviews.\n---\nBody.\n',
            );
            final separator = Platform.pathSeparator;
            final result = _success(
              await createExecutor().fake().execute([
                'skill',
                'install',
                '${source.path}$separator',
                '--destination',
                'claude',
                '--scope',
                'project',
                '--cwd',
                '${project.path}$separator',
                '--project-root',
                '${project.path}$separator',
                '--home',
                '${home.path}$separator',
                '--dry-run',
                '--format',
                'json',
              ]),
            );
            final envelope = jsonDecode(result.output!) as Map<String, Object?>;
            expect(envelope['command'], 'skill install');
            expect(envelope['outcome'], 'planned');
            expect(
              Directory(p.join(project.path, '.agent-resource')).existsSync(),
              isFalse,
            );
            expect(
              Directory(p.join(project.path, '.claude')).existsSync(),
              isFalse,
            );
          } finally {
            await sandbox.delete(recursive: true);
          }
        });

        test(
          'typed paths and JSON/interactive conflicts reject before effects',
          () async {
            final result = await createExecutor().fake().execute([
              'skill',
              'install',
              'missing-separator',
              '--destination',
              'claude',
            ]);
            _failure(
              result,
              1,
              'Invalid path',
              phase: MambaExecutionPhase.parse,
              commandPath: const ['agent_resource', 'skill', 'install'],
            );

            final conflict = await createExecutor().fake().execute([
              'skill',
              'install',
              '..${Platform.pathSeparator}',
              '--destination',
              'claude',
              '--interactive',
              '--format',
              'json',
            ]);
            _failure(
              conflict,
              1,
              'conflict',
              phase: MambaExecutionPhase.run,
              commandPath: const ['agent_resource', 'skill', 'install'],
            );
          },
        );
      });

      group('recover', () {
        test(
          'action without an ID rejects before filesystem effects',
          () async {
            final result = await createExecutor().fake().execute([
              'skill',
              'recover',
              '--action',
              'rollback',
              '--yes',
            ]);
            _failure(
              result,
              1,
              'requires a transaction ID',
              phase: MambaExecutionPhase.run,
              commandPath: const ['agent_resource', 'skill', 'recover'],
            );
          },
        );
      });
    });

    group('agent', () {
      test('help lists regular-file lifecycle commands only', () async {
        final output = _success(
          await createExecutor().fake().execute(['agent', '--help']),
        ).output!;
        for (final command in [
          'list',
          'install',
          'adopt',
          'replace',
          'remove',
          'backup',
          'recover',
          'inspect',
          'validate',
        ]) {
          expect(output, contains(command));
        }
        for (final unsupported in ['register', 'compose', 'convert', 'clone']) {
          expect(output, isNot(contains(unsupported)));
        }
      });

      group('install', () {
        test('native source requires an explicit harness', () async {
          final result = await createExecutor().fake().execute([
            'agent',
            'install',
            'definition.md',
          ]);
          _failure(
            result,
            1,
            '--harness',
            phase: MambaExecutionPhase.parse,
            commandPath: const ['agent_resource', 'agent', 'install'],
          );
        });
      });
    });
  });
}
