import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/process_test_support.dart';

const _destinations = <String, String>{
  'shared': '.agents',
  'claude': '.claude',
  'codex': '.codex',
};

late final String _entrypoint;
late final String _packageConfig;

Future<T> _withRoots<T>(
  Future<T> Function(Directory home, Directory project) body,
) async {
  final parent = await Directory.systemTemp.createTemp(
    'agent-resource-discover-user-',
  );
  final home = Directory(p.join(parent.path, 'home'))..createSync();
  final project = Directory(p.join(parent.path, 'project'))..createSync();
  try {
    return await body(home, project);
  } finally {
    await parent.delete(recursive: true);
  }
}

Directory _skillsDirectory(Directory root, String destination) =>
    Directory(p.join(root.path, _destinations[destination]!, 'skills'))
      ..createSync(recursive: true);

Directory _candidate(
  Directory root,
  String destination,
  String name, {
  bool createMarker = false,
}) {
  final directory = Directory(
    p.join(_skillsDirectory(root, destination).path, name),
  )..createSync(recursive: true);
  if (createMarker) {
    File(p.join(directory.path, 'SKILL.md')).writeAsStringSync('{ malformed');
  }
  return directory;
}

String _candidatePath(String rootArgument, String destination, String name) =>
    p.normalize(
      p.absolute(
        p.join(rootArgument, _destinations[destination]!, 'skills', name),
      ),
    );

Map<String, Object?> _occurrence(
  String rootArgument,
  String destination,
  String name, {
  required String installationScope,
  required bool hasSkillFile,
}) => <String, Object?>{
  'path': _candidatePath(rootArgument, destination, name),
  'destination': destination,
  'installationScope': installationScope,
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

String _expectDiscoverHelp(MambaSuccessResult result) {
  final output = result.output;
  expect(output, isNotNull);
  expect(output, contains('--project'));
  expect(output, contains('--home'));
  final lower = output!.toLowerCase();
  expect(lower, contains('exactly one'));
  expect(lower, contains('.agents/skills'));
  expect(lower, contains('.claude/skills'));
  expect(lower, contains('.codex/skills'));
  expect(lower, contains('installationscope'));
  expect(lower, contains('user'));
  expect(lower, contains('project'));
  expect(lower, contains('ordinary files'));
  expect(lower, contains('linked scan'));
  expect(lower, contains('candidate directories'));
  expect(lower, contains('regular file'));
  expect(lower, contains('not a link'));
  expect(lower, contains('read-only'));
  return output;
}

MambaFailureResult _expectFailure(
  MambaExecutionResult result, {
  required MambaExecutionPhase phase,
  String? message,
  String? messageToken,
}) {
  expect(
    result,
    isA<MambaFailureResult>()
        .having((value) => value.exitCode, 'exit code', isNonZero)
        .having((value) => value.output, 'output', isNull)
        .having((value) => value.error.phase, 'phase', phase)
        .having((value) => value.error.commandPath, 'command path', [
          'agent_resource',
          'skill',
          'discover',
        ]),
  );
  final failure = result as MambaFailureResult;
  if (message != null) expect(failure.message, message);
  if (messageToken != null) expect(failure.message, contains(messageToken));
  return failure;
}

List<Map<String, Object?>> _readOccurrences(
  MambaSuccessResult result, {
  required String installationScope,
}) {
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
    expect(row['installationScope'], installationScope);
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
  List<String> arguments, {
  Map<String, String>? environment,
}) => runDartScript(
  script: _entrypoint,
  packageConfig: _packageConfig,
  arguments: arguments,
  workingDirectory: workingDirectory,
  environment: environment ?? isolatedEnvironment(workingDirectory),
);

void main() {
  final projectRoot = _findProjectRoot();
  _entrypoint = p.join(projectRoot, 'bin', 'agent_resource.dart');
  _packageConfig = p.join(projectRoot, '.dart_tool', 'package_config.json');

  group('agent_resource', () {
    group('skill', () {
      group('discover', () {
        test('root and discover help advertise both explicit roots', () async {
          final rootHelp = _expectSuccess(
            await createExecutor().fake().execute(const ['--help']),
          ).output!;
          expect(rootHelp, contains('skill'));
          expect(rootHelp, isNot(contains('  discover')));
          expect(rootHelp, isNot(contains('  inspect')));

          final skillHelp = _expectSuccess(
            await createExecutor().fake().execute(const ['skill', '--help']),
          ).output!;
          expect(skillHelp, contains('discover'));
          expect(skillHelp, contains('inspect'));
          expect(skillHelp, contains('validate'));

          _expectDiscoverHelp(_expectSuccess(await _execute(const ['--help'])));
        });

        test('help succeeds without selecting a root', () async {
          _expectDiscoverHelp(_expectSuccess(await _execute(const ['--help'])));
        });

        test(
          'requires exactly one selected root when neither is supplied',
          () async {
            final result = _expectFailure(
              await _execute(const []),
              phase: MambaExecutionPhase.parse,
              message:
                  'At least one selected option is required: --project, --home',
            );
            expect(result.message, contains('--project'));
            expect(result.message, contains('--home'));
          },
        );

        test(
          'rejects project followed by home with exactly-one wording',
          () async {
            await _withRoots((home, project) async {
              _candidate(home, 'shared', 'home-sentinel');
              _candidate(project, 'shared', 'project-sentinel');
              final beforeHome = _snapshot(home);
              final beforeProject = _snapshot(project);
              final result = _expectFailure(
                await _execute([
                  '--project',
                  project.path,
                  '--home',
                  home.path,
                ]),
                phase: MambaExecutionPhase.parse,
                message: 'Selected options accept only one option.',
              );
              expect(result.output, isNull);
              expect(_snapshot(home), beforeHome);
              expect(_snapshot(project), beforeProject);
            });
          },
        );

        test(
          'rejects home followed by project with the same parser result',
          () async {
            await _withRoots((home, project) async {
              _candidate(home, 'claude', 'home-sentinel');
              _candidate(project, 'claude', 'project-sentinel');
              final beforeHome = _snapshot(home);
              final beforeProject = _snapshot(project);
              final result = _expectFailure(
                await _execute([
                  '--home',
                  home.path,
                  '--project',
                  project.path,
                ]),
                phase: MambaExecutionPhase.parse,
                message: 'Selected options accept only one option.',
              );
              expect(result.error.commandPath, [
                'agent_resource',
                'skill',
                'discover',
              ]);
              expect(_snapshot(home), beforeHome);
              expect(_snapshot(project), beforeProject);
            });
          },
        );

        test('rejects a home option without a value', () async {
          final result = _expectFailure(
            await _execute(const ['--home']),
            phase: MambaExecutionPhase.parse,
            messageToken: 'home',
          );
          expect(result.output, isNull);
        });

        test('rejects a blank home value before filesystem access', () async {
          final result = _expectFailure(
            await _execute(const ['--home', '   ']),
            phase: MambaExecutionPhase.run,
            messageToken: 'home',
          );
          expect(result.message.toLowerCase(), contains('blank'));
        });

        test(
          'rejects unknown options and unexpected positionals in home mode',
          () async {
            final unknown = _expectFailure(
              await _execute(const ['--home', 'somewhere', '--unknown']),
              phase: MambaExecutionPhase.parse,
              messageToken: '--unknown',
            );
            expect(unknown.output, isNull);

            await _withRoots((home, project) async {
              final positional = _expectFailure(
                await _execute(['--home', home.path, 'extra']),
                phase: MambaExecutionPhase.parse,
                messageToken: 'extra',
              );
              expect(positional.error.commandPath, [
                'agent_resource',
                'skill',
                'discover',
              ]);
              expect(project.existsSync(), isTrue);
            });
          },
        );

        test('rejects missing and regular-file home roots', () async {
          await _withRoots((home, project) async {
            final missing = p.join(home.parent.path, 'missing-home');
            final missingResult = _expectFailure(
              await _execute(['--home', missing]),
              phase: MambaExecutionPhase.run,
              messageToken: 'home',
            );
            expect(missingResult.message, contains('missing-home'));

            final file = File(p.join(home.parent.path, 'home.txt'))
              ..writeAsStringSync('not a directory');
            final fileResult = _expectFailure(
              await _execute(['--home', file.path]),
              phase: MambaExecutionPhase.run,
              messageToken: 'home',
            );
            expect(fileResult.output, isNull);
            expect(project.existsSync(), isTrue);
          });
        });

        test(
          'accepts an empty explicit home with no implicit environment scan',
          () async {
            await _withRoots((home, project) async {
              final result = _expectSuccess(
                await _execute(['--home', home.path]),
              );
              expect(
                _readOccurrences(result, installationScope: 'user'),
                isEmpty,
              );
              expect(project.listSync(followLinks: false), isEmpty);
            });
          },
        );

        test(
          'preserves explicit project selection and project scope',
          () async {
            await _withRoots((home, project) async {
              _candidate(project, 'shared', 'project-only');
              final result = _expectSuccess(
                await _execute(['--project', project.path]),
              );
              expect(_readOccurrences(result, installationScope: 'project'), [
                _occurrence(
                  project.path,
                  'shared',
                  'project-only',
                  installationScope: 'project',
                  hasSkillFile: false,
                ),
              ]);
              expect(home.listSync(followLinks: false), isEmpty);
            });
          },
        );

        test(
          'reports all user destinations with user scope and exact schema',
          () async {
            await _withRoots((home, project) async {
              _candidate(home, 'codex', 'codex-skill', createMarker: true);
              _candidate(home, 'shared', 'shared-skill');
              _candidate(home, 'claude', 'claude-skill', createMarker: true);
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--home', home.path])),
                installationScope: 'user',
              );
              expect(rows, [
                _occurrence(
                  home.path,
                  'shared',
                  'shared-skill',
                  installationScope: 'user',
                  hasSkillFile: false,
                ),
                _occurrence(
                  home.path,
                  'claude',
                  'claude-skill',
                  installationScope: 'user',
                  hasSkillFile: true,
                ),
                _occurrence(
                  home.path,
                  'codex',
                  'codex-skill',
                  installationScope: 'user',
                  hasSkillFile: true,
                ),
              ]);
              expect(project.existsSync(), isTrue);
            });
          },
        );

        test(
          'normalizes dot segments and reports absolute candidate paths',
          () async {
            await _withRoots((home, project) async {
              _candidate(home, 'shared', 'normalized');
              final relative = p.relative(
                home.path,
                from: Directory.current.absolute.path,
              );
              final argument = p.join('.', relative);
              expect(p.isAbsolute(argument), isFalse);
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--home', argument])),
                installationScope: 'user',
              );
              expect(rows, [
                _occurrence(
                  argument,
                  'shared',
                  'normalized',
                  installationScope: 'user',
                  hasSkillFile: false,
                ),
              ]);
              expect(p.isAbsolute(rows.single['path']! as String), isTrue);
            });
          },
        );

        test(
          'uses marker presence only and ignores ordinary candidate files',
          () async {
            await _withRoots((home, project) async {
              final marked = _candidate(
                home,
                'shared',
                'marked',
                createMarker: true,
              );
              final unmarked = _candidate(home, 'claude', 'unmarked');
              Directory(p.join(unmarked.path, 'SKILL.md')).createSync();
              final skills = _skillsDirectory(home, 'codex');
              File(p.join(skills.path, 'ordinary.txt'))
                  .writeAsStringSync('ignore');
              _candidate(home, 'codex', 'candidate');
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--home', home.path])),
                installationScope: 'user',
              );
              expect(rows, [
                _occurrence(
                  home.path,
                  'shared',
                  'marked',
                  installationScope: 'user',
                  hasSkillFile: true,
                ),
                _occurrence(
                  home.path,
                  'claude',
                  'unmarked',
                  installationScope: 'user',
                  hasSkillFile: false,
                ),
                _occurrence(
                  home.path,
                  'codex',
                  'candidate',
                  installationScope: 'user',
                  hasSkillFile: false,
                ),
              ]);
              expect(
                File(p.join(marked.path, 'SKILL.md')).readAsStringSync(),
                '{ malformed',
              );
              expect(project.existsSync(), isTrue);
            });
          },
        );

        test(
          'retains same names, destination order, and basename lexical order',
          () async {
            await _withRoots((home, project) async {
              for (final entry in _destinations.keys) {
                for (final name in ['zeta', 'Alpha', 'same']) {
                  _candidate(home, entry, name);
                }
              }
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--home', home.path])),
                installationScope: 'user',
              );
              expect(rows, [
                for (final destination in _destinations.keys)
                  for (final name in ['Alpha', 'same', 'zeta'])
                    _occurrence(
                      home.path,
                      destination,
                      name,
                      installationScope: 'user',
                      hasSkillFile: false,
                    ),
              ]);
              expect(project.existsSync(), isTrue);
            });
          },
        );

        test(
          'does not recurse into nested skill-looking directories',
          () async {
            await _withRoots((home, project) async {
              final candidate = _candidate(home, 'shared', 'outer');
              final nested = Directory(p.join(candidate.path, 'nested', 'deep'))
                ..createSync(recursive: true);
              File(p.join(nested.path, 'SKILL.md'))
                  .writeAsStringSync('# nested');
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--home', home.path])),
                installationScope: 'user',
              );
              expect(rows, [
                _occurrence(
                  home.path,
                  'shared',
                  'outer',
                  installationScope: 'user',
                  hasSkillFile: false,
                ),
              ]);
              expect(project.existsSync(), isTrue);
            });
          },
        );

        test(
          'equivalent project and home fixtures differ only by scope',
          () async {
            await _withRoots((home, project) async {
              for (final root in [home, project]) {
                _candidate(root, 'shared', 'same', createMarker: true);
                _candidate(root, 'claude', 'missing');
              }
              final homeRows = _readOccurrences(
                _expectSuccess(await _execute(['--home', home.path])),
                installationScope: 'user',
              );
              final projectRows = _readOccurrences(
                _expectSuccess(await _execute(['--project', project.path])),
                installationScope: 'project',
              );
              expect(homeRows, [
                _occurrence(
                  home.path,
                  'shared',
                  'same',
                  installationScope: 'user',
                  hasSkillFile: true,
                ),
                _occurrence(
                  home.path,
                  'claude',
                  'missing',
                  installationScope: 'user',
                  hasSkillFile: false,
                ),
              ]);
              expect(projectRows, [
                _occurrence(
                  project.path,
                  'shared',
                  'same',
                  installationScope: 'project',
                  hasSkillFile: true,
                ),
                _occurrence(
                  project.path,
                  'claude',
                  'missing',
                  installationScope: 'project',
                  hasSkillFile: false,
                ),
              ]);
            });
          },
        );

        test('missing destinations stay empty and are not created', () async {
          await _withRoots((home, project) async {
            final before = _snapshot(home);
            final result = _expectSuccess(
              await _execute(['--home', home.path]),
            );
            expect(
              _readOccurrences(result, installationScope: 'user'),
              isEmpty,
            );
            expect(_snapshot(home), before);
            for (final harness in _destinations.values) {
              expect(
                Directory(p.join(home.path, harness)).existsSync(),
                isFalse,
              );
            }
            expect(project.existsSync(), isTrue);
          });
        });

        test('file layouts fail without partial user JSON', () async {
          await _withRoots((home, project) async {
            _candidate(home, 'shared', 'before-failure');
            File(p.join(home.path, '.claude')).writeAsStringSync('bad harness');
            final before = _snapshot(home);
            final result = _expectFailure(
              await _execute(['--home', home.path]),
              phase: MambaExecutionPhase.run,
              messageToken: '.claude',
            );
            expect(result.output, isNull);
            expect(_snapshot(home), before);
            expect(project.existsSync(), isTrue);
          });
        });

        test(
          'a file at skills position fails without partial user JSON',
          () async {
            await _withRoots((home, project) async {
              final agents = Directory(p.join(home.path, '.agents'))
                ..createSync();
              File(p.join(agents.path, 'skills'))
                  .writeAsStringSync('bad skills');
              final result = _expectFailure(
                await _execute(['--home', home.path]),
                phase: MambaExecutionPhase.run,
                messageToken: 'skills',
              );
              expect(result.output, isNull);
              expect(project.existsSync(), isTrue);
            });
          },
        );

        test(
          'skips linked harness, skills, candidate, and marker entries',
          () async {
            await _withRoots((home, project) async {
              final external = Directory(p.join(home.parent.path, 'external'))
                ..createSync();
              try {
                _candidate(external, 'shared', 'outside', createMarker: true);
                final harnessLink = p.join(home.path, '.agents');
                if (!await _tryCreateLink(harnessLink, external.path)) {
                  markTestSkipped('directory symlink creation is unavailable');
                  return;
                }
                final beforeHome = _snapshot(home);
                final beforeExternal = _snapshot(external);
                expect(
                  _readOccurrences(
                    _expectSuccess(await _execute(['--home', home.path])),
                    installationScope: 'user',
                  ),
                  isEmpty,
                );
                expect(_snapshot(home), beforeHome);
                expect(_snapshot(external), beforeExternal);
              } finally {
                await external.delete(recursive: true);
              }

              final skills = _skillsDirectory(home, 'claude');
              final targetSkills = _skillsDirectory(project, 'shared');
              _candidate(
                project,
                'shared',
                'linked-skills',
                createMarker: true,
              );
              final skillsLink = p.join(home.path, '.claude', 'skills');
              if (!await _tryCreateLink(skillsLink, targetSkills.path)) {
                markTestSkipped('directory symlink creation is unavailable');
                return;
              }
              expect(skills.existsSync(), isFalse);
              final beforeHomeAfterSkills = _snapshot(home);
              final beforeProjectAfterSkills = _snapshot(project);
              expect(
                _readOccurrences(
                  _expectSuccess(await _execute(['--home', home.path])),
                  installationScope: 'user',
                ),
                isEmpty,
              );
              expect(_snapshot(home), beforeHomeAfterSkills);
              expect(_snapshot(project), beforeProjectAfterSkills);

              _candidate(home, 'codex', 'real');
              final target = _candidate(
                project,
                'codex',
                'target',
                createMarker: true,
              );
              final candidateLink = p.join(
                _skillsDirectory(home, 'codex').path,
                'linked',
              );
              if (!await _tryCreateLink(candidateLink, target.path)) {
                markTestSkipped('directory symlink creation is unavailable');
                return;
              }
              final markerTarget = File(
                p.join(project.parent.path, 'marker.md'),
              )..writeAsStringSync('# marker');
              final marker = p.join(
                _candidate(home, 'codex', 'linked-marker').path,
                'SKILL.md',
              );
              if (!await _tryCreateLink(marker, markerTarget.path)) {
                markTestSkipped('file symlink creation is unavailable');
                return;
              }
              final beforeHomeAfterMarker = _snapshot(home);
              final beforeProjectAfterMarker = _snapshot(project);
              final beforeMarkerTarget = markerTarget.readAsStringSync();
              final rows = _readOccurrences(
                _expectSuccess(await _execute(['--home', home.path])),
                installationScope: 'user',
              );
              expect(rows, [
                _occurrence(
                  home.path,
                  'codex',
                  'linked-marker',
                  installationScope: 'user',
                  hasSkillFile: false,
                ),
                _occurrence(
                  home.path,
                  'codex',
                  'real',
                  installationScope: 'user',
                  hasSkillFile: false,
                ),
              ]);
              expect(_snapshot(home), beforeHomeAfterMarker);
              expect(_snapshot(project), beforeProjectAfterMarker);
              expect(markerTarget.readAsStringSync(), beforeMarkerTarget);
            });
          },
        );

        test(
          'preserves selected and external sentinels after success and failure',
          () async {
            await _withRoots((home, project) async {
              final external = Directory(p.join(home.parent.path, 'external'))
                ..createSync();
              final sentinel = File(p.join(external.path, 'sentinel.txt'))
                ..writeAsStringSync('keep');
              _candidate(home, 'shared', 'safe');
              final beforeHome = _snapshot(home);
              final beforeParent = _snapshot(home.parent);
              expect(
                _readOccurrences(
                  _expectSuccess(await _execute(['--home', home.path])),
                  installationScope: 'user',
                ),
                [
                  _occurrence(
                    home.path,
                    'shared',
                    'safe',
                    installationScope: 'user',
                    hasSkillFile: false,
                  ),
                ],
              );
              expect(_snapshot(home), beforeHome);
              expect(_snapshot(home.parent), beforeParent);
              expect(sentinel.readAsStringSync(), 'keep');

              final broken = Directory(p.join(home.parent.path, 'broken'))
                ..createSync();
              _candidate(broken, 'claude', 'before-failure');
              File(p.join(broken.path, '.agents'))
                  .writeAsStringSync('bad layout');
              final beforeBroken = _snapshot(broken);
              final failed = _expectFailure(
                await _execute(['--home', broken.path]),
                phase: MambaExecutionPhase.run,
                messageToken: '.agents',
              );
              expect(failed.output, isNull);
              expect(_snapshot(broken), beforeBroken);
              expect(sentinel.readAsStringSync(), 'keep');
              expect(project.existsSync(), isTrue);
            });
          },
        );

        test('reuses one adapter without stale scope or occurrences', () async {
          await _withRoots((home, project) async {
            _candidate(home, 'shared', 'home-first');
            _candidate(project, 'shared', 'project-only');
            final adapter = createExecutor().fake();
            final homeFirst = _readOccurrences(
              _expectSuccess(
                await adapter.execute([
                  'skill',
                  'discover',
                  '--home',
                  home.path,
                ]),
              ),
              installationScope: 'user',
            );
            final projectRows = _readOccurrences(
              _expectSuccess(
                await adapter.execute([
                  'skill',
                  'discover',
                  '--project',
                  project.path,
                ]),
              ),
              installationScope: 'project',
            );
            final homeAgain = _readOccurrences(
              _expectSuccess(
                await adapter.execute([
                  'skill',
                  'discover',
                  '--home',
                  home.path,
                ]),
              ),
              installationScope: 'user',
            );
            expect(homeFirst, [
              _occurrence(
                home.path,
                'shared',
                'home-first',
                installationScope: 'user',
                hasSkillFile: false,
              ),
            ]);
            expect(homeAgain, homeFirst);
            expect(projectRows, [
              _occurrence(
                project.path,
                'shared',
                'project-only',
                installationScope: 'project',
                hasSkillFile: false,
              ),
            ]);
          });
        });

        test('explicit home wins over isolated HOME and USERPROFILE', () async {
          await _withRoots((home, project) async {
            final sentinel = Directory(
              p.join(home.parent.path, 'environment-home'),
            )..createSync();
            _candidate(home, 'shared', 'explicit', createMarker: true);
            _candidate(
              sentinel,
              'shared',
              'environment-sentinel',
              createMarker: true,
            );
            final environment = isolatedEnvironment(project.parent);
            environment['HOME'] = sentinel.path;
            environment['USERPROFILE'] = sentinel.path;
            final fake = _readOccurrences(
              _expectSuccess(await _execute(['--home', home.path])),
              installationScope: 'user',
            );
            expect(fake, [
              _occurrence(
                home.path,
                'shared',
                'explicit',
                installationScope: 'user',
                hasSkillFile: true,
              ),
            ]);
            final process = await _runProduction(project.parent, [
              'skill',
              'discover',
              '--home',
              home.path,
            ], environment: environment);
            expect(process.exitCode, 0);
            expect(process.stderr, isEmpty);
            expect(jsonDecode(process.stdout), {'occurrences': fake});
            expect(process.stdout, isNot(contains('environment-sentinel')));
          });
        });

        test('production home discovery matches fake JSON delivery', () async {
          await _withRoots((home, project) async {
            _candidate(home, 'claude', 'process-home', createMarker: true);
            final fake = _readOccurrences(
              _expectSuccess(await _execute(['--home', home.path])),
              installationScope: 'user',
            );
            expect(fake, [
              _occurrence(
                home.path,
                'claude',
                'process-home',
                installationScope: 'user',
                hasSkillFile: true,
              ),
            ]);
            final process = await _runProduction(project.parent, [
              'skill',
              'discover',
              '--home',
              home.path,
            ]);
            expect(process.exitCode, 0);
            expect(process.stderr, isEmpty);
            expect(jsonDecode(process.stdout), {'occurrences': fake});
          });
        });

        test('production invalid root selection has no partial JSON', () async {
          await _withRoots((home, project) async {
            final process = await _runProduction(project.parent, [
              'skill',
              'discover',
              '--project',
              project.path,
              '--home',
              home.path,
            ]);
            expect(process.exitCode, isNot(0));
            expect(process.stdout, isEmpty);
            expect(process.stderr, contains('only one'));
            expect(process.stderr, isNot(contains('{"occurrences"')));
          });
        });
      });
    });
  });
}
