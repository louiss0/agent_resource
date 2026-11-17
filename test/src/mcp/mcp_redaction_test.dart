import 'dart:convert';

import 'package:agent_resource/src/mcp/mcp_envelope.dart';
import 'package:agent_resource/src/mcp/mcp_redaction.dart';
import 'package:test/test.dart';

/// Builds a literal `${NAME}` reference without triggering Dart interpolation.
String ref(String name) => [String.fromCharCode(36), '{', name, '}'].join();

void main() {
  group('McpRedaction', () {
    test('redacts literal credential values but discloses references', () {
      final data = <String, Object?>{
        'env': <String, Object?>{
          'API_KEY': 'sk-LIVE-SECRET',
          'REF': ref('MY_TOKEN'),
        },
        'headers': <String, Object?>{'Authorization': 'Bearer HEADER_SECRET'},
        'oauth': <String, Object?>{
          'clientSecret': 'OAUTH_SECRET',
          'callbackPort': 8080,
        },
        'auth': <String, Object?>{'provider': 'pi-provider'},
        'bearer_token_env_var': 'GH_TOKEN',
      };
      final text = jsonEncode(McpRedaction.redactMap(data));
      for (final secret in <String>[
        'sk-LIVE-SECRET',
        'HEADER_SECRET',
        'OAUTH_SECRET',
        'pi-provider',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(text, contains(ref('MY_TOKEN')));
      expect(text, contains('GH_TOKEN'));
      expect(text, contains('<redacted>'));
    });

    test('redacts nested mcpServers entries and keeps non-secret fields', () {
      final data = <String, Object?>{
        'mcpServers': <String, Object?>{
          'svc': <String, Object?>{
            'command': 'node',
            'args': <Object?>['serve'],
            'env': <String, Object?>{'KEY': 'LITERAL_SECRET'},
          },
        },
      };
      final text = jsonEncode(McpRedaction.redactMap(data));
      expect(text, isNot(contains('LITERAL_SECRET')));
      expect(text, contains('node'));
      expect(text, contains('serve'));
    });

    test('sanitizes endpoints dropping userinfo, query and fragment', () {
      expect(
        McpRedaction.sanitizeEndpoint(
          'https://user:pw@example.com/mcp?token=SECRET',
        ),
        'https://example.com/mcp',
      );
      expect(
        McpRedaction.sanitizeEndpoint('https://example.com:8443/mcp#frag'),
        'https://example.com:8443/mcp',
      );
      expect(McpRedaction.sanitizeEndpoint(ref('MCP_URL')), ref('MCP_URL'));
    });

    test('isReference recognizes only whole references', () {
      expect(McpRedaction.isReference(ref('VAR')), isTrue);
      expect(McpRedaction.isReference(ref('VAR:-default')), isTrue);
      expect(McpRedaction.isReference('!pass token'), isTrue);
      expect(McpRedaction.isReference('LOCAL_SECRET_VALUE'), isFalse);
      expect(McpRedaction.isReference('Bearer TOKEN'), isFalse);
    });

    test('redaction is idempotent', () {
      final data = <String, Object?>{
        'env': <String, Object?>{'KEY': 'SECRET_VALUE', 'REF': ref('T')},
      };
      final once = McpRedaction.redactMap(data);
      final twice = McpRedaction.redactMap(once);
      expect(jsonEncode(twice), jsonEncode(once));
    });
  });

  group('McpEnvelope', () {
    McpEnvelope envelope() => McpEnvelope(
      command: 'mcp.inspect',
      outcome: 'inspected',
      data: <String, Object?>{
        'registration': <String, Object?>{
          'name': 'svc',
          'env': <String, Object?>{
            'KEY': 'ENVELOPE_LITERAL_SECRET',
            'REF': ref('ENVELOPE_REF'),
          },
          'url': 'https://host.example/mcp?token=URL_TOKEN',
        },
      },
      diagnostics: const <Map<String, Object?>>[
        <String, Object?>{
          'code': 'STATIC_CONFIGURATION_ONLY',
          'message': 'no server was launched',
        },
      ],
    );

    test('envelope() has the versioned shape and redacts centrally', () {
      final result = envelope().envelope();
      expect(result['schemaVersion'], 1);
      expect(result['command'], 'mcp.inspect');
      expect(result['outcome'], 'inspected');
      expect(result['data'], isA<Map<String, Object?>>());
      expect(result['diagnostics'], isA<List<Map<String, Object?>>>());
      final text = jsonEncode(result);
      expect(text, isNot(contains('ENVELOPE_LITERAL_SECRET')));
      expect(text, isNot(contains('URL_TOKEN')));
      expect(text, contains(ref('ENVELOPE_REF')));
    });

    test('renderText() redacts centrally and is deterministic', () {
      final first = envelope().renderText();
      final second = McpEnvelope(
        command: 'mcp.inspect',
        outcome: 'inspected',
        data: envelope().data,
        diagnostics: envelope().diagnostics,
      ).renderText();
      expect(first, equals(second));
      expect(first, contains('mcp.inspect: inspected'));
      expect(first, isNot(contains('ENVELOPE_LITERAL_SECRET')));
      expect(first, contains(ref('ENVELOPE_REF')));
    });
  });
}
