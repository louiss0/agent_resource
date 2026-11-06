import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:file/file.dart' as f;
import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'support/compiled_cli_test_support.dart';
import 'support/process_test_support.dart';

const _markerLimit = 1048576;

late final String _entrypoint;
late final String _packageConfig;

f.FileSystem get _fs =>
    Zone.current[#fs] as f.FileSystem? ?? const LocalFileSystem();
path.Context get p => _fs.path;
Future<T> _withDirectory<T>(Future<T> Function(f.Directory root) body) async {
  final fs = MemoryFileSystem.test(style: FileSystemStyle.posix);
  final root = fs.directory('/sandbox')..createSync();
  fs.currentDirectory = root;
  return runZoned(() => body(root), zoneValues: {#fs: fs});
}

Future<T> _withLocalDirectory<T>(
  Future<T> Function(f.Directory root) body,
) async {
  const fs = LocalFileSystem();
  final root = await fs.systemTempDirectory.createTemp(
    'agent-resource-inspect-',
  );
  try {
    return await runZoned(() => body(root), zoneValues: {#fs: fs});
  } finally {
    await root.delete(recursive: true);
  }
}

f.Directory _selected(f.Directory root, [String name = 'skill']) =>
    _fs.directory(p.join(root.path, name))..createSync(recursive: true);

Future<MambaExecutionResult> _execute(
  List<String> arguments, {
  Executor? executor,
}) => (executor ?? createExecutor(fileSystem: _fs)).fake().execute([
  'skill',
  'inspect',
  ...arguments,
]);

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
          'skill',
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
    p.normalize(_fs.directory(value).absolute.path);

Map<String, String> _snapshot(f.Directory root) {
  final entries = <String, String>{};

  void visit(f.Directory directory) {
    for (final entity in directory.listSync(followLinks: false)) {
      final relative = p.relative(entity.path, from: root.path);
      final type = _fs.typeSync(entity.path, followLinks: false);
      entries[relative] = switch (type) {
        FileSystemEntityType.directory => 'directory',
        FileSystemEntityType.file =>
          'file:${base64Encode(_fs.file(entity.path).readAsBytesSync())}',
        FileSystemEntityType.link =>
          'link:${_fs.link(entity.path).targetSync()}',
        FileSystemEntityType.notFound => 'not-found',
        _ => 'other',
      };
      if (type == FileSystemEntityType.directory) {
        visit(_fs.directory(entity.path));
      }
    }
  }

  visit(root);
  final keys = entries.keys.toList()..sort();
  return <String, String>{for (final key in keys) key: entries[key]!};
}

Future<bool> _tryCreateLink(String link, String target) async {
  try {
    await _fs.link(link).create(target);
    return true;
  } on FileSystemException {
    return false;
  } on UnsupportedError {
    return false;
  }
}

String _findProjectRoot() {
  var candidate = _fs.currentDirectory.absolute;
  while (true) {
    if (_fs.file(p.join(candidate.path, 'pubspec.yaml')).existsSync()) {
      return candidate.path;
    }
    final parent = candidate.parent;
    if (parent.path == candidate.path) {
      throw StateError(
        'Could not locate the package root from ${_fs.currentDirectory.path}.',
      );
    }
    candidate = parent;
  }
}

Future<CliProcessResult> _runProduction(
  f.Directory workingDirectory,
  List<String> arguments,
) => runDartScript(
  script: _entrypoint,
  packageConfig: _packageConfig,
  arguments: arguments,
  workingDirectory: workingDirectory,
  environment: isolatedEnvironment(workingDirectory),
);

Future<void> main() async {
  final projectRoot = _findProjectRoot();
  _packageConfig = p.join(projectRoot, '.dart_tool', 'package_config.json');
  _entrypoint = await compileTestCli(
    script: p.join(projectRoot, 'bin', 'agent_resource.dart'),
    packageConfig: _packageConfig,
  );

  group('agent_resource', () {
    group('skill', () {
      group('list', () {
        test('root filesystem reaches default inventory', () async {
          await _withDirectory((root) async {
            final project = _fs.directory(p.join(root.path, 'project'))
              ..createSync();
            final result = await createExecutor(fileSystem: _fs)
                .fake()
                .execute([
                  'skill',
                  'list',
                  '--scope',
                  'project',
                  '--cwd',
                  '${project.path}/',
                  '--project-root',
                  '${project.path}/',
                  '--format',
                  'json',
                ]);
            final report = jsonDecode(_expectSuccess(result).output!);
            expect(report, {
              'schemaVersion': 1,
              'command': 'skill list',
              'outcome': 'inventoried',
              'data': {
                'scope': 'project',
                'verification': 'notVerified',
                'occurrences': <Object?>[],
                'coverage': {
                  'status': 'complete',
                  'rootsScanned': 0,
                  'rootsAbsent': 3,
                  'entries': 0,
                  'limits': {'entries': 10000},
                },
              },
              'diagnostics': <Object?>[],
            });
          });
        });
      });

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
              anyOf(
                contains('1,048,576'),
                contains('1048576'),
                contains('MiB'),
              ),
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
          expect(result.error.commandPath, [
            'agent_resource',
            'skill',
            'inspect',
          ]);
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
            expect(result.error.commandPath, [
              'agent_resource',
              'skill',
              'inspect',
            ]);
          });
        });

        test('rejects a blank skill value at command level', () async {
          _expectFailure(
            await _execute(const ['--skill', '']),
            phase: MambaExecutionPhase.parse,
            diagnostic: contains('--skill'),
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

        test(
          'permission-denied lookup fails instead of appearing markerless',
          () async {
            if (Platform.isWindows) {
              markTestSkipped(
                'portable permission setup is unavailable on Windows',
              );
              return;
            }
            await _withLocalDirectory((root) async {
              _fs
                  .file(p.join(root.path, 'SKILL.md'))
                  .writeAsStringSync('content');
              final changed = await Process.run('chmod', ['000', root.path]);
              if (changed.exitCode != 0) {
                markTestSkipped('chmod is unavailable');
                return;
              }
              try {
                try {
                  root.listSync();
                  markTestSkipped(
                    'the host did not enforce directory permissions',
                  );
                  return;
                } on FileSystemException {
                  // Permission denial is available for this regression check.
                }
                _expectFailure(
                  await _execute(['--skill', root.path]),
                  phase: MambaExecutionPhase.run,
                  diagnostic: isNotEmpty,
                );
              } finally {
                await Process.run('chmod', ['700', root.path]);
              }
            });
          },
        );

        test('rejects an ordinary file selected as the root', () async {
          await _withDirectory((root) async {
            final file = _fs.file(p.join(root.path, 'not-a-directory'))
              ..writeAsStringSync('sentinel');
            _expectFailure(
              await _execute(['--skill', file.path]),
              phase: MambaExecutionPhase.run,
              diagnostic: contains('not-a-directory'),
            );
          });
        });

        test('returns the exact three-field JSON contract', () async {
          final fs = MemoryFileSystem.test(style: FileSystemStyle.posix);
          final selected = fs.directory('/sandbox/skill')
            ..createSync(recursive: true);
          final result = _expectSuccess(
            await _execute([
              '--skill',
              selected.path,
            ], executor: createExecutor(fileSystem: fs)),
          );
          final value = _inspection(result);
          expect(value, {
            'path': selected.path,
            'hasSkillFile': false,
            'content': null,
          });
        });

        test('normalizes an absolute dot-segment selection', () async {
          await _withDirectory((root) async {
            final selected = _selected(root, 'selected');
            final argument = p.join(
              root.path,
              '.',
              'selected',
              '..',
              'selected',
            );
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
              from: _fs.currentDirectory.path,
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
          expect(
            result.output,
            allOf(contains('inspect'), contains('--skill')),
          );
        });

        test('production success emits JSON on stdout only', () async {
          await _withLocalDirectory((root) async {
            final marker = _fs.file(p.join(root.path, 'SKILL.md'))
              ..writeAsStringSync('process success\n');
            final result = await _runProduction(root, [
              'skill',
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
          await _withLocalDirectory((root) async {
            final missing = p.join(root.path, 'missing');
            final result = await _runProduction(root, [
              'skill',
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
            await _withLocalDirectory((parent) async {
              final target = _fs.directory(p.join(parent.path, 'target'))
                ..createSync(recursive: true);
              final alias = p.join(parent.path, 'alias');
              _fs
                  .file(p.join(target.path, 'SKILL.md'))
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
            });
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
              final marker = _fs.file(p.join(root.path, 'SKILL.md'))
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
            _fs.directory(p.join(root.path, 'SKILL.md')).createSync();
            final value = _inspection(
              _expectSuccess(await _execute(['--skill', root.path])),
            );
            expect(value['hasSkillFile'], isFalse);
            expect(value['content'], isNull);
          });
        });

        test('rejects malformed UTF-8 without replacement text', () async {
          await _withDirectory((root) async {
            final marker = _fs.file(p.join(root.path, 'SKILL.md'))
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
            final marker = _fs.file(p.join(root.path, 'SKILL.md'))
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
            final marker = _fs.file(p.join(root.path, 'SKILL.md'))
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
            _fs.file(p.join(root.path, 'SKILL.md')).writeAsBytesSync(bytes);
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
            final nested = _fs.directory(p.join(root.path, 'nested'))
              ..createSync();
            _fs
                .file(p.join(nested.path, 'SKILL.md'))
                .writeAsStringSync('nested');
            final value = _inspection(
              _expectSuccess(await _execute(['--skill', root.path])),
            );
            expect(value['hasSkillFile'], isFalse);
            expect(value['content'], isNull);
          });
        });

        test('does not traverse a nested link cycle', () async {
          await _withLocalDirectory((root) async {
            final nested = _fs.directory(p.join(root.path, 'nested'))
              ..createSync();
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
          await _withLocalDirectory((root) async {
            final selected = _selected(root, 'selected');
            final target = _fs.file(p.join(root.path, 'external-marker.md'))
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
            _fs
                .file(p.join(selected.path, 'SKILL.md'))
                .writeAsStringSync('text');
            _fs
                .file(p.join(selected.path, 'sentinel.txt'))
                .writeAsStringSync('unchanged');
            _fs.directory(p.join(selected.path, 'nested')).createSync();
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
            _fs.file(p.join(selected.path, 'SKILL.md')).writeAsBytesSync(
              const <int>[0xFF],
            );
            _fs
                .file(p.join(selected.path, 'sentinel.txt'))
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
            _fs
                .file(p.join(selected.path, 'SKILL.md'))
                .writeAsBytesSync(List<int>.filled(_markerLimit + 1, 0x42));
            _fs
                .file(p.join(selected.path, 'sentinel.txt'))
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
            final marker = _fs.file(p.join(root.path, 'SKILL.md'))
              ..writeAsStringSync('marker');
            final first = _inspection(
              _expectSuccess(await _execute(['--skill', root.path])),
            );
            _fs
                .file(p.join(root.path, 'ordinary.txt'))
                .writeAsStringSync('other');
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
            _fs
                .file(p.join(firstDirectory.path, 'SKILL.md'))
                .writeAsStringSync('first');
            _fs
                .file(p.join(secondDirectory.path, 'SKILL.md'))
                .writeAsStringSync('second');
            final adapter = createExecutor(fileSystem: _fs).fake();
            final first = _inspection(
              _expectSuccess(
                await adapter.execute([
                  'skill',
                  'inspect',
                  '--skill',
                  firstDirectory.path,
                ]),
              ),
            );
            final second = _inspection(
              _expectSuccess(
                await adapter.execute([
                  'skill',
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

        test(
          'reuses one adapter across invalid and valid selections',
          () async {
            await _withDirectory((root) async {
              final adapter = createExecutor(fileSystem: _fs).fake();
              final missing = p.join(root.path, 'missing');
              _expectFailure(
                await adapter.execute(['skill', 'inspect', '--skill', missing]),
                phase: MambaExecutionPhase.run,
                diagnostic: contains('missing'),
              );
              final value = _inspection(
                _expectSuccess(
                  await adapter.execute([
                    'skill',
                    'inspect',
                    '--skill',
                    root.path,
                  ]),
                ),
              );
              expect(value['path'], _absoluteLexical(root.path));
            });
          },
        );

        test(
          'does not retain content when the next marker is absent',
          () async {
            await _withDirectory((root) async {
              final first = _selected(root, 'first');
              final second = _selected(root, 'second');
              _fs
                  .file(p.join(first.path, 'SKILL.md'))
                  .writeAsStringSync('stale');
              final adapter = createExecutor(fileSystem: _fs).fake();
              final firstValue = _inspection(
                _expectSuccess(
                  await adapter.execute([
                    'skill',
                    'inspect',
                    '--skill',
                    first.path,
                  ]),
                ),
              );
              final secondValue = _inspection(
                _expectSuccess(
                  await adapter.execute([
                    'skill',
                    'inspect',
                    '--skill',
                    second.path,
                  ]),
                ),
              );
              expect(firstValue['content'], 'stale');
              expect(secondValue['hasSkillFile'], isFalse);
              expect(secondValue['content'], isNull);
            });
          },
        );

        test(
          'help and parser rejection leave filesystem sentinels unchanged',
          () async {
            await _withDirectory((root) async {
              final sentinel = _fs.file(p.join(root.path, 'sentinel.txt'))
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
  });
}
