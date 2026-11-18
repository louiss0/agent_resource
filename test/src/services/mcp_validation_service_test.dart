import 'dart:convert';

import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:agent_resource/src/mcp/mcp_validation.dart';
import 'package:agent_resource/src/services/mcp_validation_service.dart';
import 'package:test/test.dart';

void main() {
  final service = McpValidationService();

  List<String> codes(McpValidationReport report) =>
      report.diagnostics.map((diagnostic) => diagnostic.code).toList();

  List<String> fieldsForCode(McpValidationReport report, String code) => report
      .diagnostics
      .where((diagnostic) => diagnostic.code == code)
      .map((diagnostic) => diagnostic.field)
      .toList();

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
          (report.baseline['recognizedFields']
              as Map<String, Object?>)['stdio'],
          isA<List<Object?>>(),
        );
        expect(
          (report.baseline['supportedTypes'] as Map<String, Object?>)['http'],
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

    test('requires exactly one command or url', () {
      for (final harness in McpHarness.values) {
        final missing = service.validate(
          harness: harness,
          fields: <String, Object?>{'type': 'stdio'},
          scope: McpScope.user,
        );
        expect(missing.valid, isFalse, reason: harness.wireName);
        expect(codes(missing), contains('MCP_TRANSPORT_MISSING'));

        final both = service.validate(
          harness: harness,
          fields: <String, Object?>{
            'command': 'node',
            'url': 'https://example.test/mcp',
          },
          scope: McpScope.project,
        );
        expect(both.valid, isFalse, reason: harness.wireName);
        expect(codes(both), contains('MCP_TRANSPORT_CONFLICT'));
      }
    });

    test('checks supported type values and transport agreement', () {
      final unsupported = service.validate(
        harness: McpHarness.claude,
        fields: <String, Object?>{'type': 'sdk', 'command': 'node'},
        scope: McpScope.project,
      );
      expect(codes(unsupported), contains('MCP_TYPE_UNSUPPORTED'));

      final stdioMismatch = service.validate(
        harness: McpHarness.pi,
        fields: <String, Object?>{'type': 'http', 'command': 'pi-mcp'},
        scope: McpScope.user,
      );
      expect(codes(stdioMismatch), contains('MCP_TYPE_TRANSPORT_MISMATCH'));

      final httpMismatch = service.validate(
        harness: McpHarness.pi,
        fields: <String, Object?>{
          'type': 'stdio',
          'url': 'https://example.test/mcp',
        },
        scope: McpScope.user,
      );
      expect(codes(httpMismatch), contains('MCP_TYPE_TRANSPORT_MISMATCH'));

      final piWebSocket = service.validate(
        harness: McpHarness.pi,
        fields: <String, Object?>{
          'type': 'ws',
          'url': 'https://example.test/mcp',
        },
        scope: McpScope.user,
      );
      expect(codes(piWebSocket), contains('MCP_TYPE_UNSUPPORTED'));
    });

    test('requires Claude HTTP type but accepts documented type values', () {
      final missingType = service.validate(
        harness: McpHarness.claude,
        fields: <String, Object?>{'url': 'https://example.test/mcp'},
        scope: McpScope.user,
      );
      expect(codes(missingType), contains('MCP_TYPE_REQUIRED'));

      final claudeWebSocket = service.validate(
        harness: McpHarness.claude,
        fields: <String, Object?>{
          'type': 'ws',
          'url': 'https://example.test/mcp',
        },
        scope: McpScope.user,
      );
      expect(claudeWebSocket.valid, isTrue);

      for (final harness in <McpHarness>[McpHarness.codex, McpHarness.pi]) {
        final streamable = service.validate(
          harness: harness,
          fields: <String, Object?>{
            'type': 'streamable-http',
            'url': 'https://example.test/mcp',
          },
          scope: McpScope.user,
        );
        expect(streamable.valid, isTrue, reason: harness.wireName);
      }
    });

    test('rejects fields that do not belong to the selected transport', () {
      final http = service.validate(
        harness: McpHarness.pi,
        fields: <String, Object?>{
          'type': 'http',
          'url': 'https://example.test/mcp',
          'cwd': '/workspace',
          'args': <Object?>['--serve'],
          'env': <String, Object?>{'TOKEN': 'TOP_SECRET_VALUE'},
        },
        scope: McpScope.user,
      );
      expect(http.valid, isFalse);
      expect(
        fieldsForCode(http, 'MCP_FIELD_TRANSPORT_INAPPLICABLE'),
        containsAll(<String>['"args"', '"cwd"', '"env"']),
      );

      final stdio = service.validate(
        harness: McpHarness.codex,
        fields: <String, Object?>{
          'command': 'gh-mcp',
          'url': 'https://example.test/mcp',
          'oauth': <String, Object?>{'client_id': 'CLIENT_SECRET_VALUE'},
          'bearer_token_env_var': 'TOKEN_NAME',
        },
        scope: McpScope.user,
      );
      expect(codes(stdio), contains('MCP_TRANSPORT_CONFLICT'));
      expect(
        fieldsForCode(stdio, 'MCP_FIELD_TRANSPORT_INAPPLICABLE'),
        containsAll(<String>['"oauth"', '"url"', '"bearer_token_env_var"']),
      );

      final piStdio = service.validate(
        harness: McpHarness.pi,
        fields: <String, Object?>{
          'command': 'pi-mcp',
          'headers': <String, Object?>{'X-Key': 'ANOTHER_SECRET_VALUE'},
        },
        scope: McpScope.user,
      );
      expect(
        fieldsForCode(piStdio, 'MCP_FIELD_TRANSPORT_INAPPLICABLE'),
        contains('"headers"'),
      );
    });

    test('rejects unknown fields without disclosing received values', () {
      final report = service.validate(
        harness: McpHarness.claude,
        fields: <String, Object?>{
          'type': 'stdio',
          'command': 'node',
          'mystery': 'UNKNOWN_SECRET_VALUE',
        },
        scope: McpScope.project,
      );
      expect(codes(report), contains('UNKNOWN_FIELD'));
      expect(fieldsForCode(report, 'UNKNOWN_FIELD'), contains('"mystery"'));
      expect(jsonEncode(report.toJson()), isNot(contains('UNKNOWN_SECRET')));
    });

    test(
      'documents closed field matrices and type support in the baseline',
      () {
        final claude = service.validate(
          harness: McpHarness.claude,
          fields: <String, Object?>{'command': 'node', 'type': 'stdio'},
          scope: McpScope.project,
        );
        final claudeFields =
            claude.baseline['recognizedFields']! as Map<String, Object?>;
        final claudeTypes =
            claude.baseline['supportedTypes']! as Map<String, Object?>;
        expect(claudeFields['stdio']! as List<Object?>, contains('args'));
        expect(
          claudeFields['http']! as List<Object?>,
          contains('headersHelper'),
        );
        expect(claudeFields['http']! as List<Object?>, contains('oauth'));
        expect(claudeTypes['http']! as List<Object?>, contains('ws'));

        final codex = service.validate(
          harness: McpHarness.codex,
          fields: <String, Object?>{'command': 'gh-mcp'},
          scope: McpScope.user,
        );
        final codexFields =
            codex.baseline['recognizedFields']! as Map<String, Object?>;
        expect(codexFields['stdio']! as List<Object?>, contains('env_vars'));
        expect(
          codexFields['common']! as List<Object?>,
          contains('default_tools_approval_mode'),
        );

        final pi = service.validate(
          harness: McpHarness.pi,
          fields: <String, Object?>{'command': 'pi-mcp'},
          scope: McpScope.user,
        );
        final piFields =
            pi.baseline['recognizedFields']! as Map<String, Object?>;
        expect(piFields['http']! as List<Object?>, contains('auth'));
        expect(piFields['common']! as List<Object?>, contains('toolExposure'));
      },
    );

    test('shape-checks Codex runtime controls when present', () {
      final valid = service.validate(
        harness: McpHarness.codex,
        fields: <String, Object?>{
          'command': 'gh-mcp',
          'enabled': true,
          'required': false,
          'startup_timeout_sec': 10,
          'tool_timeout_sec': 60,
          'enabled_tools': <Object?>['tool-a'],
          'disabled_tools': <Object?>['tool-b'],
          'default_tools_approval_mode': 'prompt',
          'tools': <String, Object?>{
            'tool-a': <String, Object?>{
              'approval_mode': 'auto',
              'output_token_limit': 100,
            },
          },
        },
        scope: McpScope.user,
      );
      expect(valid.valid, isTrue, reason: codes(valid).join(', '));

      final invalid = service.validate(
        harness: McpHarness.codex,
        fields: <String, Object?>{
          'command': 'gh-mcp',
          'enabled': 'yes',
          'startup_timeout_sec': '10',
          'enabled_tools': 'tool-a',
          'default_tools_approval_mode': 'unknown-mode',
          'tools': <String, Object?>{
            'tool-a': <String, Object?>{
              'approval_mode': 1,
              'mystery': 'CODEX_BAD_SECRET_VALUE',
            },
          },
        },
        scope: McpScope.user,
      );
      final invalidCodes = codes(invalid);
      expect(
        invalidCodes,
        containsAll(<String>['FIELD_TYPE', 'FIELD_VALUE', 'UNKNOWN_FIELD']),
      );
      expect(
        fieldsForCode(invalid, 'FIELD_TYPE'),
        containsAll(<String>[
          'enabled',
          'enabled_tools',
          'startup_timeout_sec',
          'tools.tool-a.approval_mode',
        ]),
      );
      expect(
        fieldsForCode(invalid, 'UNKNOWN_FIELD'),
        contains('tools.tool-a.mystery'),
      );
      expect(
        jsonEncode(invalid.toJson()),
        isNot(contains('CODEX_BAD_SECRET_VALUE')),
      );
    });

    test('shape-checks Pi exposure and request controls when present', () {
      final valid = service.validate(
        harness: McpHarness.pi,
        fields: <String, Object?>{
          'command': 'pi-mcp',
          'enabled': false,
          'timeout': 30,
          'description': 'Static description.',
          'exposure': 'hidden',
          'toolExposure': 'direct',
        },
        scope: McpScope.user,
      );
      expect(valid.valid, isTrue, reason: codes(valid).join(', '));

      final invalid = service.validate(
        harness: McpHarness.pi,
        fields: <String, Object?>{
          'command': 'pi-mcp',
          'timeout': '30',
          'exposure': 'unknown-mode',
        },
        scope: McpScope.user,
      );
      expect(
        codes(invalid),
        containsAll(<String>['FIELD_TYPE', 'FIELD_VALUE']),
      );
      expect(fieldsForCode(invalid, 'FIELD_TYPE'), contains('timeout'));
      expect(fieldsForCode(invalid, 'FIELD_VALUE'), contains('exposure'));
    });

    test('shape-checks Claude dynamic-header and OAuth object shapes', () {
      final valid = service.validate(
        harness: McpHarness.claude,
        fields: <String, Object?>{
          'type': 'http',
          'url': 'https://example.test/mcp',
          'headersHelper': 'headers-helper',
          'oauth': <String, Object?>{
            'clientId': 'client',
            'callbackPort': 8080,
            'authServerMetadataUrl': 'https://example.test/metadata',
            'scopes': <Object?>['tools'],
          },
        },
        scope: McpScope.user,
      );
      expect(valid.valid, isTrue, reason: codes(valid).join(', '));

      final invalid = service.validate(
        harness: McpHarness.claude,
        fields: <String, Object?>{
          'type': 'http',
          'url': 'https://example.test/mcp',
          'headersHelper': 123,
          'oauth': <String, Object?>{
            'callbackPort': '8080',
            'unknown': 'CLIENT_SECRET_VALUE',
          },
        },
        scope: McpScope.user,
      );
      expect(
        codes(invalid),
        containsAll(<String>['FIELD_TYPE', 'UNKNOWN_FIELD']),
      );
      expect(fieldsForCode(invalid, 'FIELD_TYPE'), contains('headersHelper'));
      expect(
        fieldsForCode(invalid, 'UNKNOWN_FIELD'),
        contains('oauth.unknown'),
      );
      expect(
        jsonEncode(invalid.toJson()),
        isNot(contains('CLIENT_SECRET_VALUE')),
      );
    });

    test('refuses Pi project provider credentials without disclosure', () {
      final fields = <String, Object?>{
        'type': 'http',
        'url': 'https://example.test/mcp',
        'auth': <String, Object?>{'provider': 'PI_PROVIDER_SECRET'},
      };
      final user = service.validate(
        harness: McpHarness.pi,
        fields: fields,
        scope: McpScope.user,
      );
      expect(user.valid, isTrue, reason: codes(user).join(', '));
      expect(jsonEncode(user.toJson()), isNot(contains('PI_PROVIDER_SECRET')));

      final project = service.validate(
        harness: McpHarness.pi,
        fields: fields,
        scope: McpScope.project,
      );
      expect(codes(project), contains('MCP_PI_PROJECT_AUTH_FORBIDDEN'));
      final encoded = jsonEncode(project.toJson());
      expect(encoded, isNot(contains('PI_PROVIDER_SECRET')));
      expectStaticOnly(encoded);
    });

    test('emits value-free diagnostics and a static-only claim', () {
      final report = service.validate(
        harness: McpHarness.claude,
        fields: <String, Object?>{
          'type': 'stdio',
          'command': 'COMMAND_SECRET_VALUE',
          'args': <Object?>['ARG_SECRET_VALUE'],
          'env': <String, Object?>{'TOKEN': 'ENV_SECRET_VALUE'},
          'headers': <String, Object?>{'X-Key': 'HEADER_SECRET_VALUE'},
          'oauth': <String, Object?>{'clientId': 'OAUTH_SECRET_VALUE'},
          'unknown\u202efield': 'UNKNOWN_SECRET_VALUE',
        },
        scope: McpScope.project,
      );
      final encoded = jsonEncode(report.toJson());
      final text = report.renderText();
      for (final secret in <String>[
        'COMMAND_SECRET_VALUE',
        'ARG_SECRET_VALUE',
        'ENV_SECRET_VALUE',
        'HEADER_SECRET_VALUE',
        'OAUTH_SECRET_VALUE',
        'UNKNOWN_SECRET_VALUE',
      ]) {
        expect(encoded, isNot(contains(secret)), reason: secret);
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(
        report.diagnostics.any((d) => d.field.contains(r'\u202e')),
        isTrue,
      );
      expect(encoded, isNot(contains('\u202e')));
      expect(text, isNot(contains('\u202e')));
      expectStaticOnly(encoded);
      expectStaticOnly(text);

      for (final harness in McpHarness.values) {
        final claimReport = service.validate(
          harness: harness,
          fields: <String, Object?>{'type': 'stdio', 'command': 'static-check'},
          scope: McpScope.user,
        );
        expect(claimReport.claim, mcpValidationClaim);
        final claimJson = jsonEncode(claimReport.toJson());
        expect(claimJson, contains('not runtime-verified'));
        expectStaticOnly(claimJson);
        expectStaticOnly(claimReport.renderText());
      }
    });
  });
}
