import 'dart:convert';

import 'package:agent_resource/src/mcp/mcp_native.dart';
import 'package:agent_resource/src/mcp/mcp_ownership_ledger.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

McpRegistrationIdentity _identity({String name = 'svc'}) =>
    McpRegistrationIdentity(
      harness: McpHarness.claude,
      scope: McpScope.project,
      location: '/sandbox/project/.mcp.json',
      name: name,
    );

void main() {
  group('McpNativeResolver', () {
    test('only Claude has a local scope; project/user cover all harnesses', () {
      expect(
        McpNativeResolver.supports(McpHarness.claude, McpScope.local),
        isTrue,
      );
      expect(
        McpNativeResolver.supports(McpHarness.codex, McpScope.local),
        isFalse,
      );
      expect(
        McpNativeResolver.supports(McpHarness.pi, McpScope.local),
        isFalse,
      );
      for (final harness in McpHarness.values) {
        expect(McpNativeResolver.supports(harness, McpScope.project), isTrue);
        expect(McpNativeResolver.supports(harness, McpScope.user), isTrue);
      }
    });
  });

  group('mcpCanonicalDigest', () {
    test('is independent of map key order', () {
      final a = <String, Object?>{
        'command': 'node',
        'env': <String, Object?>{'A': '1', 'B': '2'},
      };
      final b = <String, Object?>{
        'env': <String, Object?>{'B': '2', 'A': '1'},
        'command': 'node',
      };
      expect(mcpCanonicalDigest(a), mcpCanonicalDigest(b));
    });

    test('changes with a field value', () {
      final a = <String, Object?>{'command': 'node'};
      final b = <String, Object?>{'command': 'python'};
      expect(mcpCanonicalDigest(a), isNot(mcpCanonicalDigest(b)));
    });
  });

  group('McpRegistrationRecord', () {
    test('round-trips through toJson/fromJson', () {
      final record = McpRegistrationRecord(
        identity: _identity(),
        baselineDigest: 'abc123',
      );
      final encoded =
          jsonDecode(jsonEncode(record.toJson())) as Map<String, dynamic>;
      final restored = McpRegistrationRecord.fromJson(
        Map<String, Object?>.from(encoded),
      );
      expect(restored, record);
      expect(restored.hashCode, record.hashCode);
      expect(restored.baselineDigest, 'abc123');
    });
  });

  group('McpOwnershipLedger', () {
    late fslib.FileSystem fs;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      fs.directory('/sandbox').createSync(recursive: true);
    });

    test('read() is a pure read that yields empty state when absent', () {
      final ledger = McpOwnershipLedger(fs: fs, stateRoot: '/sandbox/state');
      expect(ledger.read(), isEmpty);
      // Discovery never writes: no state directory or ledger file appears.
      expect(fs.directory('/sandbox/state').existsSync(), isFalse);
      expect(
        fs.file('/sandbox/state/mcp-registrations.json').existsSync(),
        isFalse,
      );
    });

    test('upsert() writes a versioned ledger under the state root only', () {
      final ledger = McpOwnershipLedger(fs: fs, stateRoot: '/sandbox/state');
      final record = McpRegistrationRecord(
        identity: _identity(),
        baselineDigest: 'deadbeef',
      );
      ledger.upsert(record);
      final file = fs.file('/sandbox/state/mcp-registrations.json');
      expect(file.existsSync(), isTrue);
      final document =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(document['schemaVersion'], 1);
      expect(document['records'], isA<List<dynamic>>());
      // No marker is written into the native harness file.
      expect(fs.file('/sandbox/project/.mcp.json').existsSync(), isFalse);
      expect(ledger.read()[record.identity.storageKey], record);
    });

    test(
      'upsert() replaces a record with the same identity without a dupe',
      () {
        final ledger = McpOwnershipLedger(fs: fs, stateRoot: '/sandbox/state');
        ledger.upsert(
          McpRegistrationRecord(identity: _identity(), baselineDigest: 'first'),
        );
        ledger.upsert(
          McpRegistrationRecord(
            identity: _identity(),
            baselineDigest: 'second',
          ),
        );
        final records = ledger.read();
        expect(records.length, 1);
        expect(records[_identity().storageKey]!.baselineDigest, 'second');
      },
    );

    test('read() rejects malformed state as an operational failure', () {
      final ledger = McpOwnershipLedger(fs: fs, stateRoot: '/sandbox/state');
      fs.directory('/sandbox/state').createSync(recursive: true);
      fs
          .file('/sandbox/state/mcp-registrations.json')
          .writeAsStringSync('{"schemaVersion":1,"schemaVersion":1}');
      expect(() => ledger.read(), throwsA(isA<MambaException>()));
    });
  });

  group('McpNativeReader', () {
    late fslib.FileSystem fs;

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      fs.directory('/sandbox').createSync(recursive: true);
    });

    McpNativeLocation location() => const McpNativeLocation(
      harness: McpHarness.claude,
      scope: McpScope.project,
      path: '/sandbox/.mcp.json',
      format: McpNativeFormat.json,
      section: McpNativeSection.mcpServers,
    );

    test('reads named server entries from strict JSON', () {
      fs
          .file('/sandbox/.mcp.json')
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'mcpServers': <String, Object?>{
                'svc': <String, Object?>{'command': 'node'},
              },
            }),
          );
      final entries = McpNativeReader(fs).read(location());
      expect(entries.keys, <String>['svc']);
      expect(entries['svc']!['command'], 'node');
    });

    test('rejects a linked native file', () {
      fs.directory('/sandbox/target').createSync();
      fs.link('/sandbox/.mcp.json').createSync('/sandbox/target');
      expect(
        () => McpNativeReader(fs).read(location()),
        throwsA(isA<MambaException>()),
      );
    });
  });
}
