import 'dart:convert';

import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:test/test.dart';

void main() {
  group('MCP enums', () {
    test('expose stable wire names and round-trip through fromWire', () {
      for (final value in McpHarness.values) {
        expect(value.toJson(), value.wireName);
        expect(McpHarness.fromWire(value.wireName), value);
      }
      for (final value in McpScope.values) {
        expect(value.toJson(), value.wireName);
        expect(McpScope.fromWire(value.wireName), value);
      }
      for (final value in McpTransport.values) {
        expect(McpTransport.fromWire(value.wireName), value);
      }
      for (final value in McpOwnership.values) {
        expect(McpOwnership.fromWire(value.wireName), value);
      }
      for (final value in McpOutputFormat.values) {
        expect(McpOutputFormat.fromWire(value.wireName), value);
      }
      expect(McpOwnership.ownershipUnverified.wireName, 'ownership-unverified');
    });

    test('reject unknown wire names', () {
      expect(() => McpHarness.fromWire('nope'), throwsFormatException);
      expect(() => McpScope.fromWire('nope'), throwsFormatException);
      expect(() => McpTransport.fromWire('nope'), throwsFormatException);
      expect(() => McpOwnership.fromWire('nope'), throwsFormatException);
      expect(() => McpOutputFormat.fromWire('nope'), throwsFormatException);
    });
  });

  group('McpRegistrationIdentity', () {
    McpRegistrationIdentity identity({String name = 'github'}) =>
        McpRegistrationIdentity(
          harness: McpHarness.claude,
          scope: McpScope.project,
          location: '/work/project/.mcp.json',
          name: name,
        );

    test('serializes to the four-part JSON shape', () {
      expect(identity().toJson(), <String, Object?>{
        'harness': 'claude',
        'scope': 'project',
        'location': '/work/project/.mcp.json',
        'name': 'github',
      });
    });

    test('round-trips through toJson/fromJson', () {
      final encoded =
          jsonDecode(jsonEncode(identity().toJson())) as Map<String, dynamic>;
      final restored = McpRegistrationIdentity.fromJson(
        Map<String, Object?>.from(encoded),
      );
      expect(restored, identity());
      expect(restored.hashCode, identity().hashCode);
    });

    test('storageKey is stable and distinct per identity part', () {
      final base = identity();
      expect(base.storageKey, isA<String>());
      expect(base.storageKey, equals(base.storageKey));
      final otherName = identity(name: 'other');
      expect(otherName.storageKey, isNot(base.storageKey));
      final otherScope = McpRegistrationIdentity(
        harness: McpHarness.claude,
        scope: McpScope.user,
        location: '/work/project/.mcp.json',
        name: 'github',
      );
      expect(otherScope.storageKey, isNot(base.storageKey));
      final otherHarness = McpRegistrationIdentity(
        harness: McpHarness.codex,
        scope: McpScope.project,
        location: '/work/project/.mcp.json',
        name: 'github',
      );
      expect(otherHarness.storageKey, isNot(base.storageKey));
      final otherLocation = McpRegistrationIdentity(
        harness: McpHarness.claude,
        scope: McpScope.project,
        location: '/work/other/.mcp.json',
        name: 'github',
      );
      expect(otherLocation.storageKey, isNot(base.storageKey));
    });

    test('equality and hashCode follow the four parts', () {
      expect(identity(), identity());
      expect(identity().hashCode, identity().hashCode);
      expect(identity(name: 'other'), isNot(identity()));
    });

    test('fromJson rejects missing keys and unknown wire names', () {
      expect(
        () => McpRegistrationIdentity.fromJson(<String, Object?>{
          'harness': 'claude',
        }),
        throwsFormatException,
      );
      expect(
        () => McpRegistrationIdentity.fromJson(<String, Object?>{
          'harness': 'bogus',
          'scope': 'project',
          'location': '/work/project/.mcp.json',
          'name': 'github',
        }),
        throwsFormatException,
      );
    });
  });
}
