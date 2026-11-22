import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/installation/resource_catalog.dart';
import 'package:agent_resource/src/services/agent_installation_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

import 'support/installation_test_support.dart';

void main() {
  group('agent_resource', () {
    group('agent', () {
      group('install', () {
        late fslib.FileSystem fs;
        late fslib.Directory sandbox;
        late Directory project;
        late Directory home;
        late ScriptedInstallationInteraction interaction;

        setUp(() async {
          fs = MemoryFileSystem(style: FileSystemStyle.posix);
          sandbox = fs.directory('/sandbox')..createSync();
          project = fs.directory(fs.path.join(sandbox.path, 'project'))
            ..createSync();
          home = fs.directory(fs.path.join(sandbox.path, 'home'))..createSync();
          for (final name in [
            'claude',
            'codex',
            'pi',
            'antigravity',
            'state',
          ]) {
            fs.directory(fs.path.join(sandbox.path, name)).createSync();
          }
          fs
              .directory(fs.path.join(sandbox.path, 'antigravity', 'config'))
              .createSync(recursive: true);
          interaction = ScriptedInstallationInteraction();
        });

        tearDown(() async {
          if (sandbox.existsSync()) await sandbox.delete(recursive: true);
        });

        Executor executor() => createExecutor(
          agentInstallation: AgentInstallationService(
            interaction: interaction,
            fileSystem: fs,
            progress: noInstallationProgress,
          ),
        );

        fslib.File agent({String name = 'reviewer.md'}) =>
            fs.file(fs.path.join(sandbox.path, name))..writeAsStringSync(
              '---\nname: reviewer\ndescription: Reviews.\n---\nAgent body.\n',
            );

        List<String> context() => [
          '--scope',
          'project',
          '--cwd',
          '${project.path}${fs.path.separator}',
          '--project-root',
          '${project.path}${fs.path.separator}',
          '--home',
          '${home.path}${fs.path.separator}',
          '--claude-config-dir',
          '${fs.path.join(sandbox.path, 'claude')}${fs.path.separator}',
          '--codex-home',
          '${fs.path.join(sandbox.path, 'codex')}${fs.path.separator}',
          '--pi-agent-dir',
          '${fs.path.join(sandbox.path, 'pi')}${fs.path.separator}',
          '--gemini-dir',
          '${fs.path.join(sandbox.path, 'antigravity')}${fs.path.separator}',
          '--state-dir',
          '${fs.path.join(sandbox.path, 'state')}${fs.path.separator}',
        ];

        test('exact unattended dry-run requires and preserves explicit native profile', () async {
          final source = agent();
          final result = await executor().fake().execute([
            'agent',
            'install',
            source.path,
            '--source-kind',
            'resource',
            '--profile',
            'claude',
            '--target',
            'claude',
            ...context(),
            '--dry-run',
            '--format',
            'json',
          ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          final envelope = jsonDecode(
            (result as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          expect(envelope['schemaVersion'], 2);
          expect(envelope['outcome'], 'planned');
          final data = envelope['data']! as Map<String, Object?>;
          final unit =
              (data['units']! as List<Object?>).single! as Map<String, Object?>;
          expect(unit['profile'], 'claude');
          expect(unit['method'], 'copy');
          expect(unit['nativeName'], 'reviewer');
          expect(project.listSync(recursive: true), isEmpty);
        });

        test(
          'interactive collection applies project target preference',
          () async {
            final collection = fs.directory('/sandbox/collection')
              ..createSync();
            fs
                .file('${collection.path}/agent-resources.toml')
                .writeAsStringSync('''
schema_version = 1
[[agents]]
id = "claude-reviewer"
path = "claude.md"
profile = "claude"
[[agents]]
id = "codex-reviewer"
path = "codex.md"
profile = "codex"
''');
            for (final name in ['claude', 'codex']) {
              fs
                  .file('${collection.path}/$name.md')
                  .writeAsStringSync(
                    '---\nname: reviewer\ndescription: Reviews.\n---\nBody.\n',
                  );
            }
            fs.file('${project.path}/agent-resources.toml').writeAsStringSync(
              '''
schema_version = 1
[cli.install]
targets = ["claude"]
''',
            );
            interaction.resourceSelections.add(['claude-reviewer']);
            final result = await executor().fake().execute([
              'agent',
              'install',
              collection.path,
              ...context(),
              '--dry-run',
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            final output = (result as MambaSuccessResult).output!;
            expect(output, contains('Profile: claude'));
            expect(output, contains('project-config'));
            expect(output, isNot(contains('codex-reviewer')));
          },
        );

        test(
          'interactive exact Agent rejects a conflicting target preference',
          () async {
            final source = agent();
            fs
                .file('${project.path}/agent-resources.toml')
                .writeAsStringSync(
                  'schema_version = 1\n[cli.install]\ntargets = ["codex"]\n',
                );
            final result = await executor().fake().execute([
              'agent',
              'install',
              source.path,
              '--profile',
              'claude',
              ...context(),
              '--dry-run',
            ]);
            expect(
              result,
              isA<MambaFailureResult>().having(
                (r) => r.message,
                'message',
                contains('No Agent resources match the preferred targets'),
              ),
            );
            expect(
              fs.directory('${project.path}/.claude').existsSync(),
              isFalse,
            );
          },
        );

        for (final scenario in [
          (
            targets: '"codex", "claude"',
            explicit: false,
            origin: 'project-config',
          ),
          (targets: '"codex"', explicit: true, origin: 'explicit-argument'),
        ]) {
          test(
            'interactive exact Agent accepts matching or explicit target $scenario',
            () async {
              final source = agent();
              fs
                  .file('${project.path}/agent-resources.toml')
                  .writeAsStringSync(
                    'schema_version = 1\n[cli.install]\ntargets = [${scenario.targets}]\n',
                  );
              final result = await executor().fake().execute([
                'agent',
                'install',
                source.path,
                '--profile',
                'claude',
                if (scenario.explicit) ...['--target', 'claude'],
                ...context(),
                '--dry-run',
              ]);
              expect(
                result,
                isA<MambaSuccessResult>(),
                reason: result is MambaFailureResult ? result.message : null,
              );
              final output = (result as MambaSuccessResult).output!;
              expect(output, contains('Profile: claude'));
              expect(output, contains(scenario.origin));
            },
          );
        }

        test(
          'interactive exact Agent rejects an incompatible explicit target',
          () async {
            final source = agent();
            final result = await executor().fake().execute([
              'agent',
              'install',
              source.path,
              '--profile',
              'claude',
              '--target',
              'codex',
              ...context(),
              '--dry-run',
            ]);
            expect(
              result,
              isA<MambaFailureResult>().having(
                (r) => r.message,
                'message',
                contains('consistent with --profile'),
              ),
            );
          },
        );

        test(
          'interactive Agent install can save only its target preference',
          () async {
            final source = agent();
            interaction.approvals.add(true);
            interaction.preferenceSaves.add(true);
            final result = await executor().fake().execute([
              'agent',
              'install',
              source.path,
              '--profile',
              'claude',
              ...context(),
            ]);
            expect(
              result,
              isA<MambaSuccessResult>(),
              reason: result is MambaFailureResult ? result.message : null,
            );
            expect(interaction.preferenceOffers, [
              ['cli.install.targets=claude'],
            ]);
            expect(
              fs
                  .file('${project.path}/agent-resources.toml')
                  .readAsStringSync(),
              contains('targets = ["claude"]'),
            );
          },
        );

        test('interactive direct file asks profile but not a redundant target question', () async {
          final source = agent();
          interaction.sources.add(source.path);
          interaction.profiles.add(NativeAgentProfile.claude);
          final result = await executor().fake().execute([
            'agent',
            'install',
            '--cwd',
            '${project.path}${fs.path.separator}',
            '--project-root',
            '${project.path}${fs.path.separator}',
            '--home',
            '${home.path}${fs.path.separator}',
            '--dry-run',
          ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          expect(
            (result as MambaSuccessResult).output,
            contains('Profile: claude'),
          );
          final output = result.output!;
          expect(output, contains('Explicit command'));
          expect(output, contains('--profile claude'));
          expect(output, contains('--target claude'));
          expect(output, contains('--source-kind resource'));
          final command = output.split('\n').last.split('): ').last;
          final shell = await Process.run(
            Platform.isWindows ? 'powershell.exe' : 'sh',
            Platform.isWindows
                ? [
                    '-NoProfile',
                    '-Command',
                    'function agent_resource { \$args | ConvertTo-Json -Compress }; $command',
                  ]
                : [
                    '-c',
                    'agent_resource() { printf "%s\\n" "\$@"; }; $command',
                  ],
          );
          expect(shell.exitCode, 0, reason: '${shell.stderr}');
          final args = Platform.isWindows
              ? (jsonDecode(shell.stdout as String) as List).cast<String>()
              : (shell.stdout as String).trimRight().split('\n');
          final replay = await createExecutor(
            fileSystem: fs,
            agentInstallation: AgentInstallationService(
              fileSystem: fs,
              interaction: ScriptedInstallationInteraction(interactive: false),
              progress: noInstallationProgress,
            ),
          ).fake().execute(args);
          expect(
            replay,
            isA<MambaSuccessResult>(),
            reason: replay is MambaFailureResult ? replay.message : null,
          );
          expect(
            (replay as MambaSuccessResult).output,
            contains('Profile: claude'),
          );
          expect(interaction.targetSelections, isEmpty);
          expect(interaction.approvals, isEmpty);
        });

        test('unattended apply publishes a native file copy and repeat is unchanged', () async {
          final source = agent();
          final original = source.readAsBytesSync();
          final args = [
            'agent',
            'install',
            source.path,
            '--source-kind',
            'resource',
            '--profile',
            'claude',
            '--target',
            'claude',
            ...context(),
            '--yes',
            '--format',
            'json',
          ];
          final first = await executor().fake().execute(args);
          expect(
            first,
            isA<MambaSuccessResult>(),
            reason: first is MambaFailureResult ? first.message : null,
          );
          final installed = jsonDecode(
            (first as MambaSuccessResult).output!,
          ) as Map<String, Object?>;
          expect(installed['outcome'], 'installed');
          final destination = fs.file(
            fs.path.join(project.path, '.claude', 'agents', 'reviewer.md'),
          );
          expect(destination.readAsBytesSync(), original);
          expect(source.readAsBytesSync(), original);

          final second = await executor().fake().execute(args);
          expect(
            second,
            isA<MambaSuccessResult>(),
            reason: second is MambaFailureResult ? second.message : null,
          );
          expect(
            jsonDecode((second as MambaSuccessResult).output!)['outcome'],
            'unchanged',
          );
        });

        test('curated profiles filter before selection and direct profile is rejected', () async {
          final collection = fs.directory(
            fs.path.join(sandbox.path, 'collection'),
          )..createSync();
          final claude = fs.file(fs.path.join(collection.path, 'claude.md'))
            ..writeAsStringSync(
              '---\nname: reviewer\ndescription: Reviews.\n---\nBody.\n',
            );
          fs
              .file(fs.path.join(collection.path, 'codex.toml'))
              .writeAsStringSync(
                'name = "reviewer"\ndescription = "Reviews."\ndeveloper_instructions = "Review."\n',
              );
          fs
              .file(fs.path.join(collection.path, 'agent-resources.toml'))
              .writeAsStringSync('''
schema_version = 1
[[agents]]
id = "reviewer-claude"
path = "claude.md"
profile = "claude"
[[agents]]
id = "reviewer-codex"
path = "codex.toml"
profile = "codex"
''');
          interaction.resourceSelections.add(['reviewer-claude']);
          final result = await executor().fake().execute([
            'agent',
            'install',
            collection.path,
            '--target',
            'claude',
            ...context(),
            '--dry-run',
          ]);
          expect(
            result,
            isA<MambaSuccessResult>(),
            reason: result is MambaFailureResult ? result.message : null,
          );
          expect(
            (result as MambaSuccessResult).output,
            contains('reviewer-claude'),
          );
          expect(claude.existsSync(), isTrue);

          final conflict = await executor().fake().execute([
            'agent',
            'install',
            collection.path,
            '--profile',
            'claude',
            '--target',
            'claude',
            '--resource',
            'reviewer-claude',
            ...context(),
            '--dry-run',
            '--format',
            'json',
          ]);
          expect(conflict, isA<MambaFailureResult>());
          expect(
            (conflict as MambaFailureResult).message,
            contains('catalog entries'),
          );
          expect(project.listSync(recursive: true), isEmpty);
        });

        test(
          'retired and inapplicable selectors reject before native writes',
          () async {
            final source = agent();
            for (final testCase in [
              (args: ['--harness', 'claude'], message: '--profile'),
              (args: ['--method', 'copy'], message: 'copy-only'),
              (args: ['--interactive'], message: 'retired'),
            ]) {
              final result = await executor().fake().execute([
                'agent',
                'install',
                source.path,
                ...testCase.args,
              ]);
              expect(result, isA<MambaFailureResult>());
              expect(
                (result as MambaFailureResult).message,
                contains(testCase.message),
              );
              expect(result.output, isNull);
            }
            expect(project.listSync(recursive: true), isEmpty);
          },
        );

        test(
          'mismatched direct target/profile fails without a destination',
          () async {
            final source = agent();
            final result = await executor().fake().execute([
              'agent',
              'install',
              source.path,
              '--source-kind',
              'resource',
              '--profile',
              'claude',
              '--target',
              'codex',
              ...context(),
              '--dry-run',
              '--format',
              'json',
            ]);
            expect(result, isA<MambaFailureResult>());
            expect(
              (result as MambaFailureResult).message,
              contains('consistent'),
            );
            expect(project.listSync(recursive: true), isEmpty);
          },
        );
      });
    });
  });
}
