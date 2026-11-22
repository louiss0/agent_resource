import 'package:agent_resource/src/mcp/mcp_validation.dart';
import 'package:agent_resource/src/validation/validation_diagnostics.dart';
import 'package:test/test.dart';

void main() {
  group('McpValidationReport', () {
    test('serializes a deterministic, static-only report', () {
      final report = McpValidationReport(
        profile: 'mcp-claude-native-static-v1',
        baseline: const <String, Object?>{
          'sources': <String>['claude-code-mcp/2026-11-16'],
          'recognizedFields': <String, Object?>{
            'stdio': <String>['command'],
            'http': <String>['url'],
          },
        },
        diagnostics: const <McpValidationDiagnostic>[
          McpValidationDiagnostic(
            code: 'UNKNOWN_FIELD',
            field: '"unexpected\u202efield"',
          ),
        ],
      );

      final json = report.toJson();
      expect(json.keys, <String>[
        'valid',
        'profile',
        'baseline',
        'claim',
        'verification',
        'diagnostics',
      ]);
      expect(json['valid'], isFalse);
      expect(json['claim'], mcpValidationClaim);
      expect(json['verification'], 'static');
      expect(json['diagnostics'], isA<List<Object?>>());
      final diagnostic = (json['diagnostics'] as List).single as Map;
      expect(diagnostic.keys, <String>[
        'code',
        'category',
        'severity',
        'field',
        'message',
      ]);
      expect(diagnostic['code'], 'UNKNOWN_FIELD');
      expect(diagnostic['category'], 'product');
      expect(diagnostic['severity'], 'error');
      expect(diagnostic['field'], contains(r'\u202e'));
      expect(diagnostic['message'], isNot(contains('\u202e')));
      expect(
        report.renderText(),
        contains(
          ValidationDiagnostics.format(
            r'"unexpected\u202efield"',
            'UNKNOWN_FIELD',
            report.diagnostics.single.message,
          ),
        ),
      );
    });

    test('publishes a fixed, value-free diagnostic code table', () {
      expect(
        mcpValidationCodeTable.keys,
        containsAll(<String>[
          'MCP_TRANSPORT_MISSING',
          'MCP_TRANSPORT_CONFLICT',
          'MCP_TYPE_UNSUPPORTED',
          'MCP_TYPE_TRANSPORT_MISMATCH',
          'MCP_FIELD_TRANSPORT_INAPPLICABLE',
          'MCP_PI_PROJECT_AUTH_FORBIDDEN',
          'UNKNOWN_FIELD',
          'FIELD_TYPE',
          'FIELD_SHAPE',
          'FIELD_VALUE',
        ]),
      );
      for (final entry in mcpValidationCodeTable.entries) {
        expect(
          entry.value.category,
          anyOf('specification', 'product', 'security'),
          reason: entry.key,
        );
        expect(entry.value.message, isNotEmpty, reason: entry.key);
        final lower = entry.value.message.toLowerCase();
        for (final forbidden in <String>[
          'activation',
          'connectivity',
          'enforcement',
          'acceptance',
        ]) {
          expect(lower, isNot(contains(forbidden)), reason: entry.key);
        }
      }
    });
  });
}
