import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/process_test_support.dart';

late final String _entrypoint;
late final String _packageConfig;

typedef _Sandbox = ({
  Directory root,
  Directory project,
  Directory work,
  Directory home,
});

Future<T> _withSandbox<T>(Future<T> Function(_Sandbox) body) async {
  final root = await Directory.systemTemp.createTemp('agent-resource-list-');
  final sandbox = (
    root: root,
    project: Directory(p.join(root.path, 'project')),
    work: Directory(p.join(root.path, 'project', 'work')),
    home: Directory(p.join(root.path, 'home')),
  );
  sandbox.project.createSync();
  sandbox.work.createSync();
  sandbox.home.createSync();
  try {
    return await body(sandbox);
  } finally {
    await root.delete(recursive: true);
  }
}

File _write(Directory sandbox, String relative, String content) {
  final file = File(p.join(sandbox.path, relative));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  return file;
}

bool _tryLink(Link link, String target, {bool directory = false}) {
  try {
    link.createSync(target);
    return true;
  } on FileSystemException {
    // Windows directory junctions have the same no-follow contract and do not
    // need the file-symlink privilege. Keep file-link skips explicit.
    if (directory && Platform.isWindows) {
      final result = Process.runSync('cmd', [
        '/c',
        'mklink',
        '/J',
        link.path,
        target,
      ]);
      return result.exitCode == 0;
    }
    return false;
  }
}

String _claude([String name = 'reviewer', String extra = '']) =>
    '---\nname: $name\ndescription: Reviews.\n$extra---\nPRIVATE-BODY\n';

String _codex([String name = 'reviewer']) =>
    'name = "$name"\ndescription = "Reviews."\n'
    'developer_instructions = "PRIVATE-CODEX-BODY"\n';

String _pi([String name = 'worker']) =>
    '---\nname: $name\ndescription: Works.\nmodel: kimi-coding/k3\n'
    'tools: read, grep, find, ls\n---\nPRIVATE-PI-BODY\n';

List<String> _projectArgs(_Sandbox sandbox) => [
  '--cwd',
  '${sandbox.work.path}${Platform.pathSeparator}',
  '--project-root',
  '${sandbox.project.path}${Platform.pathSeparator}',
];

Future<MambaExecutionResult> _execute(List<String> arguments) =>
    createExecutor().fake().execute(['agent', 'list', ...arguments]);

MambaSuccessResult _expectSuccess(MambaExecutionResult result) {
  expect(
    result,
    isA<MambaSuccessResult>()
        .having((value) => value.exitCode, 'exit code', 0)
        .having((value) => value.output, 'output', isNotNull),
    reason: result is MambaFailureResult ? result.message : null,
  );
  return result as MambaSuccessResult;
}

MambaFailureResult _expectFailure(
  MambaExecutionResult result, {
  required int exitCode,
  MambaExecutionPhase phase = MambaExecutionPhase.run,
}) {
  expect(
    result,
    isA<MambaFailureResult>()
        .having((value) => value.exitCode, 'exit code', exitCode)
        .having((value) => value.message, 'message', isNotEmpty)
        .having((value) => value.output, 'output', isNull)
        .having((value) => value.error.phase, 'phase', phase)
        .having((value) => value.error.commandPath, 'command path', [
          'agent_resource',
          'agent',
          'list',
        ]),
  );
  return result as MambaFailureResult;
}

Map<String, Object?> _report(MambaExecutionResult result) {
  final output = _expectSuccess(result).output!;
  final report = Map<String, Object?>.from(
    jsonDecode(output) as Map<Object?, Object?>,
  );
  // JSON success has no decorative prefix, suffix, or alternate formatting;
  // the report's complete encoded output is part of the command contract.
  expect(output, jsonEncode(report));
  return report;
}

Map<String, Object?> _data(Map<String, Object?> report) =>
    Map<String, Object?>.from(report['data']! as Map<Object?, Object?>);

List<Map<String, Object?>> _occurrences(Map<String, Object?> report) =>
    (_data(report)['occurrences']! as List<Object?>)
        .map(
          (value) => Map<String, Object?>.from(value as Map<Object?, Object?>),
        )
        .toList();

Map<String, Object?> _single(Map<String, Object?> report) {
  final occurrences = _occurrences(report);
  expect(occurrences, hasLength(1));
  return occurrences.single;
}

Map<String, Object?> _snapshot(Directory root) {
  final result = <String, Object?>{};
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: root.path);
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    result[relative] = switch (type) {
      FileSystemEntityType.file => base64Encode(
        File(entity.path).readAsBytesSync(),
      ),
      FileSystemEntityType.directory => 'directory',
      FileSystemEntityType.link => 'link:${Link(entity.path).targetSync()}',
      _ => 'other',
    };
  }
  return result;
}

void main() {
  final projectRoot = _findProjectRoot();
  _entrypoint = p.join(projectRoot.path, 'bin', 'agent_resource.dart');
  _packageConfig = p.join(
    projectRoot.path,
    '.dart_tool',
    'package_config.json',
  );

  group('agent_resource', () {
    group('agent', () {
      group('list', () {
        test('help and parser behavior use the agent group', () async {
          final root = _expectSuccess(
            await createExecutor().fake().execute(['--help']),
          ).output!;
          expect(root, contains('agent'));
          expect(root, isNot(contains('  list ')));
          final help = _expectSuccess(await _execute(['--help'])).output!;
          for (final token in [
            '--scope',
            '--harness',
            '--project-root',
            '--read-root',
            '20,000',
            'unmanaged',
          ]) {
            expect(help, contains(token), reason: token);
          }
          for (final arguments in [
            ['unexpected'],
            ['--scope', 'machine'],
            ['--harness', 'other'],
            ['--unknown'],
            ['--cwd', 'missing-separator'],
          ]) {
            _expectFailure(
              await _execute(arguments),
              exitCode: 1,
              phase: MambaExecutionPhase.parse,
            );
          }
        });

        test('overlapping read roots are location-deduplicated', () async {
          await _withSandbox((sandbox) async {
            _write(sandbox.project, '.claude/agents/a.md', _claude('same'));
            final args = [..._projectArgs(sandbox), '--format', 'json'];
            final original = _single(_report(await _execute(args)));
            final report = _report(
              await _execute([
                ...args,
                '--read-root',
                '${sandbox.project.path}${Platform.pathSeparator}',
                '--read-root',
                '${sandbox.project.path}${Platform.pathSeparator}',
              ]),
            );
            expect(_single(report), original);
            expect(_data(report)['collisions'], isEmpty);
          });
        });

        test('filters and scope do not bypass explicit read-root validation', () async {
          await _withSandbox((sandbox) async {
            for (final scope in ['project', 'user']) {
              final failure = _expectFailure(
                await _execute([
                  ..._projectArgs(sandbox),
                  '--harness',
                  'pi',
                  '--scope',
                  scope,
                  '--home',
                  '${sandbox.home.path}${Platform.pathSeparator}',
                  '--read-root',
                  '${p.join(sandbox.root.path, 'missing')}${Platform.pathSeparator}',
                ]),
                exitCode: 1,
              );
              expect(failure.message, contains('read root does not exist'));
            }
          });
        });

        test(
          'global Codex agents settings are not role declarations',
          () async {
            await _withSandbox((sandbox) async {
              _write(
                sandbox.project,
                '.codex/config.toml',
                '[agents]\nenabled = true\nmax_threads = 4\nmax_depth = 2\n'
                    '[agents.reviewer]\ndescription = "Reviews."\n',
              );
              final occurrence = _single(
                _report(
                  await _execute([
                    ..._projectArgs(sandbox),
                    '--format',
                    'json',
                  ]),
                ),
              );
              expect((occurrence['binding']! as Map)['roleKey'], 'reviewer');
              final request = _write(
                sandbox.root,
                'request.json',
                jsonEncode({
                  'schemaVersion': 1,
                  'operation': 'inspect',
                  'source': {
                    'kind': 'codex-role',
                    'configFile': p.join(
                      sandbox.project.path,
                      '.codex',
                      'config.toml',
                    ),
                    'roleKey': 'max_threads',
                  },
                  'context': {'workingDirectory': sandbox.work.path},
                }),
              );
              final selected = await createExecutor().fake().execute([
                'agent',
                'inspect',
                '--request',
                request.path,
                '--format',
                'json',
              ]);
              expect(
                selected,
                isA<MambaFailureResult>()
                    .having((v) => v.exitCode, 'status', 1)
                    .having(
                      (v) => v.message,
                      'message',
                      contains('declares no'),
                    )
                    .having((v) => v.output, 'output', isNull)
                    .having(
                      (v) => v.error.phase,
                      'phase',
                      MambaExecutionPhase.run,
                    )
                    .having((v) => v.error.commandPath, 'path', [
                      'agent_resource',
                      'agent',
                      'inspect',
                    ]),
              );
            });
          },
        );

        test('automatic boundary search exhaustion is incomplete, not cwd fallback', () async {
          await _withSandbox((sandbox) async {
            var current = sandbox.project;
            for (var i = 0; i < 64; i++) {
              current = Directory(p.join(current.path, 'd'));
            }
            current.createSync(recursive: true);
            _write(sandbox.project, '.git', 'gitdir: elsewhere');
            final failure = _expectFailure(
              await _execute([
                '--cwd',
                '${current.path}${Platform.pathSeparator}',
                '--format',
                'json',
              ]),
              exitCode: 3,
            );
            expect(failure.message, contains('64'));
          });
        });

        test('coverage records actual ancestry and traversal depth', () async {
          await _withSandbox((sandbox) async {
            _write(sandbox.project, '.claude/agents/a/b/deep.md', _claude());
            final coverage =
                _data(
                      _report(
                        await _execute([
                          ..._projectArgs(sandbox),
                          '--format',
                          'json',
                        ]),
                      ),
                    )['coverage']!
                    as Map;
            expect(coverage['ancestors'], 2);
            expect(coverage['depth'], 2);
          });
        });

        test('text includes every safe occurrence and coverage fact', () async {
          await _withSandbox((sandbox) async {
            _write(
              sandbox.project,
              '.codex/config.toml',
              '[agents.reviewer]\ndescription = "Reviews."\nconfig_file = "roles/reviewer.toml"\n',
            );
            _write(
              sandbox.project,
              '.codex/roles/reviewer.toml',
              '# no private body\n',
            );
            final args = _projectArgs(sandbox);
            final report = _report(
              await _execute([...args, '--format', 'json']),
            );
            final text = _expectSuccess(await _execute(args)).output!;
            // Every map key, scalar and null is represented in plain text.
            void check(Object? value) {
              if (value is Map) {
                for (final entry in value.entries) {
                  expect(text, contains('${entry.key}:'));
                  check(entry.value);
                }
              } else if (value is List) {
                for (final item in value) {
                  check(item);
                }
              } else {
                expect(text, contains('$value'));
              }
            }

            check(report['data']);
          });
        });

        test('intermediate native root and config links are refused', () async {
          for (final harness in ['claude', 'codex', 'pi']) {
            await _withSandbox((sandbox) async {
              final target = Directory(p.join(sandbox.root.path, 'outside'))
                ..createSync();
              _write(
                target,
                'agents/secret.${harness == 'codex' ? 'toml' : 'md'}',
                'PRIVATE',
              );
              final link = Link(p.join(sandbox.project.path, '.$harness'));
              if (!_tryLink(link, target.path, directory: true)) {
                markTestSkipped('directory symlink creation is unavailable');
                return;
              }
              _expectFailure(
                await _execute([
                  ..._projectArgs(sandbox),
                  '--harness',
                  harness,
                  '--format',
                  'json',
                ]),
                exitCode: 4,
              );
            });
          }
        });

        for (final intermediate in [false, true]) {
          test(
            'bound ${intermediate ? 'intermediate' : 'file'} links are unsupported occurrences',
            () async {
              await _withSandbox((sandbox) async {
                final target = _write(
                  sandbox.root,
                  'outside/secret.toml',
                  'PRIVATE-INVALID',
                );
                _write(
                  sandbox.project,
                  '.codex/config.toml',
                  '[agents.reviewer]\ndescription = "Reviews."\nconfig_file = "roles/reviewer.toml"\n',
                );
                final link = Link(
                  p.join(
                    sandbox.project.path,
                    '.codex',
                    'roles',
                    intermediate ? '' : 'reviewer.toml',
                  ),
                );
                link.parent.createSync(recursive: true);
                if (!_tryLink(
                  link,
                  intermediate ? target.parent.path : target.path,
                  directory: intermediate,
                )) {
                  markTestSkipped('symlink creation is unavailable');
                  return;
                }
                final report = _report(
                  await _execute([
                    ..._projectArgs(sandbox),
                    '--harness',
                    'codex',
                    '--format',
                    'json',
                  ]),
                );
                final occurrence = _single(report);
                expect(occurrence['eligibility'], 'unsupported-link');
                expect(occurrence['form'], 'codex-config-bound-role');
                expect((occurrence['binding']! as Map)['roleKey'], 'reviewer');
                expect(
                  (occurrence['validation']! as Map)['status'],
                  'incomplete',
                );
                expect(jsonEncode(report), isNot(contains('PRIVATE-INVALID')));
                final request = _write(
                  sandbox.root,
                  'linked-request.json',
                  jsonEncode({
                    'schemaVersion': 1,
                    'operation': 'inspect',
                    'source': {
                      'kind': 'codex-role',
                      'configFile': p.join(
                        sandbox.project.path,
                        '.codex',
                        'config.toml',
                      ),
                      'roleKey': 'reviewer',
                    },
                    'context': {'workingDirectory': sandbox.work.path},
                  }),
                );
                final inspected = await createExecutor().fake().execute([
                  'agent',
                  'inspect',
                  '--request',
                  request.path,
                ]);
                expect(
                  inspected,
                  isA<MambaFailureResult>()
                      .having((v) => v.exitCode, 'status', 4)
                      .having(
                        (v) => v.message,
                        'message',
                        contains('linked role definition'),
                      )
                      .having((v) => v.output, 'output', isNull)
                      .having(
                        (v) => v.error.phase,
                        'phase',
                        MambaExecutionPhase.run,
                      )
                      .having((v) => v.error.commandPath, 'path', [
                        'agent_resource',
                        'agent',
                        'inspect',
                      ]),
                );
              });
            },
          );
        }

        test('nested read-root overlap does not repeat traversal or metadata reads', () async {
          await _withSandbox((sandbox) async {
            final nested = Directory(
              p.join(sandbox.project.path, '.claude', 'agents', 'nested'),
            );
            _write(nested, '.claude/agents/a.md', _claude());
            final args = [
              ..._projectArgs(sandbox),
              '--harness',
              'claude',
              '--format',
              'json',
            ];
            final original = _report(await _execute(args));
            final repeated = _report(
              await _execute([
                ...args,
                '--read-root',
                '${nested.path}${Platform.pathSeparator}',
              ]),
            );
            expect(_occurrences(repeated), _occurrences(original));
            final before = _data(original)['coverage']! as Map;
            final after = _data(repeated)['coverage']! as Map;
            for (final count in ['entries', 'directories', 'metadataBytes']) {
              expect(after[count], before[count], reason: count);
            }
          });
        });

        test(
          'same content at distinct locations and bound forms remains distinct',
          () async {
            await _withSandbox((sandbox) async {
              _write(
                sandbox.project,
                '.claude/agents/a.md',
                _claude('duplicate'),
              );
              _write(
                sandbox.project,
                '.claude/agents/b.md',
                _claude('duplicate'),
              );
              _write(
                sandbox.project,
                '.codex/agents/a.toml',
                _codex('codex-duplicate'),
              );
              _write(
                sandbox.project,
                '.codex/config.toml',
                '[agents.reviewer]\nconfig_file = "agents/a.toml"\n',
              );
              final report = _report(
                await _execute([..._projectArgs(sandbox), '--format', 'json']),
              );
              final occurrences = _occurrences(report);
              expect(occurrences, hasLength(4));
              expect(
                occurrences.map((v) => v['occurrenceId']).toSet(),
                hasLength(4),
              );
              expect(_data(report)['collisions'], hasLength(2));
            });
          },
        );

        test('all explicit directory overrides are validated before presentation filtering', () async {
          await _withSandbox((sandbox) async {
            for (final option in [
              '--home',
              '--claude-config-dir',
              '--codex-home',
              '--pi-agent-dir',
            ]) {
              final failure = _expectFailure(
                await _execute([
                  ..._projectArgs(sandbox),
                  '--harness',
                  'pi',
                  option,
                  '${p.join(sandbox.root.path, 'missing')}${Platform.pathSeparator}',
                ]),
                exitCode: 1,
              );
              expect(failure.message, contains('does not exist'));
            }
          });
        });

        test(
          'explicit linked native context is refused even when filtered out',
          () async {
            await _withSandbox((sandbox) async {
              final target = Directory(p.join(sandbox.root.path, 'target'))
                ..createSync();
              final linked = Link(p.join(sandbox.root.path, 'linked-config'));
              if (!_tryLink(linked, target.path, directory: true)) {
                markTestSkipped('directory links are unavailable');
                return;
              }
              final failure = _expectFailure(
                await _execute([
                  ..._projectArgs(sandbox),
                  '--harness',
                  'pi',
                  '--codex-home',
                  '${linked.path}${Platform.pathSeparator}',
                ]),
                exitCode: 4,
              );
              expect(failure.message, contains('linked native path'));
            });
          },
        );

        test('empty project succeeds without consulting a home', () async {
          await _withSandbox((sandbox) async {
            final report = _report(
              await _execute([..._projectArgs(sandbox), '--format', 'json']),
            );
            expect(report, {
              'schemaVersion': 1,
              'command': 'agent list',
              'outcome': 'inventoried',
              'data': anything,
              'diagnostics': anything,
            });
            final data = _data(report);
            expect(data.keys, {
              'scope',
              'verification',
              'occurrences',
              'collisions',
              'coverage',
            });
            expect(data['scope'], 'project');
            expect(data['occurrences'], isEmpty);
            final coverage = data['coverage']! as Map<Object?, Object?>;
            expect(coverage['status'], 'complete');
            expect(coverage['rootsAbsent'], greaterThan(0));
            expect(coverage['limits'], {
              'ancestors': 64,
              'depth': 16,
              'entries': 20000,
              'directories': 2000,
              'metadataBytes': 67108864,
            });
          });
        });

        test(
          'Claude and Codex project ancestors retain native identity',
          () async {
            await _withSandbox((sandbox) async {
              _write(sandbox.project, '.git/keep', '');
              _write(
                sandbox.project,
                '.claude/agents/root.md',
                _claude('root'),
              );
              _write(
                sandbox.work,
                '.claude/agents/nested/near.md',
                _claude('near'),
              );
              _write(
                sandbox.project,
                '.codex/agents/root.toml',
                _codex('codex-root'),
              );
              _write(
                sandbox.work,
                '.codex/agents/near.toml',
                _codex('codex-near'),
              );
              final occurrences = _occurrences(
                _report(
                  await _execute([
                    ..._projectArgs(sandbox),
                    '--format',
                    'json',
                  ]),
                ),
              );
              expect(occurrences, hasLength(4));
              expect(occurrences.map((value) => value['form']).toSet(), {
                'claude-agent-file',
                'codex-agent-file',
              });
              expect(occurrences.map((value) => value['scope']).toSet(), {
                'project',
              });
              expect(occurrences.map((value) => value['management']).toSet(), {
                'unmanaged',
              });
              expect(
                occurrences.map((value) => value['modification']).toSet(),
                {'notVerified'},
              );
              for (final occurrence in occurrences) {
                expect(occurrence['occurrenceId'], hasLength(64));
                expect(occurrence['path'], isNot(contains('PRIVATE')));
                expect(jsonEncode(occurrence), isNot(contains('PRIVATE')));
              }
            });
          },
        );

        test('automatic project boundary uses a git marker', () async {
          await _withSandbox((sandbox) async {
            _write(sandbox.project, '.git', 'gitdir: elsewhere');
            _write(sandbox.project, '.claude/agents/root.md', _claude('root'));
            _write(
              sandbox.root,
              '.claude/agents/outside.md',
              _claude('outside'),
            );
            final occurrences = _occurrences(
              _report(
                await _execute([
                  '--cwd',
                  '${sandbox.work.path}${Platform.pathSeparator}',
                  '--format',
                  'json',
                ]),
              ),
            );
            expect(occurrences, hasLength(1));
            expect(occurrences.single['path'], contains('root.md'));
          });
        });

        test(
          'automatic project boundary falls back to cwd without git',
          () async {
            await _withSandbox((sandbox) async {
              _write(
                sandbox.project,
                '.claude/agents/outside.md',
                _claude('outside'),
              );
              _write(sandbox.work, '.claude/agents/near.md', _claude('near'));
              final occurrences = _occurrences(
                _report(
                  await _execute([
                    '--cwd',
                    '${sandbox.work.path}${Platform.pathSeparator}',
                    '--format',
                    'json',
                  ]),
                ),
              );
              expect(occurrences, hasLength(1));
              expect(occurrences.single['path'], contains('near.md'));
            });
          },
        );

        test(
          'Pi distinguishes native, shared, and deeper provider candidates',
          () async {
            await _withSandbox((sandbox) async {
              _write(sandbox.project, '.pi/agents/direct.md', _pi('direct'));
              _write(sandbox.project, '.pi/agents/nested/deep.md', _pi('deep'));
              _write(
                sandbox.project,
                '.agents/agents/shared.md',
                _pi('shared'),
              );
              _write(
                sandbox.project,
                '.agents/agents/nested/deep-shared.md',
                _pi('deep-shared'),
              );
              final occurrences = _occurrences(
                _report(
                  await _execute([
                    ..._projectArgs(sandbox),
                    '--format',
                    'json',
                  ]),
                ),
              );
              expect(occurrences, hasLength(4));
              expect(occurrences.map((value) => value['eligibility']).toSet(), {
                'native',
                'provider-specific',
              });
              final shared = occurrences.singleWhere(
                (value) =>
                    value['destination'] == 'shared' &&
                    value['eligibility'] == 'native',
              );
              expect(shared['path'], contains('.agents'));
              expect(
                occurrences.where(
                  (value) => value['form'] == 'pi-provider-specific-file',
                ),
                hasLength(2),
              );
            });
          },
        );

        test('user and all scopes honor explicit native context overrides', () async {
          await _withSandbox((sandbox) async {
            _write(
              sandbox.root,
              'claude-config/agents/user.md',
              _claude('user-claude'),
            );
            _write(
              sandbox.root,
              'codex-home/agents/user.toml',
              _codex('user-codex'),
            );
            _write(sandbox.root, 'pi-home/agents/user.md', _pi('user-pi'));
            _write(
              sandbox.project,
              '.claude/agents/project.md',
              _claude('project'),
            );
            final args = [
              ..._projectArgs(sandbox),
              '--home',
              '${sandbox.home.path}${Platform.pathSeparator}',
              '--claude-config-dir',
              '${p.join(sandbox.root.path, 'claude-config')}${Platform.pathSeparator}',
              '--codex-home',
              '${p.join(sandbox.root.path, 'codex-home')}${Platform.pathSeparator}',
              '--pi-agent-dir',
              '${p.join(sandbox.root.path, 'pi-home')}${Platform.pathSeparator}',
            ];
            final user = _occurrences(
              _report(
                await _execute([
                  ...args,
                  '--scope',
                  'user',
                  '--format',
                  'json',
                ]),
              ),
            );
            expect(user, hasLength(3));
            expect(user.map((value) => value['scope']).toSet(), {'user'});
            final all = _occurrences(
              _report(
                await _execute([...args, '--scope', 'all', '--format', 'json']),
              ),
            );
            expect(all, hasLength(4));
            expect(all.map((value) => value['scope']).toSet(), {
              'project',
              'user',
            });
            final filtered = _occurrences(
              _report(
                await _execute([
                  ...args,
                  '--scope',
                  'all',
                  '--harness',
                  'pi',
                  '--format',
                  'json',
                ]),
              ),
            );
            expect(filtered, hasLength(1));
            expect(filtered.single['harness'], 'pi');
          });
        });

        test(
          'missing user native roots are empty rather than errors',
          () async {
            await _withSandbox((sandbox) async {
              final report = _report(
                await _execute([
                  ..._projectArgs(sandbox),
                  '--scope',
                  'user',
                  '--home',
                  '${sandbox.home.path}${Platform.pathSeparator}',
                  '--format',
                  'json',
                ]),
              );
              expect(_occurrences(report), isEmpty);
            });
          },
        );

        test(
          'Codex declarations share one config parse and preserve bindings',
          () async {
            await _withSandbox((sandbox) async {
              _write(
                sandbox.project,
                '.codex/config.toml',
                '[agents.first]\n'
                    'description = "First declaration."\n'
                    'config_file = "roles/first.toml"\n\n'
                    '[agents.metadata]\ndescription = "Metadata only."\n',
              );
              _write(
                sandbox.project,
                '.codex/roles/first.toml',
                'developer_instructions = "PRIVATE-BOUND"\n',
              );
              final occurrences = _occurrences(
                _report(
                  await _execute([
                    ..._projectArgs(sandbox),
                    '--format',
                    'json',
                  ]),
                ),
              );
              expect(occurrences, hasLength(2));
              final first = occurrences.singleWhere(
                (value) =>
                    (value['binding']! as Map<Object?, Object?>)['roleKey'] ==
                    'first',
              );
              final identity = first['identity']! as Map<Object?, Object?>;
              expect(identity['name'], {
                'declared': null,
                'resolved': 'first',
                'provenance': 'binding-fallback',
                'bindingHint': 'first',
              });
              final metadata = occurrences.singleWhere(
                (value) =>
                    (value['binding']! as Map<Object?, Object?>)['roleKey'] ==
                    'metadata',
              );
              expect(metadata['path'], endsWith('config.toml'));
              expect(jsonEncode(occurrences), isNot(contains('PRIVATE-BOUND')));
            });
          },
        );

        test('read roots add only Claude project occurrences', () async {
          await _withSandbox((sandbox) async {
            final extra = Directory(p.join(sandbox.root.path, 'extra'))
              ..createSync();
            _write(extra, '.claude/agents/extra.md', _claude('extra'));
            _write(extra, '.codex/agents/ignored.toml', _codex('ignored'));
            final occurrences = _occurrences(
              _report(
                await _execute([
                  ..._projectArgs(sandbox),
                  '--read-root',
                  '${extra.path}${Platform.pathSeparator}',
                  '--format',
                  'json',
                ]),
              ),
            );
            expect(occurrences, hasLength(1));
            expect(occurrences.single['harness'], 'claude');
          });
        });

        test(
          'collisions are per target and Pi comparison ignores case',
          () async {
            await _withSandbox((sandbox) async {
              _write(
                sandbox.project,
                '.claude/agents/same.md',
                _claude('same'),
              );
              _write(
                sandbox.project,
                '.codex/agents/same.toml',
                _codex('same'),
              );
              _write(sandbox.project, '.pi/agents/Worker.md', _pi('Worker'));
              _write(
                sandbox.project,
                '.agents/agents/worker.md',
                _pi('worker'),
              );
              final report = _report(
                await _execute([..._projectArgs(sandbox), '--format', 'json']),
              );
              expect(_occurrences(report), hasLength(4));
              final collisions = _data(report)['collisions']! as List<Object?>;
              expect(collisions, hasLength(1));
              final collision = collisions.single as Map<Object?, Object?>;
              expect(collision['harness'], 'pi');
              expect(collision['comparisonName'], 'worker');
              expect(collision['occurrenceIds'], hasLength(2));
            });
          },
        );

        test(
          'malformed candidates remain visible without filename identity',
          () async {
            await _withSandbox((sandbox) async {
              _write(
                sandbox.project,
                '.claude/agents/broken.md',
                'not an agent',
              );
              final occurrence = _single(
                _report(
                  await _execute([
                    ..._projectArgs(sandbox),
                    '--format',
                    'json',
                  ]),
                ),
              );
              final validation =
                  occurrence['validation']! as Map<Object?, Object?>;
              expect(validation['status'], 'failed');
              final identity = occurrence['identity']! as Map<Object?, Object?>;
              expect(identity['name'], {
                'declared': null,
                'resolved': null,
                'provenance': 'unresolved',
              });
            });
          },
        );

        test(
          'verify never fabricates a baseline or unchanged result',
          () async {
            await _withSandbox((sandbox) async {
              _write(sandbox.project, '.claude/agents/a.md', _claude());
              final report = _report(
                await _execute([
                  ..._projectArgs(sandbox),
                  '--verify',
                  '--format',
                  'json',
                ]),
              );
              expect(_data(report)['verification'], 'no-managed-baselines');
              expect(_single(report)['modification'], 'notVerified');
              expect(jsonEncode(report), isNot(contains('unchanged')));
            });
          },
        );

        test(
          'invalid project context and repeated adapter isolation are honest',
          () async {
            await _withSandbox((sandbox) async {
              final outside = Directory(p.join(sandbox.root.path, 'outside'))
                ..createSync();
              _expectFailure(
                await _execute([
                  '--cwd',
                  '${sandbox.work.path}${Platform.pathSeparator}',
                  '--project-root',
                  '${outside.path}${Platform.pathSeparator}',
                ]),
                exitCode: 1,
              );
              _write(sandbox.project, '.claude/agents/a.md', _claude());
              final adapter = createExecutor().fake();
              final first = _report(
                await adapter.execute([
                  'agent',
                  'list',
                  ..._projectArgs(sandbox),
                  '--format',
                  'json',
                ]),
              );
              expect(_occurrences(first), hasLength(1));
              final second = _report(
                await adapter.execute([
                  'agent',
                  'list',
                  ..._projectArgs(sandbox),
                  '--harness',
                  'pi',
                  '--format',
                  'json',
                ]),
              );
              expect(_occurrences(second), isEmpty);
            });
          },
        );

        test(
          'sixty-four ancestors are accepted and more are incomplete',
          () async {
            Future<void> exercise(int depth, {required int exitCode}) async {
              await _withSandbox((sandbox) async {
                var current = sandbox.project;
                for (var index = 0; index < depth; index++) {
                  current = Directory(p.join(current.path, 'd'));
                }
                current.createSync(recursive: true);
                _write(sandbox.project, '.claude/agents/root.md', _claude());
                final result = await _execute([
                  '--cwd',
                  '${current.path}${Platform.pathSeparator}',
                  '--project-root',
                  '${sandbox.project.path}${Platform.pathSeparator}',
                  '--format',
                  'json',
                ]);
                if (exitCode == 0) {
                  _report(result);
                } else {
                  _expectFailure(result, exitCode: exitCode);
                }
              });
            }

            await exercise(63, exitCode: 0);
            await exercise(64, exitCode: 3);
          },
        );

        test(
          'depth sixteen is accepted and deeper traversal is incomplete',
          () async {
            await _withSandbox((sandbox) async {
              final root = Directory(
                p.join(sandbox.project.path, '.claude', 'agents'),
              );
              root.createSync(recursive: true);
              var current = root;
              for (var depth = 0; depth < 16; depth++) {
                current = Directory(p.join(current.path, 'd$depth'));
              }
              _write(current, 'deep.md', _claude('deep'));
              _report(
                await _execute([..._projectArgs(sandbox), '--format', 'json']),
              );
              Directory(p.join(current.path, 'too-deep')).createSync();
              _expectFailure(
                await _execute(_projectArgs(sandbox)),
                exitCode: 3,
              );
            });
          },
        );

        test(
          'directory and entry budgets fail without partial output',
          () async {
            await _withSandbox((sandbox) async {
              final agents = Directory(
                p.join(sandbox.project.path, '.claude', 'agents'),
              )..createSync(recursive: true);
              for (var index = 0; index < 1999; index++) {
                Directory(p.join(agents.path, 'd$index')).createSync();
              }
              final report = _report(
                await _execute([..._projectArgs(sandbox), '--format', 'json']),
              );
              expect((_data(report)['coverage']! as Map)['directories'], 2000);
              Directory(p.join(agents.path, 'overflow')).createSync();
              _expectFailure(
                await _execute(_projectArgs(sandbox)),
                exitCode: 3,
              );
            });
            await _withSandbox((sandbox) async {
              final agents = Directory(
                p.join(sandbox.project.path, '.claude', 'agents'),
              )..createSync(recursive: true);
              for (var index = 0; index < 20000; index++) {
                File(p.join(agents.path, 'f$index.txt')).writeAsStringSync('');
              }
              final report = _report(
                await _execute([..._projectArgs(sandbox), '--format', 'json']),
              );
              expect((_data(report)['coverage']! as Map)['entries'], 20000);
              File(p.join(agents.path, 'overflow.txt')).writeAsStringSync('');
              _expectFailure(
                await _execute(_projectArgs(sandbox)),
                exitCode: 3,
              );
            });
          },
          timeout: const Timeout(Duration(minutes: 2)),
        );

        test('aggregate metadata budget is independently enforced', () async {
          await _withSandbox((sandbox) async {
            final agents = Directory(
              p.join(sandbox.project.path, '.codex', 'agents'),
            )..createSync(recursive: true);
            for (var index = 0; index < 64; index++) {
              final file = File(p.join(agents.path, '$index.toml'));
              final handle = file.openSync(mode: FileMode.write);
              handle.truncateSync(1048576);
              handle.closeSync();
            }
            _report(
              await _execute([
                ..._projectArgs(sandbox),
                '--harness',
                'codex',
                '--format',
                'json',
              ]),
            );
            final file = File(p.join(agents.path, 'overflow.toml'));
            final handle = file.openSync(mode: FileMode.write);
            handle.truncateSync(1048576);
            handle.closeSync();
            _expectFailure(
              await _execute([..._projectArgs(sandbox), '--harness', 'codex']),
              exitCode: 3,
            );
          });
        }, timeout: const Timeout(Duration(minutes: 2)));

        test(
          'malformed declaring config and over-cap candidates are incomplete',
          () async {
            await _withSandbox((sandbox) async {
              _write(sandbox.project, '.codex/config.toml', '[agents');
              _expectFailure(
                await _execute(_projectArgs(sandbox)),
                exitCode: 3,
              );
            });
            await _withSandbox((sandbox) async {
              final file = _write(
                sandbox.project,
                '.claude/agents/large.md',
                _claude(),
              );
              final handle = file.openSync(mode: FileMode.append);
              handle.truncateSync(1048577);
              handle.closeSync();
              _expectFailure(
                await _execute(_projectArgs(sandbox)),
                exitCode: 3,
              );
              file.renameSync('${file.path}.closed');
            });
          },
        );

        test(
          'Pi-only inventory does not scan a Claude/Codex ancestor chain',
          () async {
            await _withSandbox((sandbox) async {
              var current = sandbox.work;
              for (var index = 0; index < 64; index++) {
                current = Directory(p.join(current.path, 'deeper'));
              }
              current.createSync(recursive: true);
              _write(sandbox.project, '.pi/agents/worker.md', _pi());
              final report = _report(
                await _execute([
                  '--cwd',
                  '${current.path}${Platform.pathSeparator}',
                  '--project-root',
                  '${sandbox.project.path}${Platform.pathSeparator}',
                  '--harness',
                  'pi',
                  '--format',
                  'json',
                ]),
              );
              expect(_single(report)['harness'], 'pi');
              expect(
                _data(report)['coverage'],
                isA<Map<Object?, Object?>>().having(
                  (coverage) => coverage['ancestors'],
                  'selected Pi boundary',
                  1,
                ),
              );
            });
          },
        );

        test(
          'deeper linked Pi candidates retain provider-specific form',
          () async {
            await _withSandbox((sandbox) async {
              final agents = Directory(
                p.join(sandbox.project.path, '.pi', 'agents', 'nested'),
              )..createSync(recursive: true);
              final target = _write(sandbox.root, 'target.md', _pi('target'));
              if (!_tryLink(
                Link(p.join(agents.path, 'linked.md')),
                target.path,
              )) {
                markTestSkipped('file symlink creation is unavailable');
                return;
              }
              final occurrence = _single(
                _report(
                  await _execute([
                    ..._projectArgs(sandbox),
                    '--harness',
                    'pi',
                    '--format',
                    'json',
                  ]),
                ),
              );
              expect(occurrence['eligibility'], 'unsupported-link');
              expect(occurrence['form'], 'pi-provider-specific-file');
              expect(
                jsonEncode(occurrence),
                isNot(contains('PRIVATE-PI-BODY')),
              );
            });
          },
        );

        test(
          'linked candidates are visible and linked roots are refused',
          () async {
            await _withSandbox((sandbox) async {
              final agents = Directory(
                p.join(sandbox.project.path, '.claude', 'agents'),
              )..createSync(recursive: true);
              final target = _write(
                sandbox.root,
                'target.md',
                _claude('target'),
              );
              try {
                Link(p.join(agents.path, 'linked.md')).createSync(target.path);
              } on FileSystemException {
                markTestSkipped('file symlink creation is unavailable');
                return;
              }
              final occurrence = _single(
                _report(
                  await _execute([
                    ..._projectArgs(sandbox),
                    '--format',
                    'json',
                  ]),
                ),
              );
              expect(occurrence['eligibility'], 'unsupported-link');
              expect(occurrence['validation'], {
                'status': 'incomplete',
                'coverage': ['link-observation'],
                'diagnostics': anything,
              });
              expect(jsonEncode(occurrence), isNot(contains('PRIVATE-BODY')));
            });
            await _withSandbox((sandbox) async {
              final actual = Directory(
                p.join(sandbox.root.path, 'actual-agents'),
              )..createSync();
              final linked = Link(
                p.join(sandbox.project.path, '.claude', 'agents'),
              );
              linked.parent.createSync(recursive: true);
              try {
                linked.createSync(actual.path);
              } on FileSystemException {
                markTestSkipped('directory symlink creation is unavailable');
                return;
              }
              _expectFailure(
                await _execute(_projectArgs(sandbox)),
                exitCode: 4,
              );
            });
          },
        );

        test(
          'inert hook and MCP declarations do not execute or leak values',
          () async {
            await _withSandbox((sandbox) async {
              _write(
                sandbox.project,
                '.claude/agents/inert.md',
                _claude(
                  'inert',
                  'hooks:\n  Stop:\n    command: "touch EXECUTED-MARKER"\n'
                      'mcpServers:\n  - private:\n      env:\n'
                      '        TOKEN: SECRET-INVENTORY-VALUE\n',
                ),
              );
              final report = _report(
                await _execute([..._projectArgs(sandbox), '--format', 'json']),
              );
              expect(_occurrences(report), hasLength(1));
              expect(
                jsonEncode(report),
                isNot(contains('SECRET-INVENTORY-VALUE')),
              );
              expect(
                jsonEncode(report),
                isNot(contains('touch EXECUTED-MARKER')),
              );
              expect(
                File(p.join(sandbox.project.path, 'EXECUTED-MARKER'))
                    .existsSync(),
                isFalse,
              );
            });
          },
        );

        test(
          'permission-denied required candidates are incomplete when supported',
          () async {
            if (Platform.isWindows) {
              markTestSkipped(
                'portable permission setup is unavailable on Windows',
              );
              return;
            }
            await _withSandbox((sandbox) async {
              final file = _write(
                sandbox.project,
                '.claude/agents/denied.md',
                _claude(),
              );
              final changed = await Process.run('chmod', ['000', file.path]);
              if (changed.exitCode != 0) {
                markTestSkipped('chmod is unavailable');
                return;
              }
              try {
                _expectFailure(
                  await _execute(_projectArgs(sandbox)),
                  exitCode: 3,
                );
              } finally {
                await Process.run('chmod', ['600', file.path]);
              }
            });
          },
        );

        test('success and failure preserve every sandbox entry and close handles', () async {
          await _withSandbox((sandbox) async {
            final file = _write(
              sandbox.project,
              '.claude/agents/a.md',
              _claude(),
            );
            _write(sandbox.root, 'sentinel.txt', 'keep');
            final before = _snapshot(sandbox.root);
            _report(
              await _execute([..._projectArgs(sandbox), '--format', 'json']),
            );
            file.renameSync('${file.path}.renamed');
            File('${file.path}.renamed').renameSync(file.path);
            file.writeAsStringSync('broken');
            _report(
              await _execute([..._projectArgs(sandbox), '--format', 'json']),
            );
            _expectFailure(
              await _execute([
                '--scope',
                'user',
                ..._projectArgs(sandbox),
                '--home',
                '${p.join(sandbox.root.path, 'missing-home')}${Platform.pathSeparator}',
              ]),
              exitCode: 1,
            );
            _expectSuccess(await _execute(['--help']));
            final after = _snapshot(sandbox.root);
            expect(after.keys.toSet(), before.keys.toSet());
            expect(after['sentinel.txt'], before['sentinel.txt']);
          });
        });

        test(
          'production JSON and text inventory match explicit isolated context',
          () async {
            await _withSandbox((sandbox) async {
              _write(sandbox.project, '.pi/agents/a.md', _pi('production'));
              final environment = isolatedEnvironment(sandbox.root);
              Future<CliProcessResult> run(List<String> arguments) =>
                  runDartScript(
                    script: _entrypoint,
                    packageConfig: _packageConfig,
                    arguments: ['agent', 'list', ...arguments],
                    workingDirectory: sandbox.work,
                    environment: environment,
                    timeout: const Duration(seconds: 60),
                  );
              final json = await run([
                '--project-root',
                '${sandbox.project.path}${Platform.pathSeparator}',
                '--format',
                'json',
              ]);
              expect(json.exitCode, 0);
              expect(json.stderr, isEmpty);
              final report = Map<String, Object?>.from(
                jsonDecode(json.stdout) as Map<Object?, Object?>,
              );
              expect(_single(report)['harness'], 'pi');
              expect(json.stdout, isNot(contains('PRIVATE-PI-BODY')));

              _write(
                sandbox.home,
                '.claude/agents/user.md',
                _claude('home-user'),
              );
              final text = await run(['--scope', 'user']);
              expect(text.exitCode, 0, reason: text.stderr);
              expect(text.stderr, isEmpty);
              expect(text.stdout, contains('home-user'));
              expect(text.stdout, contains('agent list: inventoried'));

              _write(
                sandbox.root,
                'env-claude/agents/env.md',
                _claude('env-claude'),
              );
              _write(
                sandbox.root,
                'env-codex/agents/env.toml',
                _codex('env-codex'),
              );
              _write(sandbox.root, 'env-pi/agents/env.md', _pi('env-pi'));
              environment['CLAUDE_CONFIG_DIR'] = p.join(
                sandbox.root.path,
                'env-claude',
              );
              environment['CODEX_HOME'] = p.join(
                sandbox.root.path,
                'env-codex',
              );
              environment['PI_CODING_AGENT_DIR'] = p.join(
                sandbox.root.path,
                'env-pi',
              );
              final nativeEnvironment = await run([
                '--scope',
                'user',
                '--format',
                'json',
              ]);
              expect(nativeEnvironment.exitCode, 0);
              expect(nativeEnvironment.stderr, isEmpty);
              final environmentReport = Map<String, Object?>.from(
                jsonDecode(nativeEnvironment.stdout) as Map<Object?, Object?>,
              );
              final environmentOccurrences = _occurrences(environmentReport);
              expect(environmentOccurrences, hasLength(3));
              expect(
                jsonEncode(environmentOccurrences),
                allOf(
                  contains('env-claude'),
                  contains('env-codex'),
                  contains('env-pi'),
                  isNot(contains('home-user')),
                ),
              );
            });
          },
          timeout: const Timeout(Duration(seconds: 120)),
        );
      });
    });
  });
}

Directory _findProjectRoot() {
  var current = Directory.current.absolute;
  while (true) {
    if (File(p.join(current.path, 'pubspec.yaml')).existsSync()) return current;
    final parent = current.parent;
    if (p.equals(parent.path, current.path)) {
      throw StateError('Could not locate package root.');
    }
    current = parent;
  }
}
