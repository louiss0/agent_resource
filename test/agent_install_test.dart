import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/installation/resource_catalog.dart';
import 'package:agent_resource/src/services/agent_installation_service.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/installation_test_support.dart';

void main() {
  group('agent_resource', () {
    group('agent', () {
      group('install', () {
        late Directory sandbox;
        late Directory project;
        late Directory home;
        late ScriptedInstallationInteraction interaction;

        setUp(() async {
          sandbox = await Directory.systemTemp.createTemp('agent-install-cli-');
          project = Directory(p.join(sandbox.path, 'project'))..createSync();
          home = Directory(p.join(sandbox.path, 'home'))..createSync();
          for (final name in ['claude', 'codex', 'pi']) {
            Directory(p.join(sandbox.path, name)).createSync();
          }
          interaction = ScriptedInstallationInteraction();
        });

        tearDown(() async {
          if (sandbox.existsSync()) await sandbox.delete(recursive: true);
        });

        Executor executor() => createExecutor(
          agentInstallation: AgentInstallationService(
            interaction: interaction,
            progress: noInstallationProgress,
          ),
        );

        File agent({String name = 'reviewer.md'}) =>
            File(p.join(sandbox.path, name))..writeAsStringSync(
              '---\nname: reviewer\ndescription: Reviews.\n---\nAgent body.\n',
            );

        List<String> context() => [
          '--scope',
          'project',
          '--cwd',
          '${project.path}${Platform.pathSeparator}',
          '--project-root',
          '${project.path}${Platform.pathSeparator}',
          '--home',
          '${home.path}${Platform.pathSeparator}',
          '--claude-config-dir',
          '${p.join(sandbox.path, 'claude')}${Platform.pathSeparator}',
          '--codex-home',
          '${p.join(sandbox.path, 'codex')}${Platform.pathSeparator}',
          '--pi-agent-dir',
          '${p.join(sandbox.path, 'pi')}${Platform.pathSeparator}',
          '--state-dir',
          '${p.join(sandbox.path, 'state')}${Platform.pathSeparator}',
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

        test('interactive direct file asks profile but not a redundant target question', () async {
          final source = agent();
          interaction.sources.add(source.path);
          interaction.profiles.add(NativeAgentProfile.claude);
          final result = await executor().fake().execute([
            'agent',
            'install',
            '--cwd',
            '${project.path}${Platform.pathSeparator}',
            '--project-root',
            '${project.path}${Platform.pathSeparator}',
            '--home',
            '${home.path}${Platform.pathSeparator}',
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
          final destination = File(
            p.join(project.path, '.claude', 'agents', 'reviewer.md'),
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
          final collection = Directory(p.join(sandbox.path, 'collection'))
            ..createSync();
          final claude = File(p.join(collection.path, 'claude.md'))
            ..writeAsStringSync(
              '---\nname: reviewer\ndescription: Reviews.\n---\nBody.\n',
            );
          File(p.join(collection.path, 'codex.toml')).writeAsStringSync(
            'name = "reviewer"\ndescription = "Reviews."\ndeveloper_instructions = "Review."\n',
          );
          File(p.join(collection.path, 'agent-resources.toml'))
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
