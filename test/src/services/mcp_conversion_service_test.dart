import 'dart:convert';

import 'package:agent_resource/src/mcp/mcp_native.dart';
import 'package:agent_resource/src/mcp/mcp_ownership_ledger.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:agent_resource/src/services/mcp_conversion_service.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group(McpConversionService, () {
    late fslib.FileSystem fs;
    const String sourceName = 'svc';
    const String sourcePath = '/sandbox/project/.mcp.json';

    setUp(() {
      fs = MemoryFileSystem(style: FileSystemStyle.posix);
      for (final dir in const <String>[
        '/sandbox/project',
        '/sandbox/home',
        '/sandbox/pi',
        '/sandbox/codex',
        '/sandbox/state',
      ]) {
        fs.directory(dir).createSync(recursive: true);
      }
      fs
          .file(sourcePath)
          .writeAsStringSync(
            jsonEncode(<String, Object?>{
              'mcpServers': <String, Object?>{
                sourceName: <String, Object?>{
                  'type': 'stdio',
                  'command': 'node',
                  'args': <Object?>['serve'],
                },
              },
            }),
          );
      final entry = McpNativeReader(fs).read(
        McpNativeLocation(
          harness: McpHarness.claude,
          scope: McpScope.project,
          path: sourcePath,
          format: McpNativeFormat.json,
          section: McpNativeSection.mcpServers,
        ),
      )[sourceName]!;
      McpOwnershipLedger(fs: fs, stateRoot: '/sandbox/state').upsert(
        McpRegistrationRecord(
          identity: McpRegistrationIdentity(
            harness: McpHarness.claude,
            scope: McpScope.project,
            location: sourcePath,
            name: sourceName,
          ),
          baselineDigest: mcpCanonicalDigest(entry),
        ),
      );
    });

    McpConversionRequest request({
      List<String> omitFields = const <String>[],
    }) => McpConversionRequest(
      environment: const <String, String>{},
      harness: McpHarness.claude,
      scope: McpScope.project,
      name: sourceName,
      targetHarness: McpHarness.pi,
      omitFields: omitFields,
      cwd: '/sandbox/project',
      projectRoot: '/sandbox/project',
      home: '/sandbox/home',
      piAgentDir: '/sandbox/pi',
      codexHome: '/sandbox/codex',
      stateDir: '/sandbox/state',
    );

    test('plans a reviewed conversion without writing native files', () {
      final service = McpConversionService(fileSystem: fs);
      final before = fs.file(sourcePath).readAsStringSync();
      final plan = service.plan(request());
      expect(plan.command, 'mcp.convert.plan');
      expect(plan.outcome, 'planned');
      expect(plan.data['writes'], isFalse);
      expect(plan.data['nativeWritten'], isFalse);
      expect(plan.data['planId'], isA<String>());
      expect(service.plan(request()).data, equals(plan.data));
      expect(fs.file(sourcePath).readAsStringSync(), before);
      expect(fs.file('/sandbox/project/.pi/mcp.json').existsSync(), isFalse);
    });

    test('an omission decision changes the reviewed plan identity', () {
      final service = McpConversionService(fileSystem: fs);
      final plain = service.plan(request());
      final omitted = service.plan(request(omitFields: const <String>['args']));
      expect(omitted.data['planId'], isNot(plain.data['planId']));
      final fields = (omitted.data['fields'] as List)
          .cast<Map<String, dynamic>>();
      final args = fields.firstWhere((field) => field['sourcePath'] == 'args');
      expect(args['outcome'], 'omitted-after-review');
      expect(args['decision'], 'omit:args');
    });

    test('a non-managed source is refused before any write', () {
      final record = McpRegistrationRecord(
        identity: McpRegistrationIdentity(
          harness: McpHarness.claude,
          scope: McpScope.project,
          location: sourcePath,
          name: sourceName,
        ),
        baselineDigest: 'not-the-baseline',
      );
      McpOwnershipLedger(fs: fs, stateRoot: '/sandbox/state').upsert(record);
      expect(
        () => McpConversionService(fileSystem: fs).plan(request()),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'exit code', 4)
              .having((error) => error.message, 'message', contains('drifted')),
        ),
      );
    });
  });
}
