import 'dart:io';

import 'package:agent_resource/src/agent_inspection.dart';
import 'package:agent_resource/src/services/agent_conversion_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group(AgentConversionService, () {
    const instructions = 'Review correctness.\n';
    final cases = <({AgentHarness source, AgentHarness target})>[
      (source: AgentHarness.claude, target: AgentHarness.codex),
      (source: AgentHarness.claude, target: AgentHarness.pi),
      (source: AgentHarness.codex, target: AgentHarness.claude),
      (source: AgentHarness.codex, target: AgentHarness.pi),
      (source: AgentHarness.pi, target: AgentHarness.claude),
      (source: AgentHarness.pi, target: AgentHarness.codex),
    ];
    for (final testCase in cases) {
      test(
        '${testCase.source.name} to ${testCase.target.name} produces valid native output',
        () async {
          final sandbox = await Directory.systemTemp.createTemp(
            'agent-conversion-',
          );
          try {
            final project = Directory(p.join(sandbox.path, 'project'))
              ..createSync();
            final home = Directory(p.join(sandbox.path, 'home'))..createSync();
            final source = File(
              p.join(
                sandbox.path,
                'source${testCase.source == AgentHarness.codex ? '.toml' : '.md'}',
              ),
            );
            source.writeAsStringSync(switch (testCase.source) {
              AgentHarness.claude =>
                '''---
name: reviewer
description: Reviews changes.
model: claude-sonnet
effort: high
tools: [Read, Grep]
---
$instructions''',
              AgentHarness.codex =>
                '''name = "reviewer"
description = "Reviews changes."
model = "openai/gpt-5"
model_reasoning_effort = "high"
developer_instructions = "Review correctness.\\n"
''',
              AgentHarness.pi =>
                '''---
name: reviewer
description: Reviews changes.
model: kimi-coding/k3
thinking: high
tools: read, grep
---
$instructions''',
            });
            final sourceBytes = source.readAsBytesSync();
            final targetDefinition = <String, Object?>{
              'model': switch (testCase.target) {
                AgentHarness.claude => 'claude-sonnet',
                AgentHarness.codex => 'openai/gpt-5',
                AgentHarness.pi => 'kimi-coding/k3',
              },
              switch (testCase.target) {
                AgentHarness.claude => 'effort',
                AgentHarness.codex => 'model_reasoning_effort',
                AgentHarness.pi => 'thinking',
              }: 'high',
              if (testCase.target == AgentHarness.pi) 'tools': 'read, grep',
              if (testCase.target == AgentHarness.claude)
                'tools': <Object?>['Read'],
            };
            final request = ConversionRequest(
              source: <String, Object?>{
                'kind': 'native-file',
                'path': source.path,
                'harness': testCase.source.name,
              },
              target: <String, Object?>{
                'harness': testCase.target.name,
                'output': p.join(
                  project.path,
                  '.${testCase.target.name}',
                  'agents',
                  'reviewer${testCase.target == AgentHarness.codex ? '.toml' : '.md'}',
                ),
              },
              context: './',
              definition: targetDefinition,
              decisions: <String>{
                'map:model',
                'map:effort',
                if (testCase.target == AgentHarness.pi ||
                    testCase.target == AgentHarness.claude)
                  'map:tools',
                if (testCase.source != AgentHarness.codex &&
                    testCase.target == AgentHarness.codex)
                  'omit:tools',
              },
              references: const <String, String>{},
            );
            final options = LifecycleOptions(
              processWorkingDirectory: project.path,
              cwd: project.path,
              projectRoot: project.path,
              home: home.path,
            );

            final plan = await AgentConversionService().plan(request, options);

            expect(
              plan.result.data['ready'],
              isTrue,
              reason: plan.result.diagnostics.toString(),
            );
            final candidate = inspectNativeAgentContent(
              content: plan.authoring.content,
              harness: testCase.target,
            );
            expect(
              candidate.hasErrors,
              isFalse,
              reason: candidate.diagnostics.toString(),
            );
            expect(candidate.instructionText, instructions);
            expect(
              candidate.identity['name'],
              isA<Map<String, Object?>>().having(
                (value) => value['resolved'],
                'name',
                'reviewer',
              ),
            );
            expect(candidate.nativeFields['model'], targetDefinition['model']);
            expect(source.readAsBytesSync(), sourceBytes);
            final output = File(request.target['output']! as String);
            expect(output.existsSync(), isFalse);

            final applied = await AgentConversionService().run(
              request,
              options.copyWith(approved: true),
              apply: true,
              planId: plan.result.data['planId']! as String,
            );
            expect(applied.outcome, 'converted');
            expect(output.existsSync(), isTrue);
            final published = inspectNativeAgent(
              AgentInspectionInput(
                nativeFile: output.path,
                harness: testCase.target,
              ),
              operation: AgentOperation.validate,
            );
            expect(published.hasErrors, isFalse);
            expect(published.instructionText, instructions);
            expect(source.readAsBytesSync(), sourceBytes);
          } finally {
            await sandbox.delete(recursive: true);
          }
        },
      );
    }

    test('altered controls require their explicit mapping decisions', () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'agent-conversion-',
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
effort: high
tools: [Read]
---
Review.
''');
        final output = p.join(
          project.path,
          '.codex',
          'agents',
          'reviewer.toml',
        );
        final plan = await AgentConversionService().plan(
          ConversionRequest(
            source: <String, Object?>{
              'kind': 'native-file',
              'path': source.path,
              'harness': 'claude',
            },
            target: <String, Object?>{'harness': 'codex', 'output': output},
            context: './',
            definition: <String, Object?>{
              'model': 'openai/gpt-5',
              'model_reasoning_effort': 'high',
            },
            decisions: const <String>{'omit:tools'},
            references: const <String, String>{},
          ),
          LifecycleOptions(
            processWorkingDirectory: project.path,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          ),
        );

        expect(plan.result.data['ready'], isFalse);
        final fields = plan.result.data['fields']! as List<Object?>;
        final model =
            fields.singleWhere(
                  (field) =>
                      (field! as Map<String, Object?>)['sourcePath'] == 'model',
                )!
                as Map<String, Object?>;
        final effort =
            fields.singleWhere(
                  (field) =>
                      (field! as Map<String, Object?>)['sourcePath'] ==
                      'effort',
                )!
                as Map<String, Object?>;
        expect(model['outcome'], 'unresolved');
        expect(effort['outcome'], 'unresolved');
        expect(File(output).existsSync(), isFalse);
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'an explicit Skill mapping changes the proposed native association',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'agent-conversion-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final source = File(p.join(sandbox.path, 'source.toml'))
            ..writeAsStringSync('''name = "reviewer"
description = "Reviews."
model = "openai/gpt-5"
model_reasoning_effort = "high"
developer_instructions = "Review."

[skills]
config = [{ path = "old", enabled = false }]
''');
          final skill =
              File(p.join(project.path, '.claude', 'skills', 'new', 'SKILL.md'))
                ..createSync(recursive: true)
                ..writeAsStringSync('''---
name: new
description: New target Skill.
---
Skill body.
''');
          final plan = await AgentConversionService().plan(
            ConversionRequest(
              source: <String, Object?>{
                'kind': 'native-file',
                'path': source.path,
                'harness': 'codex',
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
              context: './',
              definition: <String, Object?>{
                'model': 'claude-sonnet',
                'effort': 'high',
                'tools': <Object?>['Read'],
                'skills': <Object?>['old'],
              },
              decisions: const <String>{
                'map:model',
                'map:effort',
                'map:tools',
                'map:skills',
              },
              references: const <String, String>{'skill:old': 'new'},
            ),
            LifecycleOptions(
              processWorkingDirectory: project.path,
              cwd: project.path,
              projectRoot: project.path,
              home: home.path,
            ),
          );

          expect(
            plan.result.data['ready'],
            isTrue,
            reason: plan.result.diagnostics.toString(),
          );
          final candidate = inspectNativeAgentContent(
            content: plan.authoring.content,
            harness: AgentHarness.claude,
          );
          expect(candidate.nativeFields['skills'], <Object?>['new']);
          expect(skill.existsSync(), isTrue);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'a config-bound Codex source retains binding provenance and bytes',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'agent-conversion-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final config = File(p.join(project.path, '.codex', 'config.toml'))
            ..createSync(recursive: true)
            ..writeAsStringSync('''[agents.reviewer]
description = "Reviews from the declaration."
config_file = "roles/reviewer.toml"
''');
          final role =
              File(p.join(project.path, '.codex', 'roles', 'reviewer.toml'))
                ..createSync(recursive: true)
                ..writeAsStringSync(
                  'developer_instructions = "Review the bound role."\n',
                );
          final configBytes = config.readAsBytesSync();
          final roleBytes = role.readAsBytesSync();
          final output = p.join(
            project.path,
            '.claude',
            'agents',
            'reviewer.md',
          );
          final request = ConversionRequest(
            source: <String, Object?>{
              'kind': 'codex-role',
              'configFile': config.path,
              'roleKey': 'reviewer',
            },
            target: <String, Object?>{'harness': 'claude', 'output': output},
            context: './',
            definition: <String, Object?>{
              'model': 'claude-sonnet',
              'effort': 'high',
              'tools': <Object?>['Read'],
            },
            decisions: const <String>{'map:model', 'map:effort', 'map:tools'},
            references: const <String, String>{},
          );
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );

          final plan = await AgentConversionService().plan(request, options);

          expect(
            plan.result.data['ready'],
            isTrue,
            reason: plan.result.diagnostics.toString(),
          );
          expect(plan.result.data['sourceForm'], 'codex-config-bound-role');
          expect(
            plan.result.data['sourceBinding'],
            isA<Map<String, Object?>>().having(
              (value) => value['roleKey'],
              'role key',
              'reviewer',
            ),
          );
          expect(plan.authoring.content, contains('Review the bound role.'));
          final effort = (plan.result.data['fields']! as List<Object?>)
              .map((field) => field! as Map<String, Object?>)
              .singleWhere((field) => field['targetPath'] == 'effort');
          expect(effort['sourcePath'], isNull);
          expect(effort['outcome'], 'represented');
          expect(config.readAsBytesSync(), configBytes);
          expect(role.readAsBytesSync(), roleBytes);
          expect(File(output).existsSync(), isFalse);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
  });
}
