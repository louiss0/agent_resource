import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/process_test_support.dart';

late final String _entrypoint;
late final String _packageConfig;

const _destinations = <String, String>{
  'shared': '.agents',
  'claude': '.claude',
  'codex': '.codex',
};

Future<T> _withProject<T>(Future<T> Function(Directory project) body) async {
  final parent = await Directory.systemTemp.createTemp(
    'agent-resource-discover-',
  );
  final project = Directory(p.join(parent.path, 'project'))
    ..createSync(recursive: true);
  try {
    return await body(project);
  } finally {
    await parent.delete(recursive: true);
  }
}

Directory _skillsDirectory(Directory project, String destination) =>
    Directory(p.join(project.path, _destinations[destination]!, 'skills'))
      ..createSync(recursive: true);

Directory _candidate(
  Directory project,
  String destination,
  String name, {
  bool createMarker = false,
}) {
  final directory = Directory(
    p.join(_skillsDirectory(project, destination).path, name),
  )..createSync(recursive: true);
  if (createMarker) {
    File(p.join(directory.path, 'SKILL.md')).writeAsStringSync('# $name');
  }
  return directory;
}

String _skillPath(String projectArgument, String destination, String name) =>
    p.normalize(
      p.absolute(
        p.join(projectArgument, _destinations[destination]!, 'skills', name),
      ),
    );

Map<String, Object?> _occurrence(
  String projectArgument,
  String destination,
  String name, {
  required bool hasSkillFile,
}) => <String, Object?>{
  'path': _skillPath(projectArgument, destination, name),
  'destination': destination,
  'installationScope': 'project',
  'hasSkillFile': hasSkillFile,
};

Future<MambaExecutionResult> _execute(List<String> arguments) =>
    createExecutor().fake().execute(['skill', 'discover', ...arguments]);

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
  String? messageToken,
}) {
  expect(
    result,
    isA<MambaFailureResult>()
        .having((value) => value.exitCode, 'exit code', isNonZero)
        .having((value) => value.message, 'message', isNotEmpty)
        .having((value) => value.output, 'output', isNull)
        .having((value) => value.error.phase, 'phase', phase)
        .having((value) => value.error.commandPath, 'command path', [
          'agent_resource',
          'skill',
          'discover',
        ]),
  );
  final failure = result as MambaFailureResult;
  if (messageToken != null) {
    expect(failure.message, contains(messageToken));
  }
  return failure;
}

List<Map<String, Object?>> _readOccurrences(MambaSuccessResult result) {
  final output = result.output!;
  final decoded = jsonDecode(output);
  if (decoded is! Map) {
    fail('discover output was not a JSON object: $output');
  }
  expect(decoded.keys.map((key) => key.toString()).toSet(), {'occurrences'});
  final occurrences = decoded['occurrences'];
  if (occurrences is! List) {
    fail('discover occurrences was not a JSON array: $output');
  }

  return occurrences.map((value) {
    if (value is! Map) {
      fail('discover occurrence was not a JSON object: $value');
    }
    final row = Map<String, Object?>.from(value);
    expect(row.keys.toSet(), {
      'path',
      'destination',
      'installationScope',
      'hasSkillFile',
    });
    expect(row['path'], isA<String>());
    expect(row['destination'], isA<String>());
    expect(row['installationScope'], 'project');
    expect(row['hasSkillFile'], isA<bool>());
    return row;
  }).toList();
}

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
      if (type == FileSystemEntityType.directory) {
        visit(Directory(entity.path));
      }
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
    group('skill', () {
      group('discover', () {
        test('accepts the required project option', () async {
          await _withProject((project) async {
            final result = _expectSuccess(
              await _execute(['--project', project.path]),
            );
            expect(_readOccurrences(result), isEmpty);
          });
        });

        test(
          'requires exactly one discovery root before command execution',
          () async {
            final result = _expectFailure(
              await _execute(const []),
              phase: MambaExecutionPhase.parse,
              messageToken: 'At least one selected option is required',
            );
            expect(result.error.commandPath, [
              'agent_resource',
              'skill',
              'discover',
            ]);
          },
        );

        test('requires a value for --project', () async {
          final result = _expectFailure(
            await _execute(const ['--project']),
            phase: MambaExecutionPhase.parse,
            messageToken: 'project',
          );
          expect(result.output, isNull);
        });

        test('supports an equals-form project option', () async {
          await _withProject((project) async {
            final result = _expectSuccess(
              await _execute(['--project=${project.path}']),
            );
            expect(_readOccurrences(result), isEmpty);
          });
        });

        test(
          'selected command help explains project-local discovery',
          () async {
            final result = _expectSuccess(await _execute(const ['--help']));
            expect(result.output, contains('discover'));
            expect(result.output, contains('--project'));
            expect(result.output, contains('project-local'));
            expect(result.output, isNot(contains('validate')));
            expect(result.output, isNot(contains('adopt')));
          },
        );

        test('rejects unknown options', () async {
          final result = _expectFailure(
            await _execute(const ['--unknown', 'value']),
            phase: MambaExecutionPhase.parse,
            messageToken: '--unknown',
          );
          expect(result.output, isNull);
        });

        test('rejects an extra positional argument', () async {
          await _withProject((project) async {
            final result = _expectFailure(
              await _execute(['--project', project.path, 'extra']),
              phase: MambaExecutionPhase.parse,
              messageToken: 'extra',
            );
            expect(result.error.commandPath, [
              'agent_resource',
              'skill',
              'discover',
            ]);
          });
        });

        test(
          'permission-denied project lookup fails instead of appearing empty',
          () async {
            if (Platform.isWindows) {
              markTestSkipped(
                'portable permission setup is unavailable on Windows',
              );
              return;
            }
            await _withProject((project) async {
              final changed = await Process.run('chmod', ['000', project.path]);
              if (changed.exitCode != 0) {
                markTestSkipped('chmod is unavailable');
                return;
              }
              try {
                try {
                  project.listSync();
                  markTestSkipped(
                    'the host did not enforce directory permissions',
                  );
                  return;
                } on FileSystemException {
                  // Permission denial is available for this regression check.
                }
                _expectFailure(
                  await _execute(['--project', project.path]),
                  phase: MambaExecutionPhase.run,
                  messageToken: null,
                );
              } finally {
                await Process.run('chmod', ['700', project.path]);
              }
            });
          },
        );

        test('fails when the project directory does not exist', () async {
          await _withProject((parentProject) async {
            final missing = p.join(parentProject.parent.path, 'missing');
            final result = _expectFailure(
              await _execute(['--project', missing]),
              phase: MambaExecutionPhase.run,
              messageToken: 'missing',
            );
            expect(result.output, isNull);
          });
        });

        test('fails when project resolves to a regular file', () async {
          await _withProject((project) async {
            final file = File(p.join(project.parent.path, 'project.txt'))
              ..writeAsStringSync('not a directory');
            final result = _expectFailure(
              await _execute(['--project', file.path]),
              phase: MambaExecutionPhase.run,
              messageToken: 'project',
            );
            expect(result.error.commandPath, [
              'agent_resource',
              'skill',
              'discover',
            ]);
          });
        });

        test(
          'fresh executors and repeated valid calls remain independent',
          () async {
            await _withProject((project) async {
              final first = _readOccurrences(
                _expectSuccess(await _execute(['--project', project.path])),
              );
              _candidate(project, 'shared', 'new-skill');
              final second = _readOccurrences(
                _expectSuccess(await _execute(['--project', project.path])),
              );
              final third = _readOccurrences(
                _expectSuccess(
                  await createExecutor().fake().execute([
                    'skill',
                    'discover',
                    '--project',
                    project.path,
                  ]),
                ),
              );
              expect(first, isEmpty);
              expect(second.length, 1);
              expect(third, equals(second));
            });
          },
        );

        test('enumerates all destinations in destination order', () async {
          await _withProject((project) async {
            _candidate(project, 'codex', 'zeta', createMarker: true);
            _candidate(project, 'shared', 'shared-skill');
            _candidate(project, 'claude', 'claude-skill', createMarker: true);
            final result = _readOccurrences(
              _expectSuccess(await _execute(['--project', project.path])),
            );

            expect(result, [
              _occurrence(
                project.path,
                'shared',
                'shared-skill',
                hasSkillFile: false,
              ),
              _occurrence(
                project.path,
                'claude',
                'claude-skill',
                hasSkillFile: true,
              ),
              _occurrence(project.path, 'codex', 'zeta', hasSkillFile: true),
            ]);
          });
        });

        test(
          'sorts candidate basenames lexicographically within each destination',
          () async {
            await _withProject((project) async {
              for (final name in ['zeta', 'Alpha', 'beta']) {
                _candidate(
                  project,
                  'shared',
                  name,
                  createMarker: name == 'beta',
                );
              }
              final result = _readOccurrences(
                _expectSuccess(await _execute(['--project', project.path])),
              );
              expect(
                result
                    .map((row) => p.basename(row['path']! as String))
                    .toList(),
                ['Alpha', 'beta', 'zeta'],
              );
              expect(result[1]['hasSkillFile'], isTrue);
            });
          },
        );

        test(
          'retains same-name candidates at different destinations',
          () async {
            await _withProject((project) async {
              for (final destination in _destinations.keys) {
                _candidate(project, destination, 'same-name');
              }
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--project', project.path])),
              );
              expect(rows, [
                _occurrence(
                  project.path,
                  'shared',
                  'same-name',
                  hasSkillFile: false,
                ),
                _occurrence(
                  project.path,
                  'claude',
                  'same-name',
                  hasSkillFile: false,
                ),
                _occurrence(
                  project.path,
                  'codex',
                  'same-name',
                  hasSkillFile: false,
                ),
              ]);
            });
          },
        );

        test('reports the exact four-field occurrence schema', () async {
          await _withProject((project) async {
            _candidate(project, 'shared', 'schema');
            final rows = _readOccurrences(
              _expectSuccess(await _execute(['--project', project.path])),
            );
            expect(rows.single.keys.toList()..sort(), [
              'destination',
              'hasSkillFile',
              'installationScope',
              'path',
            ]);
            expect(rows.single['destination'], 'shared');
            expect(rows.single['installationScope'], 'project');
            expect(rows.single['hasSkillFile'], isFalse);
          });
        });

        test('marks only a regular SKILL.md file as present', () async {
          await _withProject((project) async {
            final regular = _candidate(project, 'shared', 'regular');
            File(p.join(regular.path, 'SKILL.md'))
                .writeAsStringSync('{ malformed');
            final directoryMarker = _candidate(project, 'claude', 'directory');
            Directory(p.join(directoryMarker.path, 'SKILL.md')).createSync();
            _candidate(project, 'codex', 'absent');
            final rows = _readOccurrences(
              _expectSuccess(await _execute(['--project', project.path])),
            );
            expect(rows.map((row) => row['hasSkillFile']).toList(), [
              true,
              false,
              false,
            ]);
          });
        });

        test(
          'returns an empty object without creating known directories',
          () async {
            await _withProject((project) async {
              final before = _snapshot(project);
              final output = _expectSuccess(
                await _execute(['--project', project.path]),
              ).output!;
              expect(jsonDecode(output), {'occurrences': const <Object?>[]});
              expect(_snapshot(project), equals(before));
              for (final harness in _destinations.values) {
                expect(
                  Directory(p.join(project.path, harness)).existsSync(),
                  isFalse,
                );
              }
            });
          },
        );

        test(
          'missing destinations do not hide candidates in existing ones',
          () async {
            await _withProject((project) async {
              _candidate(project, 'claude', 'only-claude');
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--project', project.path])),
              );
              expect(rows, [
                _occurrence(
                  project.path,
                  'claude',
                  'only-claude',
                  hasSkillFile: false,
                ),
              ]);
            });
          },
        );

        test('ignores ordinary files among candidate entries', () async {
          await _withProject((project) async {
            final skills = _skillsDirectory(project, 'shared');
            File(p.join(skills.path, 'not-a-directory')).writeAsStringSync('x');
            _candidate(project, 'shared', 'real');
            final rows = _readOccurrences(
              _expectSuccess(await _execute(['--project', project.path])),
            );
            expect(rows, [
              _occurrence(project.path, 'shared', 'real', hasSkillFile: false),
            ]);
          });
        });

        test(
          'does not recurse below an immediate candidate directory',
          () async {
            await _withProject((project) async {
              final nested = Directory(
                p.join(
                  _skillsDirectory(project, 'shared').path,
                  'outer',
                  'nested',
                ),
              )..createSync(recursive: true);
              File(p.join(nested.path, 'SKILL.md'))
                  .writeAsStringSync('# nested');
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--project', project.path])),
              );
              expect(rows, [
                _occurrence(
                  project.path,
                  'shared',
                  'outer',
                  hasSkillFile: false,
                ),
              ]);
            });
          },
        );

        test('normalizes the explicit project path lexically', () async {
          await _withProject((project) async {
            _candidate(project, 'shared', 'normalized');
            final projectArgument = p.join(
              project.parent.path,
              '.',
              p.basename(project.path),
              '..',
              p.basename(project.path),
            );
            final rows = _readOccurrences(
              _expectSuccess(await _execute(['--project', projectArgument])),
            );
            expect(rows, [
              _occurrence(
                projectArgument,
                'shared',
                'normalized',
                hasSkillFile: false,
              ),
            ]);
          });
        });

        test('emits stable JSON for identical repeated reports', () async {
          await _withProject((project) async {
            _candidate(project, 'shared', 'stable');
            final first = _expectSuccess(
              await _execute(['--project', project.path]),
            ).output;
            final second = _expectSuccess(
              await _execute(['--project', project.path]),
            ).output;
            expect(jsonDecode(first!), equals(jsonDecode(second!)));
            expect(first, isNotEmpty);
            expect(second, isNotEmpty);
          });
        });

        test('does not write to the project or its parent', () async {
          await _withProject((project) async {
            _candidate(project, 'shared', 'untouched');
            final beforeProject = _snapshot(project);
            final beforeParent = _snapshot(project.parent);
            _readOccurrences(
              _expectSuccess(await _execute(['--project', project.path])),
            );
            expect(_snapshot(project), equals(beforeProject));
            expect(_snapshot(project.parent), equals(beforeParent));
          });
        });

        test(
          'fails rather than treating a configured skills path as a file',
          () async {
            await _withProject((project) async {
              final agents = Directory(p.join(project.path, '.agents'))
                ..createSync(recursive: true);
              File(p.join(agents.path, 'skills'))
                  .writeAsStringSync('wrong kind');
              final result = _expectFailure(
                await _execute(['--project', project.path]),
                phase: MambaExecutionPhase.run,
                messageToken: 'skills',
              );
              expect(result.output, isNull);
            });
          },
        );

        test(
          'fails rather than treating an intermediate destination as a file',
          () async {
            await _withProject((project) async {
              File(p.join(project.path, '.agents'))
                  .writeAsStringSync('wrong kind');
              final result = _expectFailure(
                await _execute(['--project', project.path]),
                phase: MambaExecutionPhase.run,
                messageToken: '.agents',
              );
              expect(result.error.commandPath, [
                'agent_resource',
                'skill',
                'discover',
              ]);
            });
          },
        );

        test('ignores a symlink candidate without following it', () async {
          await _withProject((project) async {
            final target = await Directory.systemTemp.createTemp(
              'discover-link-target-',
            );
            try {
              _candidate(project, 'shared', 'real');
              _candidate(target, 'shared', 'linked-target', createMarker: true);
              final link = p.join(
                _skillsDirectory(project, 'shared').path,
                'linked',
              );
              if (!await _tryCreateLink(
                link,
                p.join(target.path, '.agents', 'skills', 'linked-target'),
              )) {
                markTestSkipped('directory symlink creation is unavailable');
                return;
              }
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--project', project.path])),
              );
              expect(rows, [
                _occurrence(
                  project.path,
                  'shared',
                  'real',
                  hasSkillFile: false,
                ),
              ]);
            } finally {
              await target.delete(recursive: true);
            }
          });
        });

        test('ignores a symlinked configured skills directory', () async {
          await _withProject((project) async {
            final target = await Directory.systemTemp.createTemp(
              'discover-skills-target-',
            );
            try {
              final targetSkills = Directory(p.join(target.path, 'skills'))
                ..createSync();
              Directory(p.join(targetSkills.path, 'hidden'))
                  .createSync(recursive: true);
              File(p.join(targetSkills.path, 'hidden', 'SKILL.md'))
                  .writeAsStringSync('# hidden');
              final agents = Directory(p.join(project.path, '.agents'));
              agents.createSync();
              final link = p.join(agents.path, 'skills');
              if (!await _tryCreateLink(link, targetSkills.path)) {
                markTestSkipped('directory symlink creation is unavailable');
                return;
              }
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--project', project.path])),
              );
              expect(rows, isEmpty);
            } finally {
              await target.delete(recursive: true);
            }
          });
        });

        test(
          'ignores a symlinked intermediate destination directory',
          () async {
            await _withProject((project) async {
              final target = await Directory.systemTemp.createTemp(
                'discover-destination-target-',
              );
              try {
                final skills = _skillsDirectory(target, 'shared');
                _candidate(target, 'shared', 'hidden', createMarker: true);
                final link = p.join(project.path, '.agents');
                if (!await _tryCreateLink(link, target.path)) {
                  markTestSkipped('directory symlink creation is unavailable');
                  return;
                }
                final rows = _readOccurrences(
                  _expectSuccess(await _execute(['--project', project.path])),
                );
                expect(rows, isEmpty);
                expect(skills.existsSync(), isTrue);
              } finally {
                await target.delete(recursive: true);
              }
            });
          },
        );

        test('does not follow a symlinked SKILL.md marker', () async {
          await _withProject((project) async {
            final target = File(p.join(project.parent.path, 'marker-target.md'))
              ..writeAsStringSync('# target');
            final candidate = _candidate(project, 'shared', 'linked-marker');
            final marker = p.join(candidate.path, 'SKILL.md');
            if (!await _tryCreateLink(marker, target.path)) {
              markTestSkipped('file symlink creation is unavailable');
              return;
            }
            final rows = _readOccurrences(
              _expectSuccess(await _execute(['--project', project.path])),
            );
            expect(rows, [
              _occurrence(
                project.path,
                'shared',
                'linked-marker',
                hasSkillFile: false,
              ),
            ]);
            expect(target.readAsStringSync(), '# target');
          });
        });

        test(
          'a link cycle inside a candidate does not recurse or hang',
          () async {
            await _withProject((project) async {
              final candidate = _candidate(project, 'shared', 'cycle');
              final loop = p.join(candidate.path, 'loop');
              if (!await _tryCreateLink(loop, candidate.path)) {
                markTestSkipped('directory symlink creation is unavailable');
                return;
              }
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--project', project.path])),
              );
              expect(rows, [
                _occurrence(
                  project.path,
                  'shared',
                  'cycle',
                  hasSkillFile: false,
                ),
              ]);
            });
          },
        );

        test(
          'allows the explicit project root itself to be a symlink',
          () async {
            final parent = await Directory.systemTemp.createTemp(
              'discover-root-link-',
            );
            final target = Directory(p.join(parent.path, 'target'))
              ..createSync(recursive: true);
            final alias = p.join(parent.path, 'alias');
            try {
              _candidate(target, 'shared', 'through-root', createMarker: true);
              if (!await _tryCreateLink(alias, target.path)) {
                markTestSkipped('directory symlink creation is unavailable');
                return;
              }
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--project', alias])),
              );
              expect(rows, [
                _occurrence(
                  alias,
                  'shared',
                  'through-root',
                  hasSkillFile: true,
                ),
              ]);
            } finally {
              await parent.delete(recursive: true);
            }
          },
        );

        test('returns no partial output after an IO failure', () async {
          await _withProject((project) async {
            _candidate(project, 'shared', 'before-failure');
            File(p.join(project.path, '.claude')).writeAsStringSync('bad path');
            final before = _snapshot(project);
            final result = _expectFailure(
              await _execute(['--project', project.path]),
              phase: MambaExecutionPhase.run,
              messageToken: '.claude',
            );
            expect(result.output, isNull);
            expect(_snapshot(project), equals(before));
          });
        });

        test(
          'a failed scan followed by a valid scan has no stale failure state',
          () async {
            await _withProject((project) async {
              final adapter = createExecutor().fake();
              File(p.join(project.path, '.agents'))
                  .writeAsStringSync('bad path');
              final failed = _expectFailure(
                await adapter.execute([
                  'skill',
                  'discover',
                  '--project',
                  project.path,
                ]),
                phase: MambaExecutionPhase.run,
                messageToken: '.agents',
              );
              expect(failed.output, isNull);
              File(p.join(project.path, '.agents')).deleteSync();
              _candidate(project, 'shared', 'after-failure');
              final succeeded = _readOccurrences(
                _expectSuccess(
                  await adapter.execute([
                    'skill',
                    'discover',
                    '--project',
                    project.path,
                  ]),
                ),
              );
              expect(succeeded, [
                _occurrence(
                  project.path,
                  'shared',
                  'after-failure',
                  hasSkillFile: false,
                ),
              ]);
            });
          },
        );

        test(
          'does not inspect or alter unrelated neighboring directories',
          () async {
            await _withProject((project) async {
              final outside = Directory(p.join(project.parent.path, 'outside'))
                ..createSync();
              File(p.join(outside.path, 'sentinel.txt'))
                  .writeAsStringSync('keep');
              final before = _snapshot(project.parent);
              _readOccurrences(
                _expectSuccess(await _execute(['--project', project.path])),
              );
              expect(_snapshot(project.parent), equals(before));
              expect(
                File(p.join(outside.path, 'sentinel.txt')).readAsStringSync(),
                'keep',
              );
            });
          },
        );

        test(
          'production discover smoke matches the fake JSON report',
          () async {
            await _withProject((project) async {
              _candidate(
                project,
                'shared',
                'process-skill',
                createMarker: true,
              );
              final fake = _readOccurrences(
                _expectSuccess(await _execute(['--project', project.path])),
              );
              final process = await _runProduction(project.parent, [
                'skill',
                'discover',
                '--project',
                project.path,
              ]);
              expect(process.exitCode, 0);
              expect(process.stderr, isEmpty);
              expect(jsonDecode(process.stdout), {'occurrences': fake});
            });
          },
        );

        test('production invalid project fails without partial JSON', () async {
          await _withProject((project) async {
            final missing = p.join(project.parent.path, 'missing-project');
            final process = await _runProduction(project.parent, [
              'skill',
              'discover',
              '--project',
              missing,
            ]);
            expect(process.exitCode, isNot(0));
            expect(process.stdout, isEmpty);
            expect(process.stderr, contains('Project'));
            expect(process.stderr, contains('missing-project'));
          });
        });
      });
    });
  });
}
