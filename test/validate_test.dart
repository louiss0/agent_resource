import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/process_test_support.dart';

const _markerSizeLimit = 1048576;
const _frontmatterSizeLimit = 65536;
const _profile = 'agentskills-core-ascii-v1';
const _baseline = '69ef37e9424c0a7ea9dd2293b559e43ec8176379';

late final String _entrypoint;
late final String _packageConfig;

String _absoluteLexical(String value) =>
    p.normalize(Directory(value).absolute.path);

String _sizedFrontmatter(int bytes, {bool multibyte = false}) {
  const prefix = 'name: valid-skill\ndescription: valid\n#';
  final fillerBytes = bytes - utf8.encode(prefix).length - 1;
  if (fillerBytes < 0) throw ArgumentError.value(bytes, 'bytes');
  if (!multibyte) {
    return '---\n$prefix${'x' * fillerBytes}\n---\n';
  }
  final pairs = fillerBytes ~/ 2;
  final odd = fillerBytes.isOdd ? 'x' : '';
  return '---\n$prefix${'é' * pairs}$odd\n---\n';
}

List<int> _sizedMarkerBytes(int bytes) {
  final prefix = utf8.encode(_marker(body: ''));
  final fillerBytes = bytes - prefix.length;
  if (fillerBytes < 0) throw ArgumentError.value(bytes, 'bytes');
  final result = <int>[...prefix];
  for (var i = 0; i < fillerBytes ~/ 2; i++) {
    result.addAll(const [0xC3, 0xA9]);
  }
  if (fillerBytes.isOdd) result.add(0x78);
  return result;
}

String _marker({
  String name = 'valid-skill',
  String description = 'A valid skill.',
  String? license,
  String? compatibility,
  String? metadata,
  String? allowedTools,
  String body = '# Instructions\n',
}) {
  final lines = <String>['name: $name', 'description: $description'];
  if (license != null) lines.add('license: $license');
  if (compatibility != null) lines.add('compatibility: $compatibility');
  if (metadata != null) lines.add('metadata:\n$metadata');
  if (allowedTools != null) lines.add('allowed-tools: $allowedTools');
  return '---\n${lines.join('\n')}\n---\n$body';
}

Future<T> _withParent<T>(Future<T> Function(Directory parent) body) async {
  final parent = await Directory.systemTemp.createTemp(
    'agent-resource-validate-',
  );
  try {
    return await body(parent);
  } finally {
    await parent.delete(recursive: true);
  }
}

Future<T> _withSkill<T>(
  Future<T> Function(Directory skill) body, {
  String directoryName = 'valid-skill',
  List<int>? bytes,
  String? marker,
}) => _withParent((parent) async {
  final skill = Directory(p.join(parent.path, directoryName))
    ..createSync(recursive: true);
  if (bytes != null || marker != null) {
    File(p.join(skill.path, 'SKILL.md'))
        .writeAsBytesSync(bytes ?? utf8.encode(marker!));
  }
  return body(skill);
});

Future<T> _withRoot<T>(Future<T> Function(Directory root) body) async {
  final root = await Directory.systemTemp.createTemp(
    'agent-resource-validate-',
  );
  try {
    return await body(root);
  } finally {
    await root.delete(recursive: true);
  }
}

Map<String, String> _snapshot(Directory root) {
  final entries = <String, String>{'.': 'directory'};

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

Future<MambaExecutionResult> _execute(
  List<String> arguments, {
  Executor? executor,
}) => (executor ?? createExecutor()).fake().execute([
  'skill',
  'validate',
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
  required Object exitCode,
  required MambaExecutionPhase phase,
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
          'skill',
          'validate',
        ]),
  );
  return result as MambaFailureResult;
}

Map<String, Object?> _decodeObject(String text) {
  final decoded = jsonDecode(text);
  expect(decoded, isA<Map<Object?, Object?>>());
  return Map<String, Object?>.from(decoded as Map<Object?, Object?>);
}

Map<String, Object?> _reportFromSuccess(MambaSuccessResult result) =>
    _decodeObject(result.output!);

Map<String, Object?> _reportFromInvalid(MambaFailureResult result) =>
    _decodeObject(result.message);

void _expectReportShape(
  Map<String, Object?> report, {
  required String path,
  required bool valid,
}) {
  expect(report.keys.toSet(), {
    'path',
    'profile',
    'baseline',
    'valid',
    'diagnostics',
  });
  expect(report['path'], path);
  expect(report['profile'], _profile);
  expect(report['baseline'], _baseline);
  expect(report['valid'], valid);
  expect(report['diagnostics'], isA<List<Object?>>());
  for (final raw in report['diagnostics']! as List<Object?>) {
    expect(raw, isA<Map<Object?, Object?>>());
    final diagnostic = Map<String, Object?>.from(raw! as Map<Object?, Object?>);
    expect(diagnostic.keys.toSet(), {
      'code',
      'category',
      'severity',
      'field',
      'message',
    });
    expect(diagnostic['code'], isA<String>());
    expect(
      diagnostic['category'],
      anyOf('specification', 'product', 'advisory'),
    );
    expect(diagnostic['severity'], anyOf('error', 'warning'));
    expect(diagnostic['field'], anyOf(isNull, isA<String>()));
    expect(diagnostic['message'], allOf(isA<String>(), isNotEmpty));
  }
}

List<Map<String, Object?>> _diagnostics(Map<String, Object?> report) =>
    (report['diagnostics']! as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map((value) => Map<String, Object?>.from(value))
        .toList();

void _expectDiagnostic(
  Map<String, Object?> report,
  String code, {
  String? field,
  String category = 'specification',
  String severity = 'error',
}) {
  final matches = _diagnostics(report).where((value) => value['code'] == code);
  expect(matches, hasLength(1), reason: 'missing diagnostic $code');
  final diagnostic = matches.single;
  expect(diagnostic['category'], category);
  expect(diagnostic['severity'], severity);
  expect(diagnostic['field'], field);
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
      throw StateError('Could not locate the package root.');
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
      group('validate', () {
        test('help advertises the explicit skill root contract', () async {
          final result = _expectSuccess(await _execute(const ['--help']));
          expect(
            result.output,
            allOf(contains('validate'), contains('--skill')),
          );
          expect(result.output, contains('SKILL.md'));
        });

        test('requires --skill before command execution', () async {
          final result = _expectFailure(
            await _execute(const []),
            exitCode: isNonZero,
            phase: MambaExecutionPhase.parse,
          );
          expect(result.message, contains('skill'));
        });

        test('requires a value after --skill', () async {
          final result = _expectFailure(
            await _execute(const ['--skill']),
            exitCode: isNonZero,
            phase: MambaExecutionPhase.parse,
          );
          expect(result.message, contains('skill'));
        });

        test('rejects an unexpected positional argument', () async {
          await _withSkill((skill) async {
            final result = _expectFailure(
              await _execute(['--skill', skill.path, 'extra']),
              exitCode: isNonZero,
              phase: MambaExecutionPhase.parse,
            );
            expect(result.message, contains('extra'));
          }, marker: _marker());
        });

        test('requires a nonblank skill root', () async {
          final result = _expectFailure(
            await _execute(const ['--skill', '']),
            exitCode: 1,
            phase: MambaExecutionPhase.run,
          );
          expect(result.message.toLowerCase(), contains('blank'));
        });

        test('returns the complete valid report with no diagnostics', () async {
          await _withSkill((skill) async {
            final result = _expectSuccess(
              await _execute(['--skill', skill.path]),
            );
            final report = _reportFromSuccess(result);
            _expectReportShape(
              report,
              path: _absoluteLexical(skill.path),
              valid: true,
            );
            expect(report['diagnostics'], isEmpty);
          }, marker: _marker());
        });

        test(
          'uses the lexical absolute path for relative and dot segments',
          () async {
            await _withSkill((skill) async {
              final argument = p.relative(
                p.join(skill.path, '.', '..', p.basename(skill.path)),
                from: Directory.current.path,
              );
              final report = _reportFromSuccess(
                _expectSuccess(await _execute(['--skill', argument])),
              );
              expect(report['path'], _absoluteLexical(argument));
            }, marker: _marker());
          },
        );

        test(
          'invalid content is a report carried by MambaException2',
          () async {
            await _withSkill((skill) async {
              final result = _expectFailure(
                await _execute(['--skill', skill.path]),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
              );
              final report = _reportFromInvalid(result);
              _expectReportShape(
                report,
                path: _absoluteLexical(skill.path),
                valid: false,
              );
              _expectDiagnostic(report, 'NAME_REQUIRED', field: 'name');
            }, marker: '---\ndescription: valid\n---\n');
          },
        );

        test('reused adapters do not retain diagnostics across valid and invalid runs', () async {
          await _withSkill((skill) async {
            final adapter = createExecutor().fake();
            final valid = _expectSuccess(
              await adapter.execute([
                'skill',
                'validate',
                '--skill',
                skill.path,
              ]),
            );
            expect(_reportFromSuccess(valid)['diagnostics'], isEmpty);

            File(p.join(skill.path, 'SKILL.md'))
                .writeAsStringSync('---\ndescription: invalid\n---\n');
            final invalid = _expectFailure(
              await adapter.execute([
                'skill',
                'validate',
                '--skill',
                skill.path,
              ]),
              exitCode: 2,
              phase: MambaExecutionPhase.run,
            );
            expect(_reportFromInvalid(invalid)['valid'], isFalse);

            File(p.join(skill.path, 'SKILL.md')).writeAsStringSync(_marker());
            final validAgain = _expectSuccess(
              await adapter.execute([
                'skill',
                'validate',
                '--skill',
                skill.path,
              ]),
            );
            final reportAgain = _reportFromSuccess(validAgain);
            expect(reportAgain['valid'], isTrue);
            expect(reportAgain['diagnostics'], isEmpty);
          }, marker: _marker());
        });

        test('marker body is opaque and resources are not read', () async {
          await _withSkill(
            (skill) async {
              Directory(p.join(skill.path, 'references', 'unreadable'))
                  .createSync(recursive: true);
              File(p.join(skill.path, 'references', 'not-a-file'))
                  .writeAsStringSync(
                    'this is intentionally not a resource for validation',
                  );
              File(p.join(skill.path, 'scripts', 'run.sh'))
                ..parent.createSync(recursive: true)
                ..writeAsStringSync('exit 99\n');
              final report = _reportFromSuccess(
                _expectSuccess(await _execute(['--skill', skill.path])),
              );
              _expectReportShape(
                report,
                path: _absoluteLexical(skill.path),
                valid: true,
              );
            },
            marker: _marker(
              body: 'run scripts/run.sh and fetch https://example.invalid\n',
            ),
          );
        });

        test(
          'success, invalid, help, and parser failures preserve seeded files',
          () async {
            await _withParent((parent) async {
              final skill = Directory(p.join(parent.path, 'valid-skill'))
                ..createSync();
              File(p.join(skill.path, 'SKILL.md')).writeAsStringSync(_marker());
              Directory(p.join(parent.path, 'references')).createSync();
              File(p.join(parent.path, 'references', 'sentinel.txt'))
                  .writeAsStringSync('do not change');
              final before = _snapshot(parent);

              _expectSuccess(await _execute(['--skill', skill.path]));
              File(p.join(skill.path, 'SKILL.md'))
                  .writeAsStringSync('---\ndescription: invalid\n---\n');
              _expectFailure(
                await _execute(['--skill', skill.path]),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
              );
              File(p.join(skill.path, 'SKILL.md')).writeAsStringSync(_marker());
              _expectSuccess(await _execute(const ['--help']));
              _expectFailure(
                await _execute(const ['--unknown']),
                exitCode: isNonZero,
                phase: MambaExecutionPhase.parse,
              );
              expect(_snapshot(parent), equals(before));
            });
          },
        );

        test(
          'marker handles close before rename after success and invalid reads',
          () async {
            await _withSkill((skill) async {
              final marker = File(p.join(skill.path, 'SKILL.md'));
              _expectSuccess(await _execute(['--skill', skill.path]));
              final renamed = p.join(skill.path, 'SKILL.md.after-success');
              await marker.rename(renamed);
              await File(renamed).rename(marker.path);

              marker.writeAsBytesSync(<int>[0x2D, 0x2D, 0x2D, 0x0A, 0xFF]);
              _expectFailure(
                await _execute(['--skill', skill.path]),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
              );
              final renamedAfterInvalid = p.join(
                skill.path,
                'SKILL.md.after-invalid',
              );
              await marker.rename(renamedAfterInvalid);
              await File(renamedAfterInvalid).rename(marker.path);

              marker.writeAsBytesSync(
                List<int>.filled(_markerSizeLimit + 1, 0x78),
              );
              _expectFailure(
                await _execute(['--skill', skill.path]),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
              );
              final renamedAfterOversize = p.join(
                skill.path,
                'SKILL.md.after-oversize',
              );
              await marker.rename(renamedAfterOversize);
              await File(renamedAfterOversize).rename(marker.path);
            }, marker: _marker());
          },
        );

        test('accepts strict UTF-8 BOM and CRLF frontmatter', () async {
          await _withSkill((skill) async {
            final text = _marker().replaceAll('\n', '\r\n');
            final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(text)];
            File(p.join(skill.path, 'SKILL.md')).writeAsBytesSync(bytes);
            final report = _reportFromSuccess(
              _expectSuccess(await _execute(['--skill', skill.path])),
            );
            expect(report['valid'], isTrue);
          });
        });

        final cases =
            <({String name, String marker, String code, String field})>[
              (
                name: 'missing name',
                marker: '---\ndescription: valid\n---\n',
                code: 'NAME_REQUIRED',
                field: 'name',
              ),
              (
                name: 'wrong type name',
                marker: '---\nname: 7\ndescription: valid\n---\n',
                code: 'NAME_TYPE',
                field: 'name',
              ),
              (
                name: 'empty name',
                marker: '---\nname: ""\ndescription: valid\n---\n',
                code: 'NAME_EMPTY',
                field: 'name',
              ),
              (
                name: 'missing description',
                marker: '---\nname: valid-skill\n---\n',
                code: 'DESCRIPTION_REQUIRED',
                field: 'description',
              ),
              (
                name: 'wrong type description',
                marker: '---\nname: valid-skill\ndescription: 7\n---\n',
                code: 'DESCRIPTION_TYPE',
                field: 'description',
              ),
              (
                name: 'blank description',
                marker: '---\nname: valid-skill\ndescription: "   "\n---\n',
                code: 'DESCRIPTION_EMPTY',
                field: 'description',
              ),
              (
                name: 'description over limit',
                marker: _marker(description: 'x' * 1025),
                code: 'DESCRIPTION_LENGTH',
                field: 'description',
              ),
              (
                name: 'name over limit',
                marker: _marker(name: 'a' * 65),
                code: 'NAME_LENGTH',
                field: 'name',
              ),
              (
                name: 'uppercase name',
                marker: _marker(name: 'Bad-name'),
                code: 'NAME_FORMAT',
                field: 'name',
              ),
              (
                name: 'forbidden ASCII punctuation',
                marker: _marker(name: 'bad_name'),
                code: 'NAME_FORMAT',
                field: 'name',
              ),
              (
                name: 'trailing hyphen',
                marker: _marker(name: 'bad-'),
                code: 'NAME_FORMAT',
                field: 'name',
              ),
              (
                name: 'edge hyphen',
                marker: _marker(name: '-bad'),
                code: 'NAME_FORMAT',
                field: 'name',
              ),
              (
                name: 'consecutive hyphen',
                marker: _marker(name: 'bad--name'),
                code: 'NAME_FORMAT',
                field: 'name',
              ),
              (
                name: 'non-ASCII name policy',
                marker: _marker(name: 'café'),
                code: 'NAME_ASCII_POLICY',
                field: 'name',
              ),
              (
                name: 'directory mismatch',
                marker: _marker(name: 'other-name'),
                code: 'NAME_DIRECTORY',
                field: 'name',
              ),
            ];
        for (final testCase in cases) {
          test(testCase.name, () async {
            await _withSkill((skill) async {
              final result = _expectFailure(
                await _execute(['--skill', skill.path]),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
              );
              final report = _reportFromInvalid(result);
              _expectReportShape(
                report,
                path: _absoluteLexical(skill.path),
                valid: false,
              );
              _expectDiagnostic(
                report,
                testCase.code,
                field: testCase.field,
                category: testCase.code == 'NAME_ASCII_POLICY'
                    ? 'product'
                    : 'specification',
              );
            }, marker: testCase.marker);
          });
        }

        test('counts Unicode scalar values for descriptions', () async {
          await _withSkill((skill) async {
            final report = _reportFromSuccess(
              _expectSuccess(await _execute(['--skill', skill.path])),
            );
            expect(report['valid'], isTrue);
          }, marker: _marker(description: '😀' * 1024));
        });

        test('accepts the 64-scalar name boundary', () async {
          final name = 'a' * 64;
          await _withSkill(
            (skill) async {
              final report = _reportFromSuccess(
                _expectSuccess(await _execute(['--skill', skill.path])),
              );
              expect(report['valid'], isTrue);
            },
            directoryName: name,
            marker: _marker(name: name),
          );
        });

        test(
          'accumulates independent field diagnostics in deterministic order',
          () async {
            await _withSkill(
              (skill) async {
                final report = _reportFromInvalid(
                  _expectFailure(
                    await _execute(['--skill', skill.path]),
                    exitCode: 2,
                    phase: MambaExecutionPhase.run,
                  ),
                );
                final diagnostics = _diagnostics(report);
                expect(diagnostics.map((value) => value['field']).toList(), [
                  'name',
                  'description',
                  'license',
                  'compatibility',
                  'metadata',
                  'allowed-tools',
                  'aardvark',
                  'zeta',
                ]);
                expect(diagnostics.map((value) => value['code']).toList(), [
                  'NAME_REQUIRED',
                  'DESCRIPTION_REQUIRED',
                  'LICENSE_TYPE',
                  'COMPATIBILITY_TYPE',
                  'METADATA_TYPE',
                  'ALLOWED_TOOLS_TYPE',
                  'UNKNOWN_FIELD',
                  'UNKNOWN_FIELD',
                ]);
              },
              marker: '''---
license: 7
compatibility: 7
metadata: 7
allowed-tools: 7
aardvark: true
zeta: false
---
''',
            );
          },
        );

        test('missing marker is a specification diagnostic', () async {
          await _withSkill((skill) async {
            final report = _reportFromInvalid(
              _expectFailure(
                await _execute(['--skill', skill.path]),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
              ),
            );
            _expectDiagnostic(report, 'SKILL_FILE_MISSING');
          });
        });

        test('directory marker is not read as a file', () async {
          await _withSkill((skill) async {
            Directory(p.join(skill.path, 'SKILL.md')).createSync();
            final report = _reportFromInvalid(
              _expectFailure(
                await _execute(['--skill', skill.path]),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
              ),
            );
            _expectDiagnostic(report, 'SKILL_FILE_TYPE');
          });
        });

        test(
          'explicit root links preserve their lexical selected path',
          () async {
            await _withParent((parent) async {
              final target = Directory(p.join(parent.path, 'valid-skill'))
                ..createSync();
              File(p.join(target.path, 'SKILL.md'))
                  .writeAsStringSync(_marker());
              final linkPath = p.join(parent.path, 'selected-link');
              if (!await _tryCreateLink(linkPath, target.path)) {
                markTestSkipped('directory symlink creation is unavailable');
                return;
              }
              final report = _reportFromSuccess(
                _expectSuccess(await _execute(['--skill', linkPath])),
              );
              expect(report['path'], _absoluteLexical(linkPath));
              expect(report['valid'], isTrue);
            });
          },
        );

        test('linked marker is rejected before its target is read', () async {
          await _withParent((parent) async {
            final skill = Directory(p.join(parent.path, 'valid-skill'))
              ..createSync();
            final target = File(p.join(parent.path, 'target.md'))
              ..writeAsStringSync(_marker());
            final link = p.join(skill.path, 'SKILL.md');
            if (!await _tryCreateLink(link, target.path)) {
              markTestSkipped('file symlink creation is unavailable');
              return;
            }
            final report = _reportFromInvalid(
              _expectFailure(
                await _execute(['--skill', skill.path]),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
              ),
            );
            _expectDiagnostic(report, 'SKILL_FILE_LINK', category: 'product');
          });
        });

        test(
          'missing and unterminated frontmatter have separate diagnostics',
          () async {
            for (final fixture in <({String text, String code})>[
              (text: '# body only\n', code: 'FRONTMATTER_MISSING'),
              (
                text: '---\nname: valid-skill\n',
                code: 'FRONTMATTER_UNTERMINATED',
              ),
            ]) {
              await _withSkill((skill) async {
                final report = _reportFromInvalid(
                  _expectFailure(
                    await _execute(['--skill', skill.path]),
                    exitCode: 2,
                    phase: MambaExecutionPhase.run,
                  ),
                );
                _expectDiagnostic(report, fixture.code);
              }, marker: fixture.text);
            }
          },
        );

        test('rejects malformed YAML, duplicate keys, and non-mapping YAML', () async {
          for (final fixture in <({String text, String code})>[
            (
              text: '---\nname: [unterminated\ndescription: x\n---\n',
              code: 'YAML_INVALID',
            ),
            (
              text:
                  '---\nname: valid-skill\nname: other\ndescription: x\n---\n',
              code: 'YAML_INVALID',
            ),
            (text: '---\n- item\n---\n', code: 'FRONTMATTER_MAPPING'),
          ]) {
            await _withSkill((skill) async {
              final report = _reportFromInvalid(
                _expectFailure(
                  await _execute(['--skill', skill.path]),
                  exitCode: 2,
                  phase: MambaExecutionPhase.run,
                ),
              );
              _expectDiagnostic(report, fixture.code);
            }, marker: fixture.text);
          }
        });

        test('rejects non-string top-level YAML keys', () async {
          await _withSkill((skill) async {
            final report = _reportFromInvalid(
              _expectFailure(
                await _execute(['--skill', skill.path]),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
              ),
            );
            _expectDiagnostic(report, 'FRONTMATTER_KEYS', category: 'product');
          }, marker: '---\n1: value\nname: valid-skill\ndescription: x\n---\n');
        });

        test('enforces the marker and frontmatter byte caps', () async {
          await _withSkill(
            (skill) async {
              final report = _reportFromSuccess(
                _expectSuccess(await _execute(['--skill', skill.path])),
              );
              expect(report['valid'], isTrue);
            },
            bytes: utf8
                .encode(_marker(body: ''))
                .followedBy(
                  List<int>.filled(
                    _markerSizeLimit - utf8.encode(_marker(body: '')).length,
                    0x78,
                  ),
                )
                .toList(),
          );
          await _withSkill((skill) async {
            final report = _reportFromInvalid(
              _expectFailure(
                await _execute(['--skill', skill.path]),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
              ),
            );
            _expectDiagnostic(report, 'FILE_SIZE_LIMIT', category: 'product');
          }, bytes: List<int>.filled(_markerSizeLimit + 1, 0x78));
          await _withSkill((skill) async {
            final report = _reportFromSuccess(
              _expectSuccess(await _execute(['--skill', skill.path])),
            );
            expect(report['valid'], isTrue);
          }, marker: _sizedFrontmatter(_frontmatterSizeLimit));
          await _withSkill((skill) async {
            final report = _reportFromInvalid(
              _expectFailure(
                await _execute(['--skill', skill.path]),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
              ),
            );
            _expectDiagnostic(
              report,
              'FRONTMATTER_SIZE_LIMIT',
              category: 'product',
            );
          }, marker: _sizedFrontmatter(_frontmatterSizeLimit + 1));
        });

        test('counts multibyte marker and frontmatter caps in bytes', () async {
          await _withSkill((skill) async {
            final report = _reportFromSuccess(
              _expectSuccess(await _execute(['--skill', skill.path])),
            );
            expect(report['valid'], isTrue);
          }, bytes: _sizedMarkerBytes(_markerSizeLimit));
          await _withSkill(
            (skill) async {
              final report = _reportFromInvalid(
                _expectFailure(
                  await _execute(['--skill', skill.path]),
                  exitCode: 2,
                  phase: MambaExecutionPhase.run,
                ),
              );
              _expectDiagnostic(
                report,
                'FRONTMATTER_SIZE_LIMIT',
                category: 'product',
              );
            },
            marker: _sizedFrontmatter(
              _frontmatterSizeLimit + 1,
              multibyte: true,
            ),
          );
        });

        test(
          'rejects invalid UTF-8 without decoding or reading resources',
          () async {
            await _withSkill((skill) async {
              final report = _reportFromInvalid(
                _expectFailure(
                  await _execute(['--skill', skill.path]),
                  exitCode: 2,
                  phase: MambaExecutionPhase.run,
                ),
              );
              _expectDiagnostic(report, 'UTF8_INVALID', category: 'product');
            }, bytes: <int>[0x2D, 0x2D, 0x2D, 0x0A, 0xFF]);
          },
        );

        test(
          'accepts all documented optional string fields and metadata map',
          () async {
            await _withSkill(
              (skill) async {
                final report = _reportFromSuccess(
                  _expectSuccess(await _execute(['--skill', skill.path])),
                );
                expect(report['valid'], isTrue);
                expect(report['diagnostics'], isEmpty);
              },
              marker: '''---
name: valid-skill
description: A valid skill.
license: MIT
compatibility: Dart 3.13
metadata:
  author: example
  version: "1.0"
allowed-tools: Read Bash(git:*)
---
''',
            );
          },
        );

        final optionalCases =
            <({String name, String yaml, String code, String field})>[
              (
                name: 'license type',
                yaml: 'license: 7',
                code: 'LICENSE_TYPE',
                field: 'license',
              ),
              (
                name: 'compatibility type',
                yaml: 'compatibility: 7',
                code: 'COMPATIBILITY_TYPE',
                field: 'compatibility',
              ),
              (
                name: 'empty compatibility',
                yaml: 'compatibility: ""',
                code: 'COMPATIBILITY_LENGTH',
                field: 'compatibility',
              ),
              (
                name: 'long compatibility',
                yaml: 'compatibility: "${'x' * 501}"',
                code: 'COMPATIBILITY_LENGTH',
                field: 'compatibility',
              ),
              (
                name: 'metadata type',
                yaml: 'metadata: nope',
                code: 'METADATA_TYPE',
                field: 'metadata',
              ),
              (
                name: 'metadata value type',
                yaml: 'metadata:\n  count: 7',
                code: 'METADATA_ENTRY_TYPE',
                field: 'metadata',
              ),
              (
                name: 'allowed tools type',
                yaml: 'allowed-tools: 7',
                code: 'ALLOWED_TOOLS_TYPE',
                field: 'allowed-tools',
              ),
            ];
        for (final testCase in optionalCases) {
          test(testCase.name, () async {
            await _withSkill(
              (skill) async {
                final report = _reportFromInvalid(
                  _expectFailure(
                    await _execute(['--skill', skill.path]),
                    exitCode: 2,
                    phase: MambaExecutionPhase.run,
                  ),
                );
                _expectDiagnostic(report, testCase.code, field: testCase.field);
              },
              marker:
                  '---\nname: valid-skill\ndescription: valid\n${testCase.yaml}\n---\n',
            );
          });
        }

        test('unknown top-level fields are sorted advisory warnings', () async {
          await _withSkill(
            (skill) async {
              final report = _reportFromSuccess(
                _expectSuccess(await _execute(['--skill', skill.path])),
              );
              _expectReportShape(
                report,
                path: _absoluteLexical(skill.path),
                valid: true,
              );
              final diagnostics = _diagnostics(report);
              expect(
                diagnostics.map((value) => value['code']),
                everyElement('UNKNOWN_FIELD'),
              );
              expect(diagnostics.map((value) => value['field']), [
                'aaa',
                'zzz',
              ]);
              expect(
                diagnostics,
                everyElement(
                  allOf(
                    isA<Map<String, Object?>>(),
                    predicate<Map<String, Object?>>(
                      (value) => value['category'] == 'advisory',
                    ),
                    predicate<Map<String, Object?>>(
                      (value) => value['severity'] == 'warning',
                    ),
                  ),
                ),
              );
            },
            marker: '''---
name: valid-skill
description: valid
zzz: later
aaa: first
---
''',
          );
        });

        test('missing root is text failure with status one', () async {
          await _withRoot((root) async {
            final result = _expectFailure(
              await _execute(['--skill', p.join(root.path, 'missing')]),
              exitCode: 1,
              phase: MambaExecutionPhase.run,
            );
            expect(() => jsonDecode(result.message), throwsFormatException);
          });
        });

        test('regular-file root is text failure with status one', () async {
          await _withRoot((root) async {
            final file = File(p.join(root.path, 'root.txt'))
              ..writeAsStringSync('x');
            final result = _expectFailure(
              await _execute(['--skill', file.path]),
              exitCode: 1,
              phase: MambaExecutionPhase.run,
            );
            expect(result.message, contains('directory'));
          });
        });

        test(
          'unreadable root is operational failure when the host supports chmod',
          () async {
            if (Platform.isWindows) {
              markTestSkipped(
                'portable unreadable-directory setup is unavailable on Windows',
              );
              return;
            }
            await _withRoot((root) async {
              final changed = await Process.run('chmod', ['000', root.path]);
              if (changed.exitCode != 0) {
                markTestSkipped('chmod is unavailable');
                return;
              }
              try {
                final result = _expectFailure(
                  await _execute(['--skill', root.path]),
                  exitCode: 1,
                  phase: MambaExecutionPhase.run,
                );
                expect(() => jsonDecode(result.message), throwsFormatException);
              } finally {
                await Process.run('chmod', ['700', root.path]);
              }
            });
          },
        );

        test('valid report uses stdout and status zero', () async {
          await _withSkill((skill) async {
            final result = await _runProduction(skill.parent, [
              'skill',
              'validate',
              '--skill',
              skill.path,
            ]);
            expect(
              result.exitCode,
              0,
              reason: 'stdout=${result.stdout} stderr=${result.stderr}',
            );
            expect(result.stderr, isEmpty);
            final report = _decodeObject(result.stdout);
            expect(report['valid'], isTrue);
          }, marker: _marker());
        });

        test('invalid report uses stderr and status two', () async {
          await _withSkill((skill) async {
            final result = await _runProduction(skill.parent, [
              'skill',
              'validate',
              '--skill',
              skill.path,
            ]);
            expect(result.exitCode, 2);
            expect(result.stdout, isEmpty);
            final report = _decodeObject(result.stderr);
            expect(report['valid'], isFalse);
          }, marker: _marker(name: ''));
        });

        test('operational failure uses text stderr and status one', () async {
          await _withRoot((root) async {
            final result = await _runProduction(root, [
              'skill',
              'validate',
              '--skill',
              p.join(root.path, 'missing'),
            ]);
            expect(result.exitCode, 1);
            expect(result.stdout, isEmpty);
            expect(result.stderr, isNotEmpty);
            expect(() => jsonDecode(result.stderr), throwsFormatException);
          });
        });
      });
    });
  });
}
