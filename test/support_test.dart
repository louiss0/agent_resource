import 'dart:convert';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/resource_lifecycle_boundaries.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:test/test.dart';

void main() {
  Executor executor() => createExecutor(
    fileSystem: MemoryFileSystem.test(style: FileSystemStyle.posix),
  );

  Future<String> output(List<String> args) async {
    final result = await executor().fake().execute(args);
    expect(result, isA<MambaSuccessResult>(), reason: args.join(' '));
    return (result as MambaSuccessResult).output ?? '';
  }

  group('agent_resource support', () {
    test('prints the full matrix in text', () async {
      final text = await output(<String>['support']);
      for (final resource in BoundaryResource.values) {
        expect(text, contains('${resource.wireName}:'), reason: resource.name);
      }
      expect(text, contains('install: supported (skill install)'));
      expect(text, contains('install: deferred'));
      expect(text, contains('Pack-installed Prompts live under Skill'));
      expect(text, contains('one-shot publication'));
    });

    test('prints the versioned JSON envelope', () async {
      final decoded = jsonDecode(
        await output(<String>['support', '--format', 'json']),
      ) as Map<String, Object?>;
      expect(decoded['schemaVersion'], 1);
      expect(decoded['command'], 'support');
      expect(decoded['outcome'], 'reported');
      final resources = decoded['resources'] as Map<String, Object?>;
      final prompt = resources['prompt'] as Map<String, Object?>;
      final operations = prompt['operations'] as Map<String, Object?>;
      final install = operations['install'] as Map<String, Object?>;
      expect(install['status'], 'supported');
      expect(install['command'], 'pack install');
      expect(
        (prompt['notes'] as List).join(' '),
        contains('direct `prompt install` is deferred'),
      );
      final skill = resources['skill'] as Map<String, Object?>;
      final skillInstall =
          (skill['operations'] as Map<String, Object?>)['install']
              as Map<String, Object?>;
      expect(skillInstall['status'], 'supported');
      expect(skillInstall['command'], 'skill install');
    });

    test('rejects an undeclared option value', () async {
      final result = await executor().fake().execute(<String>[
        'support',
        '--format',
        'yaml',
      ]);
      expect(result, isNot(isA<MambaSuccessResult>()));
    });
  });

  group('resource group help discloses its boundaries', () {
    for (final resource in BoundaryResource.values) {
      test('${resource.wireName} help lists supported and deferred', () async {
        final text = await output(<String>[resource.wireName, '--help']);
        expect(text, contains('Lifecycle boundaries:'), reason: resource.name);
        expect(text, contains('supported:'), reason: resource.name);
        expect(text, contains('deferred'), reason: resource.name);
      });
    }

    test('prompt help discloses the real install routes', () async {
      final text = await output(<String>['prompt', '--help']);
      expect(text, contains('pack install --type prompt'));
      expect(text, contains('--prompt-target'));
      expect(text, contains('direct `prompt install` is deferred'));
    });

    test('context help explains the one-shot injection boundary', () async {
      final text = await output(<String>['context', '--help']);
      expect(text, contains('one-shot publication'));
    });

    test('mcp help discloses the static-check boundary', () async {
      final text = await output(<String>['mcp', '--help']);
      expect(text, contains('static'));
      expect(text, contains('inspect-only'));
    });
  });
}
