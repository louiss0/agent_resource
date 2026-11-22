import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:agent_resource/src/harness/harness_catalog.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:agent_resource/src/resource_lifecycle_boundaries.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

const String _bannerToken = 'Historical design record';

String _read(String path) =>
    File(path).readAsStringSync().replaceAll('\r\n', '\n');

Iterable<File> _markdownFiles(String directory) =>
    Directory(directory)
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.md'));

/// Joins `\`-continued lines and returns the content lines of fenced blocks.
Iterable<String> _fencedLines(String markdown) sync* {
  var inFence = false;
  var pending = '';
  for (final rawLine in markdown.split(RegExp(r'\r?\n'))) {
    final line = rawLine.trimRight();
    if (line.trimLeft().startsWith('```')) {
      inFence = !inFence;
      pending = '';
      continue;
    }
    if (!inFence) continue;
    pending += line;
    if (pending.endsWith(r'\')) {
      pending = '${pending.substring(0, pending.length - 1)} ';
      continue;
    }
    yield pending;
    pending = '';
  }
}

/// Extracts `agent-resource` invocation tokens from the fenced blocks of a
/// document. Comment lines and trailing shell comments are dropped, and
/// `<placeholder>` tokens are replaced by a concrete value.
List<List<String>> _invocations(String markdown) {
  final invocations = <List<String>>[];
  for (final line in _fencedLines(markdown)) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    const prefixes = [
      'agent-resource ',
      'agent_resource ',
      'dart run bin/agent_resource.dart ',
    ];
    String? args;
    for (final prefix in prefixes) {
      if (trimmed.startsWith(prefix)) {
        args = trimmed.substring(prefix.length);
        break;
      }
    }
    if (args == null) continue;
    final commentIndex = args.indexOf(' #');
    if (commentIndex != -1) args = args.substring(0, commentIndex);
    args = args.replaceAllMapped(RegExp(r'<[^>]*>'), (match) => 'placeholder');
    final tokens = args
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    if (tokens.isNotEmpty) invocations.add(tokens);
  }
  return invocations;
}

void _collectNames(dynamic input, Set<String> names, {String? prefix}) {
  if (input is AccessorListOption) {
    names.add(input.name);
    for (final leaf in input.options) {
      _collectNames(leaf, names, prefix: input.name);
    }
    return;
  }
  final name = (input as dynamic).name as String;
  names.add(name);
  if (prefix != null) names.add('$prefix.$name');
}

Set<String> _declaredInputs(Executor executor, List<Command> path) {
  final names = <String>{'help', 'version'};
  void collectAll(Iterable<dynamic> inputs) {
    for (final input in inputs) {
      _collectNames(input, names);
    }
  }

  collectAll(executor.flags);
  collectAll(executor.options);
  collectAll(executor.accessors);
  for (final command in path) {
    collectAll(command.flags ?? const <Flag<Object?>>[]);
    collectAll(command.options ?? const <Option<Object?>>[]);
    collectAll(command.accessors ?? const <AccessorListOption>[]);
    if (command is GroupCommand) {
      collectAll(command.inheritedFlags ?? const <Flag<Object?>>[]);
      collectAll(command.inheritedOptions ?? const <Option<Object?>>[]);
    }
  }
  return names;
}

/// Resolves leading command-path tokens against the real command tree.
/// Returns the resolved path and the index of the first non-path token.
({List<Command> path, int rest}) _resolvePath(
  Executor executor,
  List<String> tokens,
) {
  var commands = executor.commands;
  final path = <Command>[];
  var index = 0;
  while (index < tokens.length && !tokens[index].startsWith('-')) {
    final name = tokens[index];
    Command? match;
    for (final command in commands) {
      if (command.name == name) {
        match = command;
        break;
      }
    }
    if (match == null) break;
    path.add(match);
    commands = match is GroupCommand ? match.commands : const <Command>[];
    index++;
  }
  return (path: path, rest: index);
}

void main() {
  group('historical document banners', () {
    test('every docs/specs document carries the banner', () {
      final files = _markdownFiles('docs/specs').toList();
      expect(files, isNotEmpty);
      for (final file in files) {
        final head = File(file.path)
            .readAsStringSync()
            .split('\n')
            .take(5)
            .join('\n');
        expect(head, contains(_bannerToken), reason: file.path);
      }
    });

    test('every docs/research document carries the banner', () {
      for (final file in _markdownFiles('docs/research')) {
        final head = File(file.path)
            .readAsStringSync()
            .split('\n')
            .take(5)
            .join('\n');
        expect(head, contains(_bannerToken), reason: file.path);
      }
    });

    test('the legacy migration guide carries the banner', () {
      expect(
        _read('docs/migrate-interactive-installation.md')
            .split('\n')
            .take(5)
            .join('\n'),
        contains(_bannerToken),
      );
    });
  });

  group('README support matrix', () {
    test('the lifecycle matrix matches the boundary contract', () {
      expect(
        _read('README.md'),
        contains(renderSupportMatrixText()),
        reason:
            'README.md support matrix is stale; regenerate it from '
            'lib/src/resource_lifecycle_boundaries.dart.',
      );
    });

    test('the harness matrix matches the catalog', () {
      final readme = _read('README.md');
      final rows = <String, List<String>>{};
      for (final line in readme.split('\n')) {
        final match = RegExp(
          r'^\|\s*(\w+)\s*\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|([^|]*)\|',
        ).firstMatch(line.trim());
        if (match == null) continue;
        final harness = match.group(1)!;
        if (harness == 'Harness' || harness.startsWith('-')) continue;
        rows[harness] = [for (var i = 2; i <= 6; i++) match.group(i)!.trim()];
      }
      expect(
        rows.keys.toSet(),
        equals({for (final id in HarnessId.values) id.wireName}),
        reason: 'README harness table rows',
      );

      String skillCell(HarnessId id) =>
          HarnessCatalog.instance.skillInstallationTargets.contains(id)
          ? 'install'
          : '—';
      String promptCell(HarnessId id) {
        final spec = promptHarnessFacets[id];
        if (spec == null) return '—';
        return switch (spec.skillConversionForm) {
          PromptConversionForm.skillBacked => 'skill-backed',
          PromptConversionForm.template => 'template',
        };
      }

      String yesCell(bool present) => present ? 'supported' : '—';
      for (final id in HarnessId.values) {
        final row = rows[id.wireName]!;
        final expected = [
          skillCell(id),
          promptCell(id),
          yesCell(HarnessCatalog.instance.supports(id, HarnessFacet.agent)),
          yesCell(McpHarness.values.any((h) => h.wireName == id.wireName)),
          yesCell(contextHarnessFacets.containsKey(id)),
        ];
        expect(row, equals(expected), reason: id.wireName);
      }
    });
  });

  group('documented command examples', () {
    test('every fenced agent-resource invocation resolves and parses', () {
      final executor = createExecutor();
      final documents = <String>[
        'README.md',
        ..._markdownFiles('docs/guides').map((file) => file.path),
      ];
      final failures = <String>[];
      var checked = 0;
      for (final document in documents) {
        for (final tokens in _invocations(_read(document))) {
          checked++;
          final label = '$document: agent-resource ${tokens.join(' ')}';
          final resolution = _resolvePath(executor, tokens);
          if (resolution.path.isEmpty &&
              resolution.rest < tokens.length &&
              !tokens[resolution.rest].startsWith('-')) {
            failures.add('$label — unknown command path');
            continue;
          }
          final declared = _declaredInputs(executor, resolution.path);
          for (var i = resolution.rest; i < tokens.length; i++) {
            final token = tokens[i];
            if (!token.startsWith('--')) continue;
            final name = token.substring(2).split('=').first;
            if (!declared.contains(name)) {
              failures.add('$label — undeclared option --$name');
            }
          }
        }
      }
      expect(checked, greaterThan(10), reason: 'sanity: examples extracted');
      expect(failures, isEmpty, reason: failures.join('\n'));
    });
  });
}
