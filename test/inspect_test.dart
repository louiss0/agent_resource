import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/process_test_support.dart';

const _markerLimit = 1048576;

late final String _entrypoint;
late final String _packageConfig;

Future<T> _withDirectory<T>(Future<T> Function(Directory root) body) async {
  final root = await Directory.systemTemp.createTemp('agent-resource-inspect-');
  try {
    return await body(root);
  } finally {
    await root.delete(recursive: true);
  }
}

Directory _selected(Directory root, [String name = 'skill']) =>
    Directory(p.join(root.path, name))..createSync(recursive: true);

Future<MambaExecutionResult> _execute(
  List<String> arguments, {
  Executor? executor,
}) => (executor ?? createExecutor()).fake().execute(['inspect', ...arguments]);

MambaSuccessResult _expectSuccess(MambaExecutionResult result) {
  expect(
    result,
    isA<MambaSuccessResult>()
        .having((value) => value.exitCode, 'exit code', 0)
        .having((value) => value.output, 'output', isNotNull),
  );
  return result as MambaSuccessResult;
}

MambaFailureResult _expectFailure(
  MambaExecutionResult result, {
  required MambaExecutionPhase phase,
  required Matcher diagnostic,
}) {
  expect(
    result,
    isA<MambaFailureResult>()
        .having((value) => value.exitCode, 'exit code', isNonZero)
        .having((value) => value.message, 'message', diagnostic)
        .having((value) => value.output, 'output', isNull)
        .having((value) => value.error.phase, 'phase', phase)
        .having((value) => value.error.commandPath, 'command path', [
          'agent_resource',
          'inspect',
        ]),
  );
  return result as MambaFailureResult;
}

Map<String, Object?> _inspection(MambaSuccessResult result) {
  final decoded = jsonDecode(result.output!);
  expect(decoded, isA<Map<Object?, Object?>>());
  final value = Map<String, Object?>.from(decoded as Map<Object?, Object?>);
  expect(value.keys.toSet(), {'path', 'hasSkillFile', 'content'});
  expect(value['path'], isA<String>());
  expect(value['hasSkillFile'], isA<bool>());
  expect(value['content'], anyOf(isNull, isA<String>()));
  return value;
}

String _absoluteLexical(String value) =>
    p.normalize(Directory(value).absolute.path);

Map<String, String> _snapshot(Directory root) {
  final entries = <String, String>{};

  void visit(Directory directory) {
    for (final entity in directory.listSync(followLinks: false)) {
      final relative = p.relative(entity.path, from: root.path);
      final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
      entries[relative] = switch (type) {
        FileSystemEntityType.directory => 'directory',
        FileSystemEntityType.file =>
          'file:${base64Encode(File(entity.path).readAsBytesSync())}',
        FileSystemEntityType.link => 'link:${Link(entity.path).targetSync()}',
        FileSystemEntityType.notFound => 'not-found',
        _ => 'other',
      };
      if (type == FileSystemEntityType.directory) visit(Directory(entity.path));
    }
  }

  visit(root);
  final keys = entries.keys.toList()..sort();
  return <String, String>{for (final key in keys) key: entries[key]!};
}

Future<bool> _tryCreateLink(String link, String target) async {
  try {
    await Link(link).create(target);
    return true;
  } on FileSystemException {
    return false;
  } on UnsupportedError {
    return false;
  }
}

String _findProjectRoot() {
  var candidate = Directory.current.absolute;
  while (true) {
    if (File(p.join(candidate.path, 'pubspec.yaml')).existsSync()) {
      return candidate.path;
    }
    final parent = candidate.parent;
    if (parent.path == candidate.path) {
      throw StateError(
        'Could not locate the package root from ${Directory.current.path}.',
      );
    }
    candidate = parent;
  }
}

Future<CliProcessResult> _runProduction(
  Directory workingDirectory,
  List<String> arguments,
) => runDartScript(
  script: _entrypoint,
  packageConfig: _packageConfig,
  arguments: arguments,
  workingDirectory: workingDirectory,
  environment: isolatedEnvironment(workingDirectory),
);

void main() {
  final projectRoot = _findProjectRoot();
  _entrypoint = p.join(projectRoot, 'bin', 'agent_resource.dart');
  _packageConfig = p.join(projectRoot, '.dart_tool', 'package_config.json');

  group('agent_resource', () {
    group('inspect', () {
      test(
        'help explains the inspection contract and required option',
        () async {
          final result = _expectSuccess(await _execute(const ['--help']));
          final help = result.output!;
          expect(help, contains('inspect'));
          expect(help, contains('--skill'));
          expect(help, contains('SKILL.md'));
          expect(
            help,
            anyOf(contains('1,048,576'), contains('1048576'), contains('MiB')),
          );
          expect(help.toLowerCase(), contains('validation'));
        },
      );

      test('requires a selected skill directory', () async {
        final result = _expectFailure(
          await _execute(const []),
          phase: MambaExecutionPhase.parse,
          diagnostic: contains('skill'),
        );
        expect(result.error.commandPath, ['agent_resource', 'inspect']);
      });

      test('requires a value after the skill option', () async {
        _expectFailure(
          await _execute(const ['--skill']),
          phase: MambaExecutionPhase.parse,
          diagnostic: contains('skill'),
        );
      });

      test('rejects unknown options', () async {
        _expectFailure(
          await _execute(const ['--unknown', 'value']),
          phase: MambaExecutionPhase.parse,
          diagnostic: contains('--unknown'),
        );
      });

      test('rejects unexpected positional input', () async {
        await _withDirectory((root) async {
          final result = _expectFailure(
            await _execute(['--skill', root.path, 'extra']),
            phase: MambaExecutionPhase.parse,
            diagnostic: contains('extra'),
          );
          expect(result.error.commandPath, ['agent_resource', 'inspect']);
        });
      });

      test('rejects a blank skill value at command level', () async {
        _expectFailure(
          await _execute(const ['--skill', '']),
          phase: MambaExecutionPhase.run,
          diagnostic: contains('blank'),
        );
      });

      test('rejects a nonexistent selected directory', () async {
        await _withDirectory((root) async {
          final missing = p.join(root.path, 'does-not-exist');
          _expectFailure(
            await _execute(['--skill', missing]),
            phase: MambaExecutionPhase.run,
            diagnostic: contains('does-not-exist'),
          );
        });
      });

      test('rejects an ordinary file selected as the root', () async {
        await _withDirectory((root) async {
          final file = File(p.join(root.path, 'not-a-directory'))
            ..writeAsStringSync('sentinel');
          _expectFailure(
            await _execute(['--skill', file.path]),
            phase: MambaExecutionPhase.run,
            diagnostic: contains('not-a-directory'),
          );
        });
      });

      test('returns the exact three-field JSON contract', () async {
        await _withDirectory((root) async {
          final selected = _selected(root);
          final result = _expectSuccess(
            await _execute(['--skill', selected.path]),
          );
          final value = _inspection(result);
          expect(value, {
            'path': _absoluteLexical(selected.path),
            'hasSkillFile': false,
            'content': null,
          });
        });
      });

      test('normalizes an absolute dot-segment selection', () async {
        await _withDirectory((root) async {
          final selected = _selected(root, 'selected');
          final argument = p.join(root.path, '.', 'selected', '..', 'selected');
          final value = _inspection(
            _expectSuccess(await _execute(['--skill', argument])),
          );
          expect(value['path'], _absoluteLexical(argument));
          expect(value['path'], _absoluteLexical(selected.path));
        });
      });

      test('normalizes a relative selection', () async {
        await _withDirectory((root) async {
          final selected = _selected(root, 'relative');
          final argument = p.relative(
            selected.path,
            from: Directory.current.path,
          );
          final value = _inspection(
            _expectSuccess(await _execute(['--skill', argument])),
          );
          expect(value['path'], _absoluteLexical(argument));
        });
      });

      test('accepts the equals form of the required option', () async {
        await _withDirectory((root) async {
          final value = _inspection(
            _expectSuccess(await _execute(['--skill=${root.path}'])),
          );
          expect(value['path'], _absoluteLexical(root.path));
        });
      });

      test('help succeeds without selecting a directory', () async {
        final result = _expectSuccess(await _execute(const ['--help']));
        expect(result.output, allOf(contains('inspect'), contains('--skill')));
      });

      test('production success emits JSON on stdout only', () async {
        await _withDirectory((root) async {
          final marker = File(p.join(root.path, 'SKILL.md'))
            ..writeAsStringSync('process success\n');
          final result = await _runProduction(root, [
            'inspect',
            '--skill',
            root.path,
          ]);
          expect(result.exitCode, 0);
          expect(result.stderr, isEmpty);
          expect(jsonDecode(result.stdout), {
            'path': _absoluteLexical(root.path),
            'hasSkillFile': true,
            'content': marker.readAsStringSync(),
          });
        });
      });

      test('production failure emits stderr without partial JSON', () async {
        await _withDirectory((root) async {
          final missing = p.join(root.path, 'missing');
          final result = await _runProduction(root, [
            'inspect',
            '--skill',
            missing,
          ]);
          expect(result.exitCode, isNonZero);
          expect(result.stdout, isEmpty);
          expect(result.stderr, contains('missing'));
        });
      });

      test(
        'accepts a directory link as the explicitly selected root',
        () async {
          final parent = await Directory.systemTemp.createTemp(
            'agent-resource-inspect-root-link-',
          );
          final target = Directory(p.join(parent.path, 'target'))
            ..createSync(recursive: true);
          final alias = p.join(parent.path, 'alias');
          try {
            File(p.join(target.path, 'SKILL.md'))
                .writeAsStringSync('linked root');
            if (!await _tryCreateLink(alias, target.path)) {
              markTestSkipped('directory symlink creation is unavailable');
              return;
            }
            final value = _inspection(
              _expectSuccess(await _execute(['--skill', alias])),
            );
            expect(value, {
              'path': _absoluteLexical(alias),
              'hasSkillFile': true,
              'content': 'linked root',
            });
          } finally {
            await parent.delete(recursive: true);
          }
        },
      );

      final textCases = <({String name, List<int> bytes})>[
        (name: 'empty marker', bytes: const <int>[]),
        (name: 'multiline marker', bytes: utf8.encode('one\ntwo\nthree')),
        (name: 'CRLF line endings', bytes: utf8.encode('one\r\ntwo\r\n')),
        (name: 'trailing whitespace', bytes: utf8.encode('text  \t\n')),
        (name: 'no final newline', bytes: utf8.encode('no newline')),
        (name: 'Unicode text', bytes: utf8.encode('café 🚀 日本語')),
        (
          name: 'leading BOM',
          bytes: const <int>[0xEF, 0xBB, 0xBF, 0x42, 0x4F, 0x4D],
        ),
        (
          name: 'malformed frontmatter',
          bytes: utf8.encode('---\n: malformed [frontmatter\n---\nbody'),
        ),
      ];

      for (final textCase in textCases) {
        test('preserves ${textCase.name}', () async {
          await _withDirectory((root) async {
            final marker = File(p.join(root.path, 'SKILL.md'))
              ..writeAsBytesSync(textCase.bytes);
            final value = _inspection(
              _expectSuccess(await _execute(['--skill', root.path])),
            );
            expect(value['hasSkillFile'], isTrue);
            expect(value['content'], utf8.decode(textCase.bytes));
            expect(marker.readAsBytesSync(), textCase.bytes);
          });
        });
      }

      test('reports an absent marker as false and null', () async {
        await _withDirectory((root) async {
          final value = _inspection(
            _expectSuccess(await _execute(['--skill', root.path])),
          );
          expect(value['hasSkillFile'], isFalse);
          expect(value['content'], isNull);
        });
      });

      test('reports a marker directory as false and null', () async {
        await _withDirectory((root) async {
          Directory(p.join(root.path, 'SKILL.md')).createSync();
          final value = _inspection(
            _expectSuccess(await _execute(['--skill', root.path])),
          );
          expect(value['hasSkillFile'], isFalse);
          expect(value['content'], isNull);
        });
      });

      test('rejects malformed UTF-8 without replacement text', () async {
        await _withDirectory((root) async {
          final marker = File(p.join(root.path, 'SKILL.md'))
            ..writeAsBytesSync(const <int>[0xC3, 0x28]);
          _expectFailure(
            await _execute(['--skill', root.path]),
            phase: MambaExecutionPhase.run,
            diagnostic: anyOf(contains('UTF-8'), contains('utf8')),
          );
          expect(marker.readAsBytesSync(), const <int>[0xC3, 0x28]);
        });
      });

      test('accepts exactly the one MiB marker byte limit', () async {
        await _withDirectory((root) async {
          final bytes = List<int>.filled(_markerLimit, 0x41);
          final marker = File(p.join(root.path, 'SKILL.md'))
            ..writeAsBytesSync(bytes);
          final value = _inspection(
            _expectSuccess(await _execute(['--skill', root.path])),
          );
          expect(value['hasSkillFile'], isTrue);
          expect(value['content'], utf8.decode(bytes));
          expect(marker.lengthSync(), _markerLimit);
        });
      });

      test('rejects a marker one byte over the limit', () async {
        await _withDirectory((root) async {
          final bytes = List<int>.filled(_markerLimit + 1, 0x41);
          final marker = File(p.join(root.path, 'SKILL.md'))
            ..writeAsBytesSync(bytes);
          final before = marker.readAsBytesSync();
          _expectFailure(
            await _execute(['--skill', root.path]),
            phase: MambaExecutionPhase.run,
            diagnostic: anyOf(
              contains('1,048,576'),
              contains('1048576'),
              contains('MiB'),
            ),
          );
          expect(marker.readAsBytesSync(), before);
        });
      });

      test('limits bytes rather than decoded character count', () async {
        await _withDirectory((root) async {
          final bytes = <int>[
            ...List<int>.filled(_markerLimit - 1, 0x41),
            0xE2,
            0x82,
            0xAC,
          ];
          expect(bytes.length, _markerLimit + 2);
          File(p.join(root.path, 'SKILL.md')).writeAsBytesSync(bytes);
          _expectFailure(
            await _execute(['--skill', root.path]),
            phase: MambaExecutionPhase.run,
            diagnostic: anyOf(
              contains('1,048,576'),
              contains('1048576'),
              contains('MiB'),
            ),
          );
        });
      });

      test('does not recurse to a nested marker', () async {
        await _withDirectory((root) async {
          final nested = Directory(p.join(root.path, 'nested'))..createSync();
          File(p.join(nested.path, 'SKILL.md')).writeAsStringSync('nested');
          final value = _inspection(
            _expectSuccess(await _execute(['--skill', root.path])),
          );
          expect(value['hasSkillFile'], isFalse);
          expect(value['content'], isNull);
        });
      });

      test('does not traverse a nested link cycle', () async {
        await _withDirectory((root) async {
          final nested = Directory(p.join(root.path, 'nested'))..createSync();
          if (!await _tryCreateLink(p.join(nested.path, 'loop'), root.path)) {
            markTestSkipped('directory symlink creation is unavailable');
            return;
          }
          final value = _inspection(
            _expectSuccess(await _execute(['--skill', root.path])),
          );
          expect(value['hasSkillFile'], isFalse);
          expect(value['content'], isNull);
        });
      });

      test('excludes a linked marker without reading its target', () async {
        await _withDirectory((root) async {
          final selected = _selected(root, 'selected');
          final target = File(p.join(root.path, 'external-marker.md'))
            ..writeAsBytesSync([0xff, 0xfe, 0x80]);
          final link = p.join(selected.path, 'SKILL.md');
          if (!await _tryCreateLink(link, target.path)) {
            markTestSkipped('file symlink creation is unavailable');
            return;
          }
          final before = target.readAsBytesSync();
          final value = _inspection(
            _expectSuccess(await _execute(['--skill', selected.path])),
          );
          expect(value['hasSkillFile'], isFalse);
          expect(value['content'], isNull);
          expect(target.readAsBytesSync(), before);
        });
      });

      test('preserves all selected-directory entries on success', () async {
        await _withDirectory((root) async {
          final selected = _selected(root);
          File(p.join(selected.path, 'SKILL.md')).writeAsStringSync('text');
          File(p.join(selected.path, 'sentinel.txt'))
              .writeAsStringSync('unchanged');
          Directory(p.join(selected.path, 'nested')).createSync();
          final before = _snapshot(selected);
          final value = _inspection(
            _expectSuccess(await _execute(['--skill', selected.path])),
          );
          expect(value, {
            'path': _absoluteLexical(selected.path),
            'hasSkillFile': true,
            'content': 'text',
          });
          expect(_snapshot(selected), before);
        });
      });

      test('preserves sentinels after invalid UTF-8 failure', () async {
        await _withDirectory((root) async {
          final selected = _selected(root);
          File(p.join(selected.path, 'SKILL.md'))
              .writeAsBytesSync(const <int>[0xFF]);
          File(p.join(selected.path, 'sentinel.txt'))
              .writeAsStringSync('unchanged');
          final before = _snapshot(selected);
          _expectFailure(
            await _execute(['--skill', selected.path]),
            phase: MambaExecutionPhase.run,
            diagnostic: anyOf(contains('UTF-8'), contains('utf8')),
          );
          expect(_snapshot(selected), before);
        });
      });

      test('preserves sentinels after over-limit failure', () async {
        await _withDirectory((root) async {
          final selected = _selected(root);
          File(p.join(selected.path, 'SKILL.md'))
              .writeAsBytesSync(List<int>.filled(_markerLimit + 1, 0x42));
          File(p.join(selected.path, 'sentinel.txt'))
              .writeAsStringSync('unchanged');
          final before = _snapshot(selected);
          _expectFailure(
            await _execute(['--skill', selected.path]),
            phase: MambaExecutionPhase.run,
            diagnostic: anyOf(
              contains('1,048,576'),
              contains('1048576'),
              contains('MiB'),
            ),
          );
          expect(_snapshot(selected), before);
        });
      });

      test('unrelated entries do not affect marker inspection', () async {
        await _withDirectory((root) async {
          final marker = File(p.join(root.path, 'SKILL.md'))
            ..writeAsStringSync('marker');
          final first = _inspection(
            _expectSuccess(await _execute(['--skill', root.path])),
          );
          File(p.join(root.path, 'ordinary.txt')).writeAsStringSync('other');
          final second = _inspection(
            _expectSuccess(await _execute(['--skill', root.path])),
          );
          expect(second, equals(first));
          expect(marker.readAsStringSync(), 'marker');
        });
      });

      test('reuses one adapter without stale content', () async {
        await _withDirectory((root) async {
          final firstDirectory = _selected(root, 'first');
          final secondDirectory = _selected(root, 'second');
          File(p.join(firstDirectory.path, 'SKILL.md'))
              .writeAsStringSync('first');
          File(p.join(secondDirectory.path, 'SKILL.md'))
              .writeAsStringSync('second');
          final adapter = createExecutor().fake();
          final first = _inspection(
            _expectSuccess(
              await adapter.execute([
                'inspect',
                '--skill',
                firstDirectory.path,
              ]),
            ),
          );
          final second = _inspection(
            _expectSuccess(
              await adapter.execute([
                'inspect',
                '--skill',
                secondDirectory.path,
              ]),
            ),
          );
          expect(first['content'], 'first');
          expect(second['content'], 'second');
          expect(first['path'], isNot(second['path']));
        });
      });

      test('reuses one adapter across invalid and valid selections', () async {
        await _withDirectory((root) async {
          final adapter = createExecutor().fake();
          final missing = p.join(root.path, 'missing');
          _expectFailure(
            await adapter.execute(['inspect', '--skill', missing]),
            phase: MambaExecutionPhase.run,
            diagnostic: contains('missing'),
          );
          final value = _inspection(
            _expectSuccess(
              await adapter.execute(['inspect', '--skill', root.path]),
            ),
          );
          expect(value['path'], _absoluteLexical(root.path));
        });
      });

      test('does not retain content when the next marker is absent', () async {
        await _withDirectory((root) async {
          final first = _selected(root, 'first');
          final second = _selected(root, 'second');
          File(p.join(first.path, 'SKILL.md')).writeAsStringSync('stale');
          final adapter = createExecutor().fake();
          final firstValue = _inspection(
            _expectSuccess(
              await adapter.execute(['inspect', '--skill', first.path]),
            ),
          );
          final secondValue = _inspection(
            _expectSuccess(
              await adapter.execute(['inspect', '--skill', second.path]),
            ),
          );
          expect(firstValue['content'], 'stale');
          expect(secondValue['hasSkillFile'], isFalse);
          expect(secondValue['content'], isNull);
        });
      });

      test(
        'help and parser rejection leave filesystem sentinels unchanged',
        () async {
          await _withDirectory((root) async {
            final sentinel = File(p.join(root.path, 'sentinel.txt'))
              ..writeAsStringSync('unchanged');
            final before = _snapshot(root);
            final help = _expectSuccess(
              await _execute(['--skill', root.path, '--help']),
            );
            expect(help.output, contains('--skill'));
            expect(_snapshot(root), before);
            _expectFailure(
              await _execute(const ['--unknown']),
              phase: MambaExecutionPhase.parse,
              diagnostic: contains('--unknown'),
            );
            expect(_snapshot(root), before);
            expect(sentinel.readAsStringSync(), 'unchanged');
          });
        },
      );
    });
  });
}
