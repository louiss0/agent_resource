import 'dart:io';

import 'package:agent_resource/src/agent_inspection.dart';
import 'package:agent_resource/src/services/agent_graph_service.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group(AgentGraphService, () {
    test(
      'distinguishes a missing required preload from runtime observations',
      () {
        final sandbox = Directory.systemTemp.createTempSync('agent-graph-');
        try {
          final definition = File(p.join(sandbox.path, 'reviewer.md'))
            ..writeAsStringSync('''---
name: reviewer
description: Reviews.
model: claude-sonnet
skills: [missing-skill]
mcpServers: [docs]
---
Review.
''');
          final report = AgentGraphService().analyze(
            AgentInspectionInput(
              nativeFile: definition.path,
              harness: AgentHarness.claude,
              cwd: sandbox.path,
            ),
          );

          expect(report.complete, isTrue);
          expect(report.ready, isFalse);
          expect(report.blockers, hasLength(1));
          expect(report.blockers.single['code'], 'REQUIRED_REFERENCE_MISSING');
          expect(report.edges, hasLength(3));
          expect(
            report.edges.map((edge) => edge['kind']),
            containsAll(<String>['model', 'skill-preload', 'mcp-association']),
          );
          final skillNode = report.nodes.singleWhere(
            (node) => node['id'] == 'skill:missing-skill',
          );
          expect(skillNode['resolutionBase'], sandbox.path);
          expect(skillNode['coverage'], 'missing');
          expect(report.exposureNotes, isNotEmpty);
          expect(report.toJson().toString(), isNot(contains('Review.')));
        } finally {
          sandbox.deleteSync(recursive: true);
        }
      },
    );

    test('an absent disabled Skill is an exclusion, not a missing preload', () {
      final sandbox = Directory.systemTemp.createTempSync('agent-graph-');
      try {
        final definition = File(p.join(sandbox.path, 'reviewer.toml'))
          ..writeAsStringSync('''
name = "reviewer"
description = "Reviews."
developer_instructions = "Review."

[skills]
config = [{ path = "missing-skill", enabled = false }]
''');
        final report = AgentGraphService().analyze(
          AgentInspectionInput(
            nativeFile: definition.path,
            harness: AgentHarness.codex,
            cwd: sandbox.path,
          ),
        );

        expect(report.complete, isTrue);
        expect(report.ready, isTrue);
        expect(report.blockers, isEmpty);
        expect(report.edges.single['kind'], 'skill-exclusion');
        expect(report.edges.single['coverage'], 'excluded-absent');
        expect(report.edges.single['blocker'], isFalse);
      } finally {
        sandbox.deleteSync(recursive: true);
      }
    });

    test(
      'a required source that becomes unreadable fails with status three',
      () {
        final sandbox = Directory.systemTemp.createTempSync('agent-graph-');
        try {
          final definition = File(p.join(sandbox.path, 'reviewer.md'))
            ..writeAsStringSync('''---
name: reviewer
description: Reviews.
---
Review.
''');
          final inspection = inspectNativeAgent(
            AgentInspectionInput(
              nativeFile: definition.path,
              harness: AgentHarness.claude,
            ),
            operation: AgentOperation.inspect,
          );
          definition.deleteSync();

          expect(
            () => AgentGraphService().analyzeInspection(inspection),
            throwsA(
              isA<MambaException>().having(
                (error) => error.exitCode,
                'exit code',
                3,
              ),
            ),
          );
        } finally {
          sandbox.deleteSync(recursive: true);
        }
      },
    );
  });
}
