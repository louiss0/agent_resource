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
        'diagnostics',
      ]);
      expect(json['valid'], isFalse);
      expect(json['claim'], mcpValidationClaim);
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
  });
}
