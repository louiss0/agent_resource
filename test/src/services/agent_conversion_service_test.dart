import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/agent_inspection.dart';
import 'package:agent_resource/src/services/agent_conversion_service.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:mamba/mamba.dart';
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

    test('source Skill associations require source-bound mappings', () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'agent-conversion-',
      );
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        for (final skill in const ['old', 'new']) {
          File(p.join(project.path, '.claude', 'skills', skill, 'SKILL.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync(
              '---\nname: $skill\ndescription: Skill.\n---\nBody.\n',
            );
        }
        final source = File(p.join(sandbox.path, 'source.toml'))
          ..writeAsStringSync('''
name = "reviewer"
description = "Reviews."
model = "openai/gpt-5"
model_reasoning_effort = "high"
developer_instructions = "Review."

[skills]
config = [{ path = "old", enabled = false }]
''');
        final options = LifecycleOptions(
          processWorkingDirectory: project.path,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
        );
        ConversionRequest request(
          String targetSkill,
          Map<String, String> references,
        ) => ConversionRequest(
          source: <String, Object?>{
            'kind': 'native-file',
            'path': source.path,
            'harness': 'codex',
          },
          target: <String, Object?>{
            'harness': 'claude',
            'output': p.join(project.path, '.claude', 'agents', 'reviewer.md'),
          },
          context: './',
          definition: <String, Object?>{
            'model': 'claude-sonnet',
            'effort': 'high',
            'tools': <Object?>['Read'],
            'skills': <Object?>[targetSkill],
          },
          decisions: const <String>{
            'map:model',
            'map:effort',
            'map:tools',
            'map:skills',
          },
          references: references,
        );
        final service = AgentConversionService();
        Map<String, Object?> referenceField(
          LifecycleResult result,
          String sourcePath,
        ) => (result.data['fields']! as List<Object?>)
            .map((field) => field! as Map<String, Object?>)
            .singleWhere((field) => field['sourcePath'] == sourcePath);

        final unmapped = await service.plan(
          request('old', const <String, String>{}),
          options,
        );
        expect(unmapped.result.data['ready'], isFalse);
        final unmappedReference = referenceField(
          unmapped.result,
          'reference:skill:old',
        );
        expect(unmappedReference['outcome'], 'unresolved');
        expect(unmappedReference['decision'], isNull);

        final fictitious = await service.plan(
          request('new', const <String, String>{'skill:ghost': 'new'}),
          options,
        );
        expect(fictitious.result.data['ready'], isFalse);
        expect(
          referenceField(fictitious.result, 'reference:skill:ghost')['outcome'],
          'unresolved',
        );

        final mapped = await service.plan(
          request('new', const <String, String>{'skill:old': 'new'}),
          options,
        );
        expect(
          mapped.result.data['ready'],
          isTrue,
          reason: mapped.result.diagnostics.toString(),
        );
        final mappedReference = referenceField(
          mapped.result,
          'reference:skill:old',
        );
        expect(mappedReference['outcome'], 'altered');
        expect(mappedReference['targetPath'], 'reference:skill:new');
        expect(mappedReference['decision'], 'reference:skill:old');
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'a removal decision cannot publish a target that keeps the association',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'agent-conversion-',
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

[skills]
config = [{ path = "old", enabled = false }]
''');
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );
          ConversionRequest request(
            Map<String, Object?> definition, {
            required Set<String> decisions,
          }) => ConversionRequest(
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
            definition: definition,
            decisions: decisions,
            references: const <String, String>{},
          );
          const base = <String>{'map:model', 'map:effort', 'map:tools'};
          final service = AgentConversionService();

          final conflicting = await service.plan(
            request(
              <String, Object?>{
                'model': 'claude-sonnet',
                'effort': 'high',
                'tools': <Object?>['Read'],
                'skills': <Object?>['old'],
              },
              decisions: <String>{
                ...base,
                'map:skills',
                'reference:skill:old:remove',
              },
            ),
            options,
          );
          expect(conflicting.result.data['ready'], isFalse);
          final conflict = (conflicting.result.data['fields']! as List<Object?>)
              .map((field) => field! as Map<String, Object?>)
              .singleWhere(
                (field) => field['sourcePath'] == 'reference:skill:old',
              );
          expect(conflict['outcome'], 'unresolved');
          expect(conflict['evidence'].toString(), contains('conflicts'));

          final omitted = await service.plan(
            request(
              <String, Object?>{
                'model': 'claude-sonnet',
                'effort': 'high',
                'tools': <Object?>['Read'],
              },
              decisions: <String>{
                ...base,
                'omit:skills',
                'reference:skill:old:remove',
              },
            ),
            options,
          );
          expect(
            omitted.result.data['ready'],
            isTrue,
            reason: omitted.result.diagnostics.toString(),
          );
          final removal = (omitted.result.data['fields']! as List<Object?>)
              .map((field) => field! as Map<String, Object?>)
              .singleWhere(
                (field) => field['sourcePath'] == 'reference:skill:old',
              );
          expect(removal['outcome'], 'omitted');
          expect(removal['targetPath'], isNull);
          expect(removal['decision'], 'reference:skill:old:remove');
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

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
            stateDir: p.join(sandbox.path, 'state'),
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
          expect(effort['outcome'], 'altered');
          expect(config.readAsBytesSync(), configBytes);
          expect(role.readAsBytesSync(), roleBytes);
          expect(File(output).existsSync(), isFalse);

          final applied = await AgentConversionService().run(
            request,
            options.copyWith(approved: true),
            apply: true,
            planId: plan.result.data['planId']! as String,
          );
          expect(applied.outcome, 'converted');
          expect(File(output).existsSync(), isTrue);
          expect(
            File(output).readAsStringSync(),
            contains('Review the bound role.'),
          );
          expect(config.readAsBytesSync(), configBytes);
          expect(role.readAsBytesSync(), roleBytes);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );
    test('model and tool inheritance require deliberate selections', () async {
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
        final options = LifecycleOptions(
          processWorkingDirectory: project.path,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
        );
        ConversionRequest request(Set<String> decisions) => ConversionRequest(
          source: <String, Object?>{
            'kind': 'native-file',
            'path': source.path,
            'harness': 'claude',
          },
          target: <String, Object?>{
            'harness': 'codex',
            'output': p.join(project.path, '.codex', 'agents', 'reviewer.toml'),
          },
          context: './',
          definition: const <String, Object?>{'model_reasoning_effort': 'high'},
          decisions: decisions,
          references: const <String, String>{},
        );
        final service = AgentConversionService();

        final unresolved = await service.plan(
          request(const <String>{'map:effort'}),
          options,
        );
        expect(unresolved.result.data['ready'], isFalse);

        final resolved = await service.plan(
          request(const <String>{
            'map:effort',
            'inherit:model',
            'inherit:tools',
          }),
          options,
        );
        expect(
          resolved.result.data['ready'],
          isTrue,
          reason: resolved.result.diagnostics.toString(),
        );
        final fields = resolved.result.data['fields']! as List<Object?>;
        for (final path in const ['model', 'tools']) {
          final field = fields
              .map((entry) => entry! as Map<String, Object?>)
              .singleWhere((entry) => entry['sourcePath'] == path);
          expect(field['outcome'], 'inherited');
          expect(field['targetPath'], isNull);
          expect(field['decision'], 'inherit:$path');
        }
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'a target-only association requires an explicit field mapping',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'agent-conversion-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          File(p.join(project.path, '.claude', 'skills', 'new', 'SKILL.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync(
              '---\nname: new\ndescription: New Skill.\n---\nBody.\n',
            );
          final source = File(p.join(sandbox.path, 'source.toml'))
            ..writeAsStringSync('''
name = "reviewer"
description = "Reviews."
model = "openai/gpt-5"
developer_instructions = "Review."
''');
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );
          ConversionRequest request(Set<String> decisions) => ConversionRequest(
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
            definition: const <String, Object?>{
              'model': 'claude-sonnet',
              'tools': <Object?>['Read'],
              'skills': <Object?>['new'],
            },
            decisions: decisions,
            references: const <String, String>{},
          );
          const required = <String>{'map:model', 'map:tools'};
          final service = AgentConversionService();

          final unresolved = await service.plan(request(required), options);
          expect(unresolved.result.data['ready'], isFalse);
          final fields = unresolved.result.data['fields']! as List<Object?>;
          final skills = fields
              .map((field) => field! as Map<String, Object?>)
              .singleWhere((field) => field['sourcePath'] == 'skills');
          expect(skills['outcome'], 'unresolved');
          expect(skills['decision'], 'map:skills');

          final resolved = await service.plan(
            request(<String>{...required, 'map:skills'}),
            options,
          );
          expect(resolved.result.data['ready'], isTrue);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'a target-only effort selection requires an explicit mapping',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'agent-conversion-',
        );
        try {
          final project = Directory(p.join(sandbox.path, 'project'))
            ..createSync();
          final home = Directory(p.join(sandbox.path, 'home'))..createSync();
          final source = File(p.join(sandbox.path, 'source.toml'))
            ..writeAsStringSync('''
name = "reviewer"
description = "Reviews."
model = "openai/gpt-5"
developer_instructions = "Review."
''');
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );
          ConversionRequest request(Set<String> decisions) => ConversionRequest(
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
            definition: const <String, Object?>{
              'model': 'claude-sonnet',
              'effort': 'high',
              'tools': <Object?>['Read'],
            },
            decisions: decisions,
            references: const <String, String>{},
          );
          const required = <String>{'map:model', 'map:tools', 'inherit:tools'};
          final service = AgentConversionService();

          final unresolved = await service.plan(request(required), options);
          expect(unresolved.result.data['ready'], isFalse);
          final fields = unresolved.result.data['fields']! as List<Object?>;
          final effort = fields
              .map((field) => field! as Map<String, Object?>)
              .singleWhere((field) => field['targetPath'] == 'effort');
          expect(effort['outcome'], 'unresolved');
          expect(effort['decision'], 'map:effort');

          final resolved = await service.plan(
            request(<String>{...required, 'map:effort'}),
            options,
          );
          expect(resolved.result.data['ready'], isTrue);
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test('plan identity is independent of request map ordering', () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'agent-conversion-',
      );
      try {
        final project = Directory(p.join(sandbox.path, 'project'))
          ..createSync();
        final home = Directory(p.join(sandbox.path, 'home'))..createSync();
        for (final skill in const ['one', 'two']) {
          File(p.join(project.path, '.claude', 'skills', skill, 'SKILL.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync(
              '---\nname: $skill\ndescription: Skill.\n---\nBody.\n',
            );
        }
        final source = File(p.join(sandbox.path, 'source.toml'))
          ..writeAsStringSync('''
name = "reviewer"
description = "Reviews."
developer_instructions = "Review."

[skills]
config = [{ path = "one", enabled = false }, { path = "two", enabled = false }]
''');
        final options = LifecycleOptions(
          processWorkingDirectory: project.path,
          cwd: project.path,
          projectRoot: project.path,
          home: home.path,
        );
        ConversionRequest request({
          required Map<String, Object?> target,
          required Map<String, Object?> definition,
          required Map<String, String> references,
        }) => ConversionRequest(
          source: <String, Object?>{
            'kind': 'native-file',
            'path': source.path,
            'harness': 'codex',
          },
          target: target,
          context: './',
          definition: definition,
          decisions: const <String>{
            'map:model',
            'map:effort',
            'map:skills',
            'map:tools',
          },
          references: references,
        );
        final output = p.join(project.path, '.claude', 'agents', 'reviewer.md');
        final service = AgentConversionService();

        final first = await service.plan(
          request(
            target: <String, Object?>{'harness': 'claude', 'output': output},
            definition: <String, Object?>{
              'model': 'claude-sonnet',
              'effort': 'high',
              'tools': <Object?>['Read'],
              'skills': <Object?>['one', 'two'],
            },
            references: const <String, String>{
              'skill:one': 'one',
              'skill:two': 'two',
            },
          ),
          options,
        );
        final second = await service.plan(
          request(
            target: <String, Object?>{'output': output, 'harness': 'claude'},
            definition: <String, Object?>{
              'skills': <Object?>['one', 'two'],
              'tools': <Object?>['Read'],
              'effort': 'high',
              'model': 'claude-sonnet',
            },
            references: const <String, String>{
              'skill:two': 'two',
              'skill:one': 'one',
            },
          ),
          options,
        );

        expect(
          first.result.data['ready'],
          isTrue,
          reason: first.result.diagnostics.toString(),
        );
        expect(
          second.result.data['ready'],
          isTrue,
          reason: second.result.diagnostics.toString(),
        );
        expect(second.authoring.content, first.authoring.content);
        expect(second.result.data['fields'], first.result.data['fields']);
        expect(second.result.data['planId'], first.result.data['planId']);
      } finally {
        await sandbox.delete(recursive: true);
      }
    });

    test(
      'changed name and description require explicit mapping decisions',
      () async {
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
          final options = LifecycleOptions(
            processWorkingDirectory: project.path,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          );
          ConversionRequest request(Set<String> decisions) => ConversionRequest(
            source: <String, Object?>{
              'kind': 'native-file',
              'path': source.path,
              'harness': 'claude',
            },
            target: <String, Object?>{
              'harness': 'codex',
              'output': p.join(
                project.path,
                '.codex',
                'agents',
                'auditor.toml',
              ),
            },
            context: './',
            definition: const <String, Object?>{
              'name': 'auditor',
              'description': 'Audits changes.',
              'model': 'openai/gpt-5',
              'model_reasoning_effort': 'high',
            },
            decisions: decisions,
            references: const <String, String>{},
          );
          const base = <String>{'map:model', 'map:effort', 'inherit:tools'};
          final service = AgentConversionService();

          final unresolved = await service.plan(request(base), options);
          expect(unresolved.result.data['ready'], isFalse);
          final fields = unresolved.result.data['fields']! as List<Object?>;
          for (final path in const ['name', 'description']) {
            final field = fields
                .map((entry) => entry! as Map<String, Object?>)
                .singleWhere((entry) => entry['sourcePath'] == path);
            expect(field['outcome'], 'unresolved');
            expect(field['decision'], 'map:$path');
          }

          final resolved = await service.plan(
            request(<String>{...base, 'map:name', 'map:description'}),
            options,
          );
          expect(
            resolved.result.data['ready'],
            isTrue,
            reason: resolved.result.diagnostics.toString(),
          );
          final resolvedFields =
              resolved.result.data['fields']! as List<Object?>;
          for (final path in const ['name', 'description']) {
            final field = resolvedFields
                .map((entry) => entry! as Map<String, Object?>)
                .singleWhere((entry) => entry['sourcePath'] == path);
            expect(field['outcome'], 'altered');
            expect(field['decision'], 'map:$path');
          }
        } finally {
          await sandbox.delete(recursive: true);
        }
      },
    );

    test(
      'request parsing rejects unsupported and conflicting native sources',
      () {
        final sandbox = Directory.systemTemp.createTempSync(
          'agent-conversion-',
        );
        try {
          final request = File(p.join(sandbox.path, 'request.json'));
          Map<String, Object?> envelope(Map<String, Object?> source) =>
              <String, Object?>{
                'schemaVersion': 1,
                'operation': 'convert',
                'source': source,
                'target': <String, Object?>{
                  'harness': 'codex',
                  'output': '.codex/agents/reviewer.toml',
                },
                'context': <String, Object?>{'workingDirectory': './'},
              };
          request.writeAsStringSync(
            jsonEncode(
              envelope(<String, Object?>{
                'kind': 'native-file',
                'path': 'reviewer.md',
                'harness': 'unknown',
              }),
            ),
          );
          expect(
            () => parseConversionRequest(request.path, sandbox.path),
            throwsA(isA<MambaException>()),
          );

          request.writeAsStringSync(
            jsonEncode(
              envelope(<String, Object?>{
                'kind': 'native-file',
                'path': 'reviewer.md',
                'harness': 'claude',
                'roleKey': 'reviewer',
              }),
            ),
          );
          expect(
            () => parseConversionRequest(request.path, sandbox.path),
            throwsA(isA<MambaException>()),
          );
        } finally {
          sandbox.deleteSync(recursive: true);
        }
      },
    );
  });
}
