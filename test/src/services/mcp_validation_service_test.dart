import 'dart:convert';

import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:agent_resource/src/mcp/mcp_validation.dart';
import 'package:agent_resource/src/services/mcp_validation_service.dart';
import 'package:test/test.dart';

void main() {
  final service = McpValidationService();

  void expectStaticOnly(String output) {
    final lower = output.toLowerCase();
    for (final forbidden in <String>[
      'activation',
      'connectivity',
      'enforcement',
      'acceptance',
    ]) {
      expect(lower, isNot(contains(forbidden)), reason: forbidden);
    }
  }

  group('validate', () {
    test('accepts minimal documented transports for each harness', () {
      final cases =
          <
            ({McpHarness harness, McpScope? scope, Map<String, Object?> fields})
          >[
            (
              harness: McpHarness.claude,
              scope: McpScope.project,
              fields: <String, Object?>{'type': 'stdio', 'command': 'node'},
            ),
            (
              harness: McpHarness.claude,
              scope: McpScope.user,
              fields: <String, Object?>{
                'type': 'http',
                'url': 'https://example.test/mcp',
              },
            ),
            (
              harness: McpHarness.codex,
              scope: McpScope.user,
              fields: <String, Object?>{'command': 'gh-mcp'},
            ),
            (
              harness: McpHarness.codex,
              scope: McpScope.project,
              fields: <String, Object?>{'url': 'https://example.test/mcp'},
            ),
            (
              harness: McpHarness.pi,
              scope: McpScope.user,
              fields: <String, Object?>{'command': 'pi-mcp'},
            ),
            (
              harness: McpHarness.pi,
              scope: McpScope.project,
              fields: <String, Object?>{
                'type': 'http',
                'url': 'https://example.test/mcp',
              },
            ),
          ];

      for (final item in cases) {
        final report = service.validate(
          harness: item.harness,
          fields: item.fields,
          scope: item.scope,
        );
        expect(report.valid, isTrue, reason: item.harness.wireName);
        expect(report.diagnostics, isEmpty);
        expect(report.profile, contains(item.harness.wireName));
        expect(report.baseline['sources'], isA<List<Object?>>());
        expect(
          (report.baseline['recognizedFields'] as Map)['stdio'],
          isA<List<Object?>>(),
        );
        expect(
          (report.baseline['supportedTypes'] as Map)['http'],
          isA<List<Object?>>(),
        );
        expect(report.claim, mcpValidationClaim);
      }
    });

    test('produces a value-free static report', () {
      final report = service.validate(
        harness: McpHarness.pi,
        fields: <String, Object?>{'type': 'stdio', 'command': 'pi-mcp'},
        scope: McpScope.user,
      );

      final encoded = jsonEncode(report.toJson());
      expect(encoded, contains('static schema/reference correctness only'));
      expect(encoded, contains('not runtime-verified'));
      expectStaticOnly(encoded);
      expectStaticOnly(report.renderText());
      expect(encoded, isNot(contains('pi-mcp')));
    });
  });
}
