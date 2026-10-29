import 'dart:io';

import 'package:agent_resource/src/services/agent_authoring_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group(AgentAuthoringService, () {
    test('a stale source-bound plan cannot be applied', () async {
      final sandbox = await Directory.systemTemp.createTemp('agent-authoring-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final output = p.join(project.path, '.claude', 'agents', 'reviewer.md');
        final options = LifecycleOptions(
          processWorkingDirectory: project.path,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
          approved: true,
        );
        AuthoringRequest request(String description) => AuthoringRequest(
          operation: AuthoringOperation.create,
          source: null,
          base: null,
          target: <String, Object?>{'harness': 'claude', 'output': output},
          definition: <String, Object?>{
            'name': 'reviewer',
            'description': description,
          },
          instructions: const <String>['Review.'],
          baseInstructions: 'replace',
          decisions: const <String>{},
          references: const <String, String>{},
          context: './',
        );
        final service = AgentAuthoringService();
        final planned = await service.plan(request('Original.'), options);

        await expectLater(
          () => service.run(
            request('Changed after review.'),
            options,
            apply: true,
            planId: planned.result.data['planId']! as String,
          ),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'exit code',
              4,
            ),
          ),
        );
        expect(File(output).existsSync(), isFalse);
        expect(
          Directory(p.join(project.path, '.agent-resource')).existsSync(),
          isFalse,
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test('plan identity is independent of native field map order', () async {
      final sandbox = await Directory.systemTemp.createTemp('agent-authoring-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final options = LifecycleOptions(
          processWorkingDirectory: project.path,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
        );
        AuthoringRequest request(Map<String, Object?> definition) =>
            AuthoringRequest(
              operation: AuthoringOperation.create,
              source: null,
              base: null,
              target: <String, Object?>{
                'harness': 'claude',
                'output': p.join(
                  project.path,
                  '.claude',
                  'agents',
                  'reviewer.md',
                ),
              },
              definition: definition,
              instructions: const <String>['Review.'],
              baseInstructions: 'replace',
              decisions: const <String>{},
              references: const <String, String>{},
              context: './',
            );
        final service = AgentAuthoringService();

        final first = await service.plan(
          request(<String, Object?>{
            'name': 'reviewer',
            'description': 'Reviews.',
            'model': 'claude-sonnet',
            'tools': <Object?>['Read'],
          }),
          options,
        );
        final second = await service.plan(
          request(<String, Object?>{
            'tools': <Object?>['Read'],
            'model': 'claude-sonnet',
            'description': 'Reviews.',
            'name': 'reviewer',
          }),
          options,
        );

        expect(second.content, first.content);
        expect(second.result.data['planId'], first.result.data['planId']);
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'compose reports conflicting base selections until explicitly resolved',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'agent-authoring-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final source = File(p.join(sandbox.path, 'base.md'))
            ..writeAsStringSync('''---
name: reviewer
description: Reviews.
tools: [Read]
---
Base instructions.
''');
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );
          AuthoringRequest request(Set<String> decisions) => AuthoringRequest(
            operation: AuthoringOperation.compose,
            source: null,
            base: <String, Object?>{
              'kind': 'native-file',
              'path': source.path,
              'harness': 'claude',
            },
            target: <String, Object?>{
              'harness': 'claude',
              'output': p.join(
                project.path,
                '.claude',
                'agents',
                'reviewer.md',
              ),
            },
            definition: <String, Object?>{
              'tools': <Object?>['Write'],
            },
            instructions: const <String>['Additional instructions.'],
            baseInstructions: 'include',
            decisions: decisions,
            references: const <String, String>{},
            context: './',
          );
          final service = AgentAuthoringService();

          final unresolved = await service.plan(
            request(const <String>{}),
            options,
          );
          expect(unresolved.result.data['ready'], isFalse);
          expect(
            unresolved.result.diagnostics.toString(),
            contains('FIELD_CONFLICT'),
          );

          final resolved = await service.plan(
            request(const <String>{'field:tools'}),
            options,
          );
          expect(resolved.result.data['ready'], isTrue);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test('clone refuses an implicit cross-harness conversion', () async {
      final sandbox = await Directory.systemTemp.createTemp('agent-authoring-');
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        final source = File(p.join(sandbox.path, 'source.md'))
          ..writeAsStringSync('''---
name: reviewer
description: Reviews.
---
Review.
''');
        final request = AuthoringRequest(
          operation: AuthoringOperation.clone,
          source: <String, Object?>{
            'kind': 'native-file',
            'path': source.path,
            'harness': 'claude',
          },
          base: null,
          target: <String, Object?>{
            'harness': 'codex',
            'output': p.join(project.path, '.codex', 'agents', 'reviewer.toml'),
          },
          definition: const <String, Object?>{},
          instructions: const <String>[],
          baseInstructions: 'retain',
          decisions: const <String>{},
          references: const <String, String>{},
          context: './',
        );
        final options = LifecycleOptions(
          processWorkingDirectory: project.path,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
        );

        await expectLater(
          () => AgentAuthoringService().plan(request, options),
          throwsA(
            isA<MambaException>().having(
              (error) => error.exitCode,
              'exit code',
              2,
            ),
          ),
        );
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'clone reference changes require a separate impact decision',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'agent-authoring-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          for (final skill in const ['original', 'renamed']) {
            final marker = File(
              p.join(project.path, '.claude', 'skills', skill, 'SKILL.md'),
            )..createSync(recursive: true);
            marker.writeAsStringSync(
              '---\nname: $skill\ndescription: Skill.\n---\nBody.\n',
            );
          }
          final source = File(
            p.join(project.path, '.claude', 'agents', 'source.md'),
          )..createSync(recursive: true);
          source.writeAsStringSync('''---
name: reviewer
description: Reviews.
skills: [original]
---
Review.
''');
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );
          AuthoringRequest request(Set<String> decisions) => AuthoringRequest(
            operation: AuthoringOperation.clone,
            source: <String, Object?>{
              'kind': 'native-file',
              'path': source.path,
              'harness': 'claude',
            },
            base: null,
            target: <String, Object?>{
              'harness': 'claude',
              'output': p.join(
                project.path,
                '.claude',
                'agents',
                'reviewer-copy.md',
              ),
            },
            definition: const <String, Object?>{
              'skills': <Object?>['renamed'],
            },
            instructions: const <String>[],
            baseInstructions: 'retain',
            decisions: decisions,
            references: const <String, String>{'skill:original': 'renamed'},
            context: './',
          );
          final service = AgentAuthoringService();

          final unresolved = await service.plan(
            request(const <String>{}),
            options,
          );
          expect(unresolved.result.data['ready'], isFalse);
          expect(
            unresolved.result.diagnostics.toString(),
            contains('REFERENCE_DECISION_REQUIRED'),
          );
          expect(
            unresolved.result.diagnostics.toString(),
            contains('reference:skill:original:renamed'),
          );

          final resolved = await service.plan(
            request(const <String>{'reference:skill:original:renamed'}),
            options,
          );
          expect(resolved.result.data['ready'], isTrue);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'a model rename accepts its explicit reference impact decision',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'agent-authoring-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final source = File(p.join(sandbox.path, 'source.md'))
            ..writeAsStringSync('''---
name: reviewer
description: Reviews.
model: claude-sonnet
---
Review.
''');
          final request = AuthoringRequest(
            operation: AuthoringOperation.clone,
            source: <String, Object?>{
              'kind': 'native-file',
              'path': source.path,
              'harness': 'claude',
            },
            base: null,
            target: <String, Object?>{
              'harness': 'claude',
              'output': p.join(
                project.path,
                '.claude',
                'agents',
                'reviewer-copy.md',
              ),
            },
            definition: const <String, Object?>{'model': 'claude-opus'},
            instructions: const <String>[],
            baseInstructions: 'retain',
            decisions: const <String>{
              'reference:model:claude-sonnet:claude-opus',
            },
            references: const <String, String>{},
            context: './',
          );
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );

          final planned = await AgentAuthoringService().plan(request, options);

          expect(
            planned.result.diagnostics.toString(),
            isNot(contains('REFERENCE_DECISION_REQUIRED')),
          );
          expect(planned.result.data['ready'], isTrue);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'source-only fields require an explicit publication decision',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'agent-authoring-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final source = File(p.join(sandbox.path, 'source.toml'))
            ..writeAsStringSync('''
name = "reviewer"
description = "Reviews."
developer_instructions = "Review."
personality = "pragmatic"
''');
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );
          AuthoringRequest request(Set<String> decisions) => AuthoringRequest(
            operation: AuthoringOperation.clone,
            source: <String, Object?>{
              'kind': 'native-file',
              'path': source.path,
              'harness': 'codex',
            },
            base: null,
            target: <String, Object?>{
              'harness': 'codex',
              'output': p.join(
                project.path,
                '.codex',
                'agents',
                'reviewer-copy.toml',
              ),
            },
            definition: const <String, Object?>{},
            instructions: const <String>[],
            baseInstructions: 'retain',
            decisions: decisions,
            references: const <String, String>{},
            context: './',
          );
          final service = AgentAuthoringService();

          final unresolved = await service.plan(
            request(const <String>{}),
            options,
          );
          expect(unresolved.result.data['ready'], isFalse);
          expect(
            unresolved.result.diagnostics.toString(),
            contains('FIELD_DECISION_REQUIRED'),
          );
          expect(
            unresolved.result.diagnostics.toString(),
            contains('field:personality'),
          );

          final resolved = await service.plan(
            request(const <String>{'field:personality'}),
            options,
          );
          expect(resolved.result.data['ready'], isTrue);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'enforces destination, replacement, and common-Pi field boundaries',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'agent-authoring-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );
          AuthoringRequest request({
            required AuthoringOperation operation,
            required String harness,
            required String output,
            String? installationId,
            Map<String, Object?> definition = const <String, Object?>{},
            Set<String> decisions = const <String>{},
            List<String> instructions = const <String>['Work.'],
          }) => AuthoringRequest(
            operation: operation,
            source: null,
            base: null,
            target: <String, Object?>{
              'harness': harness,
              'output': output,
              'installationId': ?installationId,
            },
            definition: <String, Object?>{
              'name': 'worker',
              'description': 'Works.',
              if (harness == 'pi') ...<String, Object?>{
                'model': 'kimi-coding/k3',
                'tools': 'read',
              },
              ...definition,
            },
            instructions: instructions,
            baseInstructions: 'replace',
            decisions: decisions,
            references: const <String, String>{},
            context: './',
          );
          final service = AgentAuthoringService();

          await expectLater(
            () => service.plan(
              request(
                operation: AuthoringOperation.create,
                harness: 'claude',
                output: p.join(sandbox.path, 'outside.md'),
              ),
              options,
            ),
            throwsA(
              isA<MambaException>().having(
                (error) => error.exitCode,
                'exit code',
                4,
              ),
            ),
          );
          await expectLater(
            () => service.plan(
              request(
                operation: AuthoringOperation.clone,
                harness: 'claude',
                output: p.join(project.path, '.claude', 'agents', 'worker.md'),
                installationId: 'agent_not-a-replacement-authority',
                instructions: const <String>[],
              ),
              options,
            ),
            throwsA(
              isA<MambaException>().having(
                (error) => error.exitCode,
                'exit code',
                4,
              ),
            ),
          );
          final pi = await service.plan(
            request(
              operation: AuthoringOperation.create,
              harness: 'pi',
              output: p.join(project.path, '.pi', 'agents', 'worker.md'),
              definition: <String, Object?>{
                'skills': <Object?>['private-extension'],
              },
              decisions: const <String>{'field:skills'},
            ),
            options,
          );
          expect(pi.result.data['ready'], isFalse);
          expect(
            pi.result.diagnostics.toString(),
            contains('PROVIDER_ONLY_FIELD'),
          );
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
  });
}
