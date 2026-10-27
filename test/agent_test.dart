import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/agent_resource.dart';
import 'package:crypto/crypto.dart';
import 'package:mamba/executor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/process_test_support.dart';

const _definitionSizeLimit = 1048576; // 1 MiB
const _frontmatterSizeLimit = 65536; // 64 KiB
const _requestSizeLimit = 8388608; // 8 MiB

const _claudeProfile = 'claude-agent-native-v1';
const _codexProfile = 'codex-agent-native-v1';
const _piProfile = 'pi-agent-common-v1';

const _piTools = 'read, grep, find, ls';
const _model = 'kimi-coding/k3';

const _sentinel = 'SENTINEL-INSTRUCTION-7f3b9a keep me private.';
const _claudeBody =
    '$_sentinel\nLine two keeps trailing spaces   \nFinal line.\n';
const _codexSentinel = 'SENTINEL-CODEX-1c4d8e keep me private.';
const _piSentinel = 'SENTINEL-PI-5b2f70 keep me private.';
const _boundSentinel = 'SENTINEL-BOUND-9a06c3 keep me private.';
const _decoySentinel = 'SENTINEL-DECOY-4e71b8 never selected.';
const _secretToken = 'SECRET-TOKEN-9z41';
const _secretUnknown = 'SECRET-UNKNOWN-VALUE-6d02';
const _bundledSecret = 'SECRET-BUNDLED-8f24 never reported.';
const _ambientClaudeSentinel = 'SENTINEL-AMBIENT-CLAUDE-61c0 never read.';
const _ambientCodexSentinel = 'SENTINEL-AMBIENT-CODEX-a255 never read.';
const _ambientPiSentinel = 'SENTINEL-AMBIENT-PI-d38e never read.';
const _ambientHomeSentinel = 'SENTINEL-AMBIENT-HOME-e7a1 never read.';

late final String _entrypoint;
late final String _packageConfig;

String _absoluteLexical(String value) =>
    p.normalize(Directory(value).absolute.path);

// ---------------------------------------------------------------------------
// Fixture builders
// ---------------------------------------------------------------------------

String _claudeDefinition({
  String? name = 'reviewer',
  String? description = 'Reviews code.',
  String extra = '',
  String body = _claudeBody,
}) {
  final buffer = StringBuffer('---\n');
  if (name != null) buffer.write('name: $name\n');
  if (description != null) buffer.write('description: $description\n');
  buffer.write(extra);
  buffer.write('---\n');
  buffer.write(body);
  return buffer.toString();
}

String _piDefinition({
  String? name = 'worker',
  String? description = 'Works on tasks.',
  String? model = _model,
  String? tools = _piTools,
  String extra = '',
  String body = '$_piSentinel\n',
}) {
  final buffer = StringBuffer('---\n');
  if (name != null) buffer.write('name: $name\n');
  if (description != null) buffer.write('description: $description\n');
  if (model != null) buffer.write('model: $model\n');
  if (tools != null) buffer.write('tools: $tools\n');
  buffer.write(extra);
  buffer.write('---\n');
  buffer.write(body);
  return buffer.toString();
}

String _codexDefinition({
  String? name = 'reviewer',
  String? description = 'Reviews code.',
  String? instructions = _codexSentinel,
  String extra = '',
}) {
  final buffer = StringBuffer();
  if (name != null) buffer.write('name = "$name"\n');
  if (description != null) buffer.write('description = "$description"\n');
  if (instructions != null) {
    buffer.write('developer_instructions = "$instructions"\n');
  }
  buffer.write(extra);
  return buffer.toString();
}

const _boundConfig = '''
[agents.reviewer]
description = "Reviews code from the declaration."
config_file = "agents/reviewer.toml"
''';

const _boundRole =
    '''
description = "Reviews code from the file."
developer_instructions = "$_boundSentinel"
''';

File _write(Directory sandbox, String relativePath, String content) {
  final file = File(p.join(sandbox.path, relativePath));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
  return file;
}

File _writeBytes(Directory sandbox, String relativePath, List<int> bytes) {
  final file = File(p.join(sandbox.path, relativePath));
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes);
  return file;
}

({File config, File role}) _writeBound(
  Directory sandbox, {
  String configToml = _boundConfig,
  String roleToml = _boundRole,
}) {
  return (
    config: _write(sandbox, p.join('.codex', 'config.toml'), configToml),
    role: _write(
      sandbox,
      p.join('.codex', 'agents', 'reviewer.toml'),
      roleToml,
    ),
  );
}

String _requestEnvelope({
  String operation = 'inspect',
  Object? schemaVersion = 1,
  String kind = 'codex-role',
  String configFile = '.codex/config.toml',
  String roleKey = 'reviewer',
  Object? workingDirectory = './',
  Map<String, Object?> extraEnvelope = const {},
}) {
  final envelope = <String, Object?>{
    'schemaVersion': schemaVersion,
    'operation': operation,
    'source': <String, Object?>{
      'kind': kind,
      'configFile': configFile,
      'roleKey': roleKey,
    },
    'context': <String, Object?>{'workingDirectory': workingDirectory},
    ...extraEnvelope,
  };
  return jsonEncode(envelope);
}

File _writeRequest(Directory sandbox, {String? raw, String? operation}) =>
    _write(
      sandbox,
      'request.json',
      raw ?? _requestEnvelope(operation: operation ?? 'inspect'),
    );

/// A valid Claude definition whose frontmatter content (the bytes between the
/// standalone delimiter lines) is exactly [bytes] bytes long.
String _claudeWithFrontmatterBytes(int bytes) {
  const header = 'name: sized\ndescription: sized\n#';
  final filler = bytes - utf8.encode(header).length - 1;
  if (filler < 0) throw ArgumentError.value(bytes, 'bytes');
  return '---\n$header${'x' * filler}\n---\nBody.\n';
}

/// A valid Claude definition whose total file size is exactly [bytes].
List<int> _definitionBytes(int bytes, {bool multibyte = false}) {
  final prefix = utf8.encode(_claudeDefinition(body: ''));
  final filler = bytes - prefix.length;
  if (filler < 0) throw ArgumentError.value(bytes, 'bytes');
  final result = <int>[...prefix];
  if (multibyte) {
    for (var i = 0; i < filler ~/ 2; i++) {
      result.addAll(const [0xC3, 0xA9]); // é
    }
    if (filler.isOdd) result.add(0x78);
  } else {
    result.addAll(List<int>.filled(filler, 0x78));
  }
  return result;
}

// ---------------------------------------------------------------------------
// Sandbox and snapshot helpers
// ---------------------------------------------------------------------------

Future<T> _withSandbox<T>(Future<T> Function(Directory sandbox) body) async {
  final sandbox = await Directory.systemTemp.createTemp(
    'agent-resource-agent-',
  );
  try {
    return await body(sandbox);
  } finally {
    await sandbox.delete(recursive: true);
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

// ---------------------------------------------------------------------------
// Execution and report helpers
// ---------------------------------------------------------------------------

Future<MambaExecutionResult> _execute(
  List<String> arguments, {
  Executor? executor,
}) => (executor ?? createExecutor()).fake().execute(['agent', ...arguments]);

Future<MambaExecutionResult> _inspect(
  List<String> arguments, {
  Executor? executor,
}) => _execute(['inspect', ...arguments], executor: executor);

Future<MambaExecutionResult> _validate(
  List<String> arguments, {
  Executor? executor,
}) => _execute(['validate', ...arguments], executor: executor);

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
  MambaExecutionPhase? phase,
  String? leaf,
}) {
  expect(
    result,
    isA<MambaFailureResult>()
        .having((value) => value.exitCode, 'exit code', exitCode)
        .having((value) => value.message, 'message', isNotEmpty)
        .having((value) => value.output, 'output', isNull),
  );
  final failure = result as MambaFailureResult;
  if (phase != null) {
    expect(failure.error.phase, phase);
  }
  if (leaf != null) {
    expect(failure.error.commandPath, ['agent_resource', 'agent', leaf]);
  }
  return failure;
}

Map<String, Object?> _decodeObject(String text) {
  final decoded = jsonDecode(text);
  expect(decoded, isA<Map<Object?, Object?>>());
  return Map<String, Object?>.from(decoded as Map<Object?, Object?>);
}

Map<String, Object?> _dataOf(Map<String, Object?> report) =>
    Map<String, Object?>.from(report['data']! as Map<Object?, Object?>);

void _expectNotJson(String text) {
  expect(() => jsonDecode(text), throwsFormatException);
}

void _expectEnvelope(
  Map<String, Object?> report, {
  required String command,
  required String outcome,
}) {
  expect(report.keys.toSet(), {
    'schemaVersion',
    'command',
    'outcome',
    'data',
    'diagnostics',
  });
  expect(report['schemaVersion'], 1);
  expect(report['command'], command);
  expect(report['outcome'], outcome);
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
    expect(diagnostic['code'], allOf(isA<String>(), isNotEmpty));
    expect(diagnostic['message'], allOf(isA<String>(), isNotEmpty));
  }

  final data = _dataOf(report);
  expect(data.keys.toSet(), {
    'form',
    'profile',
    'evidence',
    'source',
    'identity',
    'validation',
    'instructions',
    'references',
    'capabilities',
    'parentRequirements',
    if (command == 'agent inspect') 'graph',
    'ready',
  });
  expect(data['form'], allOf(isA<String>(), isNotEmpty));
  expect(data['ready'], isA<bool>());
  final validation = Map<String, Object?>.from(
    data['validation']! as Map<Object?, Object?>,
  );
  expect(validation['status'], anyOf('passed', 'failed', 'incomplete'));
}

void _expectReady(Map<String, Object?> report, {required bool ready}) {
  final data = _dataOf(report);
  final validation = Map<String, Object?>.from(
    data['validation']! as Map<Object?, Object?>,
  );
  expect(data['ready'], ready);
  expect(validation['status'], ready ? 'passed' : 'failed');
}

bool _hasStringValue(Object? node, String needle) {
  if (node is String) return node == needle;
  if (node is Map) {
    return node.values.any((value) => _hasStringValue(value, needle));
  }
  if (node is List) {
    return node.any((value) => _hasStringValue(value, needle));
  }
  return false;
}

List<Map<String, Object?>> _diagnostics(Map<String, Object?> report) =>
    (report['diagnostics']! as List<Object?>)
        .cast<Map<Object?, Object?>>()
        .map((value) => Map<String, Object?>.from(value))
        .toList();

bool _containsToken(String text, String token) =>
    RegExp(r'(?<![A-Za-z0-9_-])' + RegExp.escape(token) + r'(?![A-Za-z0-9_-])')
        .hasMatch(text);

bool _containsCommandEntry(String help, String command) {
  final entry = RegExp('^${RegExp.escape(command)}(?:\\s|\$)');
  return help
      .split(RegExp(r'\r?\n'))
      .any((line) => entry.hasMatch(line.trim()));
}

String _sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();

// ---------------------------------------------------------------------------
// Production process helpers
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

void main() {
  final projectRoot = _findProjectRoot();
  _entrypoint = p.join(projectRoot, 'bin', 'agent_resource.dart');
  _packageConfig = p.join(projectRoot, '.dart_tool', 'package_config.json');

  group('agent_resource', () {
    group('agent', () {
      group('command tree and help', () {
        test('root help lists skill and agent but no leaf aliases', () async {
          for (final arguments in [
            const <String>[],
            const ['--help'],
          ]) {
            final result = _expectSuccess(
              await createExecutor().fake().execute(arguments),
            );
            final output = result.output!;
            expect(_containsCommandEntry(output, 'skill'), isTrue);
            expect(_containsCommandEntry(output, 'agent'), isTrue);
            for (final leaf in ['inspect', 'validate', 'discover']) {
              expect(
                _containsCommandEntry(output, leaf),
                isFalse,
                reason: leaf,
              );
            }
          }
        });

        test('root rejects bare inspect and validate leaves', () async {
          for (final leaf in ['inspect', 'validate']) {
            final result = await createExecutor().fake().execute([leaf]);
            expect(result, isA<MambaFailureResult>());
            expect((result as MambaFailureResult).output, isNull);
          }
        });

        test('bare agent group and agent --help list both leaves', () async {
          for (final arguments in [
            const <String>[],
            const ['--help'],
          ]) {
            final result = _expectSuccess(await _execute(arguments));
            for (final leaf in ['inspect', 'validate']) {
              expect(
                _containsCommandEntry(result.output!, leaf),
                isTrue,
                reason: leaf,
              );
            }
          }
        });

        test('inspect help documents the full explicit contract', () async {
          final result = _expectSuccess(await _inspect(const ['--help']));
          final output = result.output!;
          for (final token in [
            '--harness',
            '--request',
            '--format',
            '--cwd',
            '--show-instructions',
          ]) {
            expect(_containsToken(output, token), isTrue, reason: token);
          }
          for (final harness in ['claude', 'codex', 'pi']) {
            expect(output, contains(harness));
          }
        });

        test(
          'validate help omits show-instructions and the flag is rejected',
          () async {
            final help = _expectSuccess(await _validate(const ['--help']));
            final output = help.output!;
            for (final token in [
              '--harness',
              '--request',
              '--format',
              '--cwd',
            ]) {
              expect(_containsToken(output, token), isTrue, reason: token);
            }
            expect(_containsToken(output, '--show-instructions'), isFalse);

            await _withSandbox((sandbox) async {
              final file = _write(sandbox, 'agent.md', _claudeDefinition());
              final result = await _validate([
                file.path,
                '--harness',
                'claude',
                '--show-instructions',
              ]);
              expect(result, isA<MambaFailureResult>());
              expect((result as MambaFailureResult).output, isNull);
            });
          },
        );

        test('parser rejections name the offending input', () async {
          await _withSandbox((sandbox) async {
            final file = _write(sandbox, 'agent.md', _claudeDefinition());
            final cases = <({List<String> arguments, String token})>[
              (
                arguments: [file.path, '--harness', 'claude', 'extra'],
                token: 'extra',
              ),
              (
                arguments: [file.path, '--harness', 'claude', '--bogus'],
                token: '--bogus',
              ),
              (
                arguments: [file.path, '--harness', 'claude', '--format'],
                token: '--format',
              ),
            ];
            for (final testCase in cases) {
              final result = _expectFailure(
                await _inspect(testCase.arguments),
                exitCode: isNonZero,
                phase: MambaExecutionPhase.parse,
              );
              expect(
                result.message,
                contains(testCase.token),
                reason: testCase.token,
              );
            }
          });
        });

        test('an unsupported format value fails without output', () async {
          await _withSandbox((sandbox) async {
            final file = _write(sandbox, 'agent.md', _claudeDefinition());
            final result = _expectFailure(
              await _validate([
                file.path,
                '--harness',
                'claude',
                '--format',
                'yaml',
              ]),
              exitCode: isNonZero,
            );
            expect(result.output, isNull);
          });
        });
      });

      group('source selection', () {
        test('a native positional requires an explicit harness', () async {
          await _withSandbox((sandbox) async {
            final file = _write(sandbox, 'agent.md', _claudeDefinition());
            final result = _expectFailure(
              await _inspect([file.path]),
              exitCode: 1,
              phase: MambaExecutionPhase.run,
              leaf: 'inspect',
            );
            expect(result.message.toLowerCase(), contains('harness'));
          });
        });

        test('an unknown harness is rejected before inspection', () async {
          await _withSandbox((sandbox) async {
            final file = _write(sandbox, 'agent.md', _claudeDefinition());
            final result = _expectFailure(
              await _inspect([file.path, '--harness', 'bogus']),
              exitCode: isNonZero,
            );
            expect(result.output, isNull);
            expect(result.message, contains('--harness'));
          });
        });

        test('blank application values fail', () async {
          await _withSandbox((sandbox) async {
            final file = _write(sandbox, 'agent.md', _claudeDefinition());
            final cases = <List<String>>[
              ['', '--harness', 'claude'],
              [file.path, '--harness', 'claude', '--cwd', ''],
              const ['--request', ''],
            ];
            for (final arguments in cases) {
              _expectFailure(
                await _inspect(arguments),
                exitCode: 1,
                leaf: 'inspect',
              );
            }
          });
        });

        test('missing source selection fails with status one', () async {
          for (final leaf in ['inspect', 'validate']) {
            _expectFailure(
              await _execute([leaf]),
              exitCode: 1,
              phase: MambaExecutionPhase.run,
              leaf: leaf,
            );
          }
        });

        test('source and request are mutually exclusive', () async {
          await _withSandbox((sandbox) async {
            _writeBound(sandbox);
            final file = _write(sandbox, 'agent.md', _claudeDefinition());
            final request = _writeRequest(sandbox);
            final result = _expectFailure(
              await _inspect([
                file.path,
                '--harness',
                'claude',
                '--request',
                request.path,
              ]),
              exitCode: 1,
              phase: MambaExecutionPhase.run,
              leaf: 'inspect',
            );
            expect(result.message.toLowerCase(), contains('request'));
          });
        });

        test(
          'missing and directory native selections fail with status one',
          () async {
            await _withSandbox((sandbox) async {
              final missing = _expectFailure(
                await _validate([
                  p.join(sandbox.path, 'missing.md'),
                  '--harness',
                  'claude',
                ]),
                exitCode: 1,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
              _expectNotJson(missing.message);

              final directory = Directory(p.join(sandbox.path, 'directory.md'))
                ..createSync();
              _expectFailure(
                await _validate([directory.path, '--harness', 'claude']),
                exitCode: 1,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
            });
          },
        );

        test(
          'relative native paths resolve against the explicit cwd',
          () async {
            await _withSandbox((sandbox) async {
              _write(sandbox, 'agent.md', _claudeDefinition());
              final cwd = '${sandbox.path}${Platform.pathSeparator}';
              final result = _expectSuccess(
                await _inspect([
                  'agent.md',
                  '--harness',
                  'claude',
                  '--cwd',
                  cwd,
                  '--format',
                  'json',
                ]),
              );
              final report = _decodeObject(result.output!);
              _expectEnvelope(
                report,
                command: 'agent inspect',
                outcome: 'inspected',
              );
              expect(
                _hasStringValue(
                  report,
                  _absoluteLexical(p.join(sandbox.path, 'agent.md')),
                ),
                isTrue,
                reason: 'report records the normalized absolute source path',
              );
            });
          },
        );

        test(
          'direct inspection never scans ambient home or harness trees',
          () async {
            await _withSandbox((sandbox) async {
              final selected = _write(
                sandbox,
                'selected.md',
                _claudeDefinition(),
              );
              final decoys = <({File file, String sentinel})>[
                (
                  file: _write(
                    sandbox,
                    p.join('.claude', 'agents', 'decoy.md'),
                    '---\nname: [unterminated\n---\n$_ambientClaudeSentinel\n',
                  ),
                  sentinel: _ambientClaudeSentinel,
                ),
                (
                  file: _write(
                    sandbox,
                    p.join('.codex', 'agents', 'decoy.toml'),
                    'name = "unterminated\n$_ambientCodexSentinel\n',
                  ),
                  sentinel: _ambientCodexSentinel,
                ),
                (
                  file: _write(
                    sandbox,
                    p.join('.pi', 'agent', 'decoy.md'),
                    '# not a definition\n$_ambientPiSentinel\n',
                  ),
                  sentinel: _ambientPiSentinel,
                ),
                (
                  file: _write(
                    sandbox,
                    p.join('home', '.claude', 'agents', 'decoy.md'),
                    _claudeDefinition(
                      name: null,
                      body: '$_ambientHomeSentinel\n',
                    ),
                  ),
                  sentinel: _ambientHomeSentinel,
                ),
              ];

              final result = _expectSuccess(
                await _inspect([
                  selected.path,
                  '--harness',
                  'claude',
                  '--cwd',
                  '${sandbox.path}${Platform.pathSeparator}',
                  '--format',
                  'json',
                  '--show-instructions',
                ]),
              );
              final report = _decodeObject(result.output!);
              _expectEnvelope(
                report,
                command: 'agent inspect',
                outcome: 'inspected',
              );
              _expectReady(report, ready: true);
              expect(
                _hasStringValue(report, _absoluteLexical(selected.path)),
                isTrue,
                reason: 'report records the selected definition path',
              );
              final output = jsonEncode(report);
              for (final decoy in decoys) {
                expect(
                  _hasStringValue(report, _absoluteLexical(decoy.file.path)),
                  isFalse,
                  reason:
                      'ambient decoy path ${decoy.file.path} is never '
                      'recorded',
                );
                expect(
                  output,
                  isNot(contains(decoy.sentinel)),
                  reason: 'ambient decoy content is never read',
                );
              }
            });
          },
        );
      });

      group('delivery and privacy', () {
        test('text is the default format for inspect and validate', () async {
          await _withSandbox((sandbox) async {
            final file = _write(sandbox, 'agent.md', _claudeDefinition());
            for (final arguments in [
              [file.path, '--harness', 'claude'],
              [file.path, '--harness', 'claude', '--format', 'text'],
            ]) {
              final inspect = _expectSuccess(await _inspect(arguments));
              _expectNotJson(inspect.output!);
              expect(inspect.output, contains('reviewer'));
              expect(inspect.output, contains(_claudeProfile));

              final validate = _expectSuccess(await _validate(arguments));
              _expectNotJson(validate.output!);
              expect(validate.output, contains(_claudeProfile));
            }
          });
        });

        test(
          'json inspect emits the exact versioned success envelope',
          () async {
            await _withSandbox((sandbox) async {
              final file = _write(sandbox, 'agent.md', _claudeDefinition());
              final result = _expectSuccess(
                await _inspect([
                  file.path,
                  '--harness',
                  'claude',
                  '--format',
                  'json',
                ]),
              );
              final report = _decodeObject(result.output!);
              _expectEnvelope(
                report,
                command: 'agent inspect',
                outcome: 'inspected',
              );
              expect(_dataOf(report)['profile'], _claudeProfile);
              _expectReady(report, ready: true);
            });
          },
        );

        test(
          'json validate emits the exact versioned success envelope',
          () async {
            await _withSandbox((sandbox) async {
              final file = _write(sandbox, 'agent.md', _claudeDefinition());
              final result = _expectSuccess(
                await _validate([
                  file.path,
                  '--harness',
                  'claude',
                  '--format',
                  'json',
                ]),
              );
              final report = _decodeObject(result.output!);
              _expectEnvelope(
                report,
                command: 'agent validate',
                outcome: 'validated',
              );
              expect(_dataOf(report)['profile'], _claudeProfile);
              _expectReady(report, ready: true);
            });
          },
        );

        test('inspect succeeds for a failed candidate with ready false while '
            'validate fails with status two and no JSON', () async {
          await _withSandbox((sandbox) async {
            final file = _write(
              sandbox,
              'agent.md',
              _claudeDefinition(name: null),
            );

            final inspect = _expectSuccess(
              await _inspect([
                file.path,
                '--harness',
                'claude',
                '--format',
                'json',
              ]),
            );
            final report = _decodeObject(inspect.output!);
            _expectEnvelope(
              report,
              command: 'agent inspect',
              outcome: 'inspected',
            );
            _expectReady(report, ready: false);
            expect(_diagnostics(report), isNotEmpty);

            for (final format in [
              const <String>[],
              const ['--format', 'json'],
            ]) {
              final validate = _expectFailure(
                await _validate([file.path, '--harness', 'claude', ...format]),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
              _expectNotJson(validate.message);
            }
          });
        });

        test(
          'default reports omit instruction bodies but include hashes',
          () async {
            await _withSandbox((sandbox) async {
              final claude = _write(sandbox, 'agent.md', _claudeDefinition());
              final codex = _write(sandbox, 'agent.toml', _codexDefinition());

              final claudeReport = _decodeObject(
                _expectSuccess(
                  await _inspect([
                    claude.path,
                    '--harness',
                    'claude',
                    '--format',
                    'json',
                  ]),
                ).output!,
              );
              final claudeJson = jsonEncode(claudeReport);
              expect(claudeJson, isNot(contains(_sentinel)));
              expect(
                claudeJson,
                contains(_sha256Hex(_claudeBody)),
                reason: 'default report includes the instruction SHA-256',
              );

              final codexReport = _decodeObject(
                _expectSuccess(
                  await _validate([
                    codex.path,
                    '--harness',
                    'codex',
                    '--format',
                    'json',
                  ]),
                ).output!,
              );
              expect(jsonEncode(codexReport), isNot(contains(_codexSentinel)));
            });
          },
        );

        test(
          'inspect --show-instructions prints the exact preserved text',
          () async {
            await _withSandbox((sandbox) async {
              final file = _write(sandbox, 'agent.md', _claudeDefinition());
              final result = _expectSuccess(
                await _inspect([
                  file.path,
                  '--harness',
                  'claude',
                  '--show-instructions',
                ]),
              );
              expect(
                result.output,
                contains(_claudeBody),
                reason: 'exact text including trailing spaces and line endings',
              );
            });
          },
        );

        test(
          'unknown and sensitive declarations are never dumped by default',
          () async {
            await _withSandbox((sandbox) async {
              final file = _write(
                sandbox,
                'agent.md',
                _claudeDefinition(
                  extra:
                      'mcpServers:\n'
                      '  - name: private\n'
                      '    token: $_secretToken\n'
                      'hooks:\n'
                      '  PreToolUse:\n'
                      '    command: touch pwned-marker\n'
                      'x-unknown-field: $_secretUnknown\n',
                ),
              );
              final marker = File(p.join(sandbox.path, 'pwned-marker'));

              for (final leaf in ['inspect', 'validate']) {
                final result = _expectSuccess(
                  await _execute([
                    leaf,
                    file.path,
                    '--harness',
                    'claude',
                    '--format',
                    'json',
                  ]),
                );
                final output = result.output!;
                expect(output, isNot(contains(_secretToken)));
                expect(output, isNot(contains(_secretUnknown)));
                expect(
                  marker.existsSync(),
                  isFalse,
                  reason: 'hook declarations never execute',
                );
                final report = _decodeObject(output);
                _expectEnvelope(
                  report,
                  command: 'agent $leaf',
                  outcome: leaf == 'inspect' ? 'inspected' : 'validated',
                );
                // Unknown fields stay advisory: the candidate remains ready.
                _expectReady(report, ready: true);
                expect(_dataOf(report)['capabilities'], isNotNull);
                expect(_dataOf(report)['references'], isNotNull);
                expect(_dataOf(report)['parentRequirements'], isNotNull);
              }
            });
          },
        );

        test(
          'reused adapters retain no reports, diagnostics, or instructions',
          () async {
            await _withSandbox((sandbox) async {
              final file = _write(sandbox, 'agent.md', _claudeDefinition());
              final adapter = createExecutor().fake();

              final first = _expectSuccess(
                await adapter.execute([
                  'agent',
                  'inspect',
                  file.path,
                  '--harness',
                  'claude',
                  '--show-instructions',
                ]),
              );
              expect(first.output, contains(_sentinel));

              const replacement = 'SENTINEL-REPLACEMENT-2e5a91.\n';
              file.writeAsStringSync(
                _claudeDefinition(name: null, body: replacement),
              );
              final second = _decodeObject(
                _expectSuccess(
                  await adapter.execute([
                    'agent',
                    'inspect',
                    file.path,
                    '--harness',
                    'claude',
                    '--format',
                    'json',
                    '--show-instructions',
                  ]),
                ).output!,
              );
              _expectReady(second, ready: false);
              final secondJson = jsonEncode(second);
              expect(secondJson, contains('SENTINEL-REPLACEMENT-2e5a91'));
              expect(secondJson, isNot(contains(_sentinel)));

              file.writeAsStringSync(_claudeDefinition());
              final third = _decodeObject(
                _expectSuccess(
                  await adapter.execute([
                    'agent',
                    'validate',
                    file.path,
                    '--harness',
                    'claude',
                    '--format',
                    'json',
                  ]),
                ).output!,
              );
              _expectReady(third, ready: true);
              expect(_diagnostics(third), isEmpty);
            });
          },
        );
      });

      group('claude native form', () {
        test(
          'minimal and full definitions pass with both tools forms',
          () async {
            await _withSandbox((sandbox) async {
              final minimal = _write(
                sandbox,
                'minimal.md',
                _claudeDefinition(),
              );
              final full = _write(
                sandbox,
                'full.md',
                _claudeDefinition(
                  extra:
                      'tools: $_piTools\n'
                      'model: $_model\n'
                      'permissionMode: acceptEdits\n'
                      'maxTurns: 5\n'
                      'skills:\n'
                      '  - code-review\n',
                ),
              );
              final listTools = _write(
                sandbox,
                'list.md',
                _claudeDefinition(
                  extra: 'tools:\n  - read\n  - grep\n  - find\n  - ls\n',
                ),
              );
              for (final file in [minimal, full, listTools]) {
                final result = _expectSuccess(
                  await _validate([
                    file.path,
                    '--harness',
                    'claude',
                    '--format',
                    'json',
                  ]),
                );
                final report = _decodeObject(result.output!);
                _expectEnvelope(
                  report,
                  command: 'agent validate',
                  outcome: 'validated',
                );
                _expectReady(report, ready: true);
              }
            });
          },
        );

        test('empty description remains permitted', () async {
          await _withSandbox((sandbox) async {
            final file = _write(
              sandbox,
              'agent.md',
              _claudeDefinition(description: '""'),
            );
            _expectSuccess(await _validate([file.path, '--harness', 'claude']));
          });
        });

        test(
          'CRLF definitions are accepted and preserve the exact CRLF body',
          () async {
            await _withSandbox((sandbox) async {
              const crlfBody =
                  'First line.\r\nSecond line keeps trailing spaces   \r\n';
              final file = _write(
                sandbox,
                'crlf.md',
                '---\r\n'
                    'name: reviewer\r\n'
                    'description: Reviews code.\r\n'
                    '---\r\n'
                    '$crlfBody',
              );

              final valid = _expectSuccess(
                await _validate([
                  file.path,
                  '--harness',
                  'claude',
                  '--format',
                  'json',
                ]),
              );
              _expectReady(_decodeObject(valid.output!), ready: true);

              final shown = _decodeObject(
                _expectSuccess(
                  await _inspect([
                    file.path,
                    '--harness',
                    'claude',
                    '--format',
                    'json',
                    '--show-instructions',
                  ]),
                ).output!,
              );
              final instructions = Map<String, Object?>.from(
                _dataOf(shown)['instructions']! as Map<Object?, Object?>,
              );
              expect(instructions['text'], crlfBody);
              expect(instructions['sha256'], _sha256Hex(crlfBody));
              expect(
                instructions['sha256'],
                isNot(_sha256Hex(crlfBody.replaceAll('\r\n', '\n'))),
                reason:
                    'the hash covers the preserved CRLF body, not an LF '
                    'rewrite',
              );

              final text = _expectSuccess(
                await _inspect([
                  file.path,
                  '--harness',
                  'claude',
                  '--show-instructions',
                ]),
              );
              expect(
                text.output,
                contains(crlfBody),
                reason: 'exact text including CRLF endings and trailing spaces',
              );
            });
          },
        );

        test('name boundaries: 256 scalars pass, 257, colon, and leading hyphen fail', () async {
          await _withSandbox((sandbox) async {
            final accepted = _write(
              sandbox,
              'accepted.md',
              _claudeDefinition(name: 'a' * 256),
            );
            _expectSuccess(
              await _validate([accepted.path, '--harness', 'claude']),
            );

            final rejected = <String>['a' * 257, '"bad:name"', '"-bad"'];
            for (var i = 0; i < rejected.length; i++) {
              final file = _write(
                sandbox,
                'rejected-$i.md',
                _claudeDefinition(name: rejected[i]),
              );
              _expectFailure(
                await _validate([file.path, '--harness', 'claude']),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
            }
          });
        });

        test('optional enums, types, and ranges are enforced', () async {
          await _withSandbox((sandbox) async {
            final cases = <String>[
              'permissionMode: bogus\n',
              'maxTurns: -1\n',
              'maxTurns: soon\n',
              'autoCompactWindow: 5\n',
            ];
            for (var i = 0; i < cases.length; i++) {
              final file = _write(
                sandbox,
                'case-$i.md',
                _claudeDefinition(extra: cases[i]),
              );
              _expectFailure(
                await _validate([file.path, '--harness', 'claude']),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
            }
          });
        });

        test('malformed YAML, duplicates, aliases, tags, and merge keys are '
            'blocking failures', () async {
          await _withSandbox((sandbox) async {
            final bodies = <String>[
              '---\nname: [unterminated\ndescription: x\n---\n',
              '---\nname: a\nname: b\ndescription: x\n---\n',
              '---\nname: &anchor a\ndescription: *anchor\n---\n',
              '---\nname: !!custom a\ndescription: x\n---\n',
              '---\nbase: &b\n  k: v\nname:\n  <<: *b\ndescription: x\n---\n',
              '---\n- item\n---\n',
              '# no frontmatter at all\n',
            ];
            for (var i = 0; i < bodies.length; i++) {
              final file = _write(sandbox, 'malformed-$i.md', bodies[i]);
              _expectFailure(
                await _validate([file.path, '--harness', 'claude']),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
            }
          });
        });

        test('unknown fields are advisory and never blocking', () async {
          await _withSandbox((sandbox) async {
            final file = _write(
              sandbox,
              'agent.md',
              _claudeDefinition(extra: 'zzz: later\naaa: first\n'),
            );
            final report = _decodeObject(
              _expectSuccess(
                await _validate([
                  file.path,
                  '--harness',
                  'claude',
                  '--format',
                  'json',
                ]),
              ).output!,
            );
            _expectReady(report, ready: true);
            expect(_diagnostics(report), isNotEmpty);
          });
        });
      });

      group('codex standalone form', () {
        test(
          'minimal and full definitions pass with trimmed identity',
          () async {
            await _withSandbox((sandbox) async {
              final minimal = _write(
                sandbox,
                'minimal.toml',
                _codexDefinition(),
              );
              final full = _write(
                sandbox,
                'full.toml',
                _codexDefinition(
                  name: '  reviewer  ',
                  extra:
                      'model = "$_model"\n'
                      'model_reasoning_effort = "high"\n',
                ),
              );
              for (final file in [minimal, full]) {
                final report = _decodeObject(
                  _expectSuccess(
                    await _validate([
                      file.path,
                      '--harness',
                      'codex',
                      '--format',
                      'json',
                    ]),
                  ).output!,
                );
                _expectEnvelope(
                  report,
                  command: 'agent validate',
                  outcome: 'validated',
                );
                expect(_dataOf(report)['profile'], _codexProfile);
                _expectReady(report, ready: true);
              }
            });
          },
        );

        test('missing or blank required fields fail validation', () async {
          await _withSandbox((sandbox) async {
            final cases = <String>[
              _codexDefinition(name: null),
              _codexDefinition(description: null),
              _codexDefinition(instructions: null),
              _codexDefinition(name: '""'),
              _codexDefinition(description: '""'),
              _codexDefinition(instructions: ''),
            ];
            for (var i = 0; i < cases.length; i++) {
              final file = _write(sandbox, 'case-$i.toml', cases[i]);
              _expectFailure(
                await _validate([file.path, '--harness', 'codex']),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
            }
          });
        });

        test('malformed TOML and wrong field types fail validation', () async {
          await _withSandbox((sandbox) async {
            final cases = <String>[
              'name = "unterminated\n',
              'name = 7\ndescription = "x"\ndeveloper_instructions = "x"\n',
              'name = "x"\ndescription = "x"\ndeveloper_instructions = ["x"]\n',
            ];
            for (var i = 0; i < cases.length; i++) {
              final file = _write(sandbox, 'malformed-$i.toml', cases[i]);
              _expectFailure(
                await _validate([file.path, '--harness', 'codex']),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
            }
          });
        });

        test('false-only reductions pass while true reductions and '
            'parent-authority fields are blocking', () async {
          await _withSandbox((sandbox) async {
            final reduced = _write(
              sandbox,
              'reduced.toml',
              _codexDefinition(
                extra:
                    '[[skills.config]]\n'
                    'path = "skills/review"\n'
                    'enabled = false\n',
              ),
            );
            _expectSuccess(
              await _validate([reduced.path, '--harness', 'codex']),
            );

            final blocking = <String>[
              '[[skills.config]]\npath = "skills/review"\nenabled = true\n',
              'sandbox_mode = "read-only"\n',
              'approval_policy = "never"\n',
            ];
            for (var i = 0; i < blocking.length; i++) {
              final file = _write(
                sandbox,
                'blocking-$i.toml',
                _codexDefinition(extra: blocking[i]),
              );
              _expectFailure(
                await _validate([file.path, '--harness', 'codex']),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
            }
          });
        });

        test('skills.bundled unknown keys are advisory and never report raw '
            'values', () async {
          await _withSandbox((sandbox) async {
            final file = _write(
              sandbox,
              'agent.toml',
              _codexDefinition(
                extra:
                    '[skills.bundled]\n'
                    'enabled = false\n'
                    'mystery = "$_bundledSecret"\n',
              ),
            );
            final report = _decodeObject(
              _expectSuccess(
                await _validate([
                  file.path,
                  '--harness',
                  'codex',
                  '--format',
                  'json',
                ]),
              ).output!,
            );
            _expectReady(report, ready: true);
            final bundled = _diagnostics(report)
                .where(
                  (diagnostic) =>
                      diagnostic['code'] == 'SKILLS_BUNDLED_UNKNOWN',
                )
                .toList();
            expect(bundled, hasLength(1));
            expect(bundled.single['field'], 'skills.bundled.mystery');
            expect(bundled.single['severity'], 'warning');
            expect(
              jsonEncode(report),
              isNot(contains(_bundledSecret)),
              reason: 'the unknown nested value is not reported',
            );
          });
        });

        test(
          'source-only and unknown fields remain qualified advisories',
          () async {
            await _withSandbox((sandbox) async {
              final file = _write(
                sandbox,
                'agent.toml',
                _codexDefinition(
                  extra:
                      'nickname_candidates = ["Reviewer"]\n'
                      'personality = "friendly"\n'
                      'unknown_field = "value"\n',
                ),
              );
              final report = _decodeObject(
                _expectSuccess(
                  await _validate([
                    file.path,
                    '--harness',
                    'codex',
                    '--format',
                    'json',
                  ]),
                ).output!,
              );
              _expectReady(report, ready: true);
            });
          },
        );
      });

      group('pi common form', () {
        test('the four required fields, qualified model, exact CSV tools, and '
            'optional thinking pass', () async {
          await _withSandbox((sandbox) async {
            final minimal = _write(sandbox, 'minimal.md', _piDefinition());
            final thinking = _write(
              sandbox,
              'thinking.md',
              _piDefinition(extra: 'thinking: high\n'),
            );
            for (final file in [minimal, thinking]) {
              final report = _decodeObject(
                _expectSuccess(
                  await _validate([
                    file.path,
                    '--harness',
                    'pi',
                    '--format',
                    'json',
                  ]),
                ).output!,
              );
              _expectEnvelope(
                report,
                command: 'agent validate',
                outcome: 'validated',
              );
              expect(_dataOf(report)['profile'], _piProfile);
              _expectReady(report, ready: true);
              expect(_diagnostics(report), isEmpty);
            }
          });
        });

        test('missing required fields fail validation', () async {
          await _withSandbox((sandbox) async {
            final cases = <String>[
              _piDefinition(name: null),
              _piDefinition(description: null),
              _piDefinition(model: null),
              _piDefinition(tools: null),
            ];
            for (var i = 0; i < cases.length; i++) {
              final file = _write(sandbox, 'case-$i.md', cases[i]);
              _expectFailure(
                await _validate([file.path, '--harness', 'pi']),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
            }
          });
        });

        test('malformed model declarations fail validation', () async {
          await _withSandbox((sandbox) async {
            final cases = <String>[
              'inherit',
              'kimi-coding',
              '"kimi-coding / k3"',
              '"/k3"',
              '"kimi-coding/"',
            ];
            for (var i = 0; i < cases.length; i++) {
              final file = _write(
                sandbox,
                'model-$i.md',
                _piDefinition(model: cases[i]),
              );
              _expectFailure(
                await _validate([file.path, '--harness', 'pi']),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
            }
          });
        });

        test(
          'flow-list, empty, duplicate, wildcard, and non-catalog tools fail',
          () async {
            await _withSandbox((sandbox) async {
              final flowList = _write(
                sandbox,
                'flow.md',
                _piDefinition(tools: null, extra: 'tools: [read, grep]\n'),
              );
              _expectFailure(
                await _validate([flowList.path, '--harness', 'pi']),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );

              final cases = <String>[
                '""',
                'read, read',
                'read, *',
                'all',
                'read, write',
                'read, mcp:server',
              ];
              for (var i = 0; i < cases.length; i++) {
                final file = _write(
                  sandbox,
                  'tools-$i.md',
                  _piDefinition(tools: cases[i]),
                );
                _expectFailure(
                  await _validate([file.path, '--harness', 'pi']),
                  exitCode: 2,
                  phase: MambaExecutionPhase.run,
                  leaf: 'validate',
                );
              }
            });
          },
        );

        test('colon and whitespace-padded names fail validation', () async {
          await _withSandbox((sandbox) async {
            final cases = <String>['"bad:name"', '" padded"', '"padded "'];
            for (var i = 0; i < cases.length; i++) {
              final file = _write(
                sandbox,
                'name-$i.md',
                _piDefinition(name: cases[i]),
              );
              _expectFailure(
                await _validate([file.path, '--harness', 'pi']),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
            }
          });
        });

        test(
          'provider-only fields are observed without a union schema',
          () async {
            await _withSandbox((sandbox) async {
              final file = _write(
                sandbox,
                'agent.md',
                _piDefinition(extra: 'temperature: 0.5\n'),
              );
              final report = _decodeObject(
                _expectSuccess(
                  await _validate([
                    file.path,
                    '--harness',
                    'pi',
                    '--format',
                    'json',
                  ]),
                ).output!,
              );
              _expectReady(report, ready: true);
            });
          },
        );

        test('listed provider-only fields emit PROVIDER_ONLY_FIELD, never '
            'UNKNOWN_FIELD, and invent no union capabilities', () async {
          await _withSandbox((sandbox) async {
            final baseline = _write(sandbox, 'baseline.md', _piDefinition());
            final file = _write(
              sandbox,
              'agent.md',
              _piDefinition(
                extra:
                    'run_in_background: true\n'
                    'memory: project\n'
                    'skills:\n'
                    '  - code-review\n',
              ),
            );

            Future<String> capabilitiesOf(String path) async {
              final report = _decodeObject(
                _expectSuccess(
                  await _validate([
                    path,
                    '--harness',
                    'pi',
                    '--format',
                    'json',
                  ]),
                ).output!,
              );
              return jsonEncode(_dataOf(report)['capabilities']);
            }

            final report = _decodeObject(
              _expectSuccess(
                await _validate([
                  file.path,
                  '--harness',
                  'pi',
                  '--format',
                  'json',
                ]),
              ).output!,
            );
            _expectReady(report, ready: true);

            final diagnostics = _diagnostics(report);
            for (final field in ['run_in_background', 'memory', 'skills']) {
              final matches = diagnostics
                  .where((diagnostic) => diagnostic['field'] == field)
                  .toList();
              expect(matches, hasLength(1), reason: field);
              expect(
                matches.single['code'],
                'PROVIDER_ONLY_FIELD',
                reason: field,
              );
              expect(matches.single['severity'], 'warning', reason: field);
            }
            expect(
              diagnostics.where(
                (diagnostic) => diagnostic['code'] == 'UNKNOWN_FIELD',
              ),
              isEmpty,
              reason:
                  'listed provider-only fields are not reported as '
                  'unknown fields',
            );
            expect(
              jsonEncode(_dataOf(report)['capabilities']),
              await capabilitiesOf(baseline.path),
              reason: 'provider-only fields invent no union capabilities',
            );
          });
        });
      });

      group('codex config-bound roles', () {
        test(
          'a bound request inspects the selected role with provenance',
          () async {
            await _withSandbox((sandbox) async {
              final bound = _writeBound(sandbox);
              final request = _writeRequest(sandbox);
              final cwd = '${sandbox.path}${Platform.pathSeparator}';
              final report = _decodeObject(
                _expectSuccess(
                  await _inspect([
                    '--request',
                    request.path,
                    '--cwd',
                    cwd,
                    '--format',
                    'json',
                  ]),
                ).output!,
              );
              _expectEnvelope(
                report,
                command: 'agent inspect',
                outcome: 'inspected',
              );
              final data = _dataOf(report);
              expect(data['profile'], _codexProfile);
              _expectReady(report, ready: true);
              expect(
                _hasStringValue(report, _absoluteLexical(bound.config.path)),
                isTrue,
                reason: 'report records the declaring config path',
              );
              expect(
                _hasStringValue(report, _absoluteLexical(bound.role.path)),
                isTrue,
                reason: 'report records the selected definition path',
              );
              expect(jsonEncode(report), isNot(contains(_boundSentinel)));
            });
          },
        );

        test(
          'request paths never resolve against the request file directory',
          () async {
            await _withSandbox((sandbox) async {
              _writeBound(sandbox);
              final request = _write(
                sandbox,
                'requests/bound.json',
                _requestEnvelope(),
              );
              final report = _decodeObject(
                _expectSuccess(
                  await _inspect([
                    '--request',
                    request.path,
                    '--cwd',
                    '${sandbox.path}${Platform.pathSeparator}',
                    '--format',
                    'json',
                  ]),
                ).output!,
              );
              _expectReady(report, ready: true);
            });
          },
        );

        test('request selection rejects an explicit harness', () async {
          await _withSandbox((sandbox) async {
            _writeBound(sandbox);
            final request = _writeRequest(sandbox);
            _expectFailure(
              await _inspect([
                '--request',
                request.path,
                '--cwd',
                '${sandbox.path}${Platform.pathSeparator}',
                '--harness',
                'codex',
              ]),
              exitCode: 1,
              phase: MambaExecutionPhase.run,
              leaf: 'inspect',
            );
          });
        });

        test('a conflicting cwd context fails before inspection', () async {
          await _withSandbox((sandbox) async {
            _writeBound(sandbox);
            final other = Directory(p.join(sandbox.path, 'other'))
              ..createSync();
            final request = _writeRequest(
              sandbox,
              raw: _requestEnvelope(workingDirectory: sandbox.path),
            );
            _expectFailure(
              await _inspect([
                '--request',
                request.path,
                '--cwd',
                '${other.path}${Platform.pathSeparator}',
              ]),
              exitCode: 1,
              phase: MambaExecutionPhase.run,
              leaf: 'inspect',
            );
          });
        });

        test(
          'role-key fallback supplies identity and declaration description',
          () async {
            await _withSandbox((sandbox) async {
              _writeBound(
                sandbox,
                roleToml: 'developer_instructions = "Bound fallback."\n',
              );
              final request = _writeRequest(sandbox, operation: 'validate');
              final report = _decodeObject(
                _expectSuccess(
                  await _validate([
                    '--request',
                    request.path,
                    '--cwd',
                    '${sandbox.path}${Platform.pathSeparator}',
                    '--format',
                    'json',
                  ]),
                ).output!,
              );
              _expectEnvelope(
                report,
                command: 'agent validate',
                outcome: 'validated',
              );
              _expectReady(report, ready: true);
            });
          },
        );

        test('a blank bound declaration description without a file description '
            'fails with ROLE_DESCRIPTION_BLANK', () async {
          await _withSandbox((sandbox) async {
            _writeBound(
              sandbox,
              configToml:
                  '[agents.reviewer]\n'
                  'description = ""\n'
                  'config_file = "agents/reviewer.toml"\n',
              roleToml: 'developer_instructions = "$_boundSentinel"\n',
            );
            final cwd = '${sandbox.path}${Platform.pathSeparator}';

            final inspectRequest = _writeRequest(sandbox);
            final inspected = _decodeObject(
              _expectSuccess(
                await _inspect([
                  '--request',
                  inspectRequest.path,
                  '--cwd',
                  cwd,
                  '--format',
                  'json',
                ]),
              ).output!,
            );
            _expectEnvelope(
              inspected,
              command: 'agent inspect',
              outcome: 'inspected',
            );
            _expectReady(inspected, ready: false);
            final blank = _diagnostics(inspected)
                .where(
                  (diagnostic) =>
                      diagnostic['code'] == 'ROLE_DESCRIPTION_BLANK',
                )
                .toList();
            expect(blank, hasLength(1));
            expect(blank.single['field'], 'agents.reviewer.description');

            final validateRequest = _write(
              sandbox,
              'validate-request.json',
              _requestEnvelope(operation: 'validate'),
            );
            _expectFailure(
              await _validate([
                '--request',
                validateRequest.path,
                '--cwd',
                cwd,
                '--format',
                'json',
              ]),
              exitCode: 2,
              phase: MambaExecutionPhase.run,
              leaf: 'validate',
            );
          });
        });

        test(
          'an equivalent standalone file without name or instructions fails',
          () async {
            await _withSandbox((sandbox) async {
              final file = _write(
                sandbox,
                'standalone.toml',
                'description = "Only a description."\n',
              );
              _expectFailure(
                await _validate([file.path, '--harness', 'codex']),
                exitCode: 2,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
            });
          },
        );

        test(
          'file name disagreement with the role key stays advisory',
          () async {
            await _withSandbox((sandbox) async {
              _writeBound(
                sandbox,
                roleToml:
                    'name = "different-name"\n'
                    'description = "Reviews code."\n'
                    'developer_instructions = "Bound instructions."\n',
              );
              final request = _writeRequest(sandbox);
              final report = _decodeObject(
                _expectSuccess(
                  await _inspect([
                    '--request',
                    request.path,
                    '--cwd',
                    '${sandbox.path}${Platform.pathSeparator}',
                    '--format',
                    'json',
                  ]),
                ).output!,
              );
              _expectReady(report, ready: true);
              expect(_diagnostics(report), isNotEmpty);
            });
          },
        );

        test(
          'a metadata-only declaration retains inherited instruction state',
          () async {
            await _withSandbox((sandbox) async {
              _write(
                sandbox,
                p.join('.codex', 'config.toml'),
                '[agents.reviewer]\ndescription = "Metadata only."\n',
              );
              final request = _writeRequest(sandbox);
              final report = _decodeObject(
                _expectSuccess(
                  await _inspect([
                    '--request',
                    request.path,
                    '--cwd',
                    '${sandbox.path}${Platform.pathSeparator}',
                    '--format',
                    'json',
                  ]),
                ).output!,
              );
              _expectEnvelope(
                report,
                command: 'agent inspect',
                outcome: 'inspected',
              );
              // No definition file exists: nothing may be fabricated.
              expect(jsonEncode(report), isNot(contains(_boundSentinel)));
            });
          },
        );

        test(
          'missing config, role, and referenced definition differ',
          () async {
            await _withSandbox((sandbox) async {
              _writeBound(sandbox);
              final cwd = '${sandbox.path}${Platform.pathSeparator}';

              final missingConfig = _writeRequest(
                sandbox,
                raw: _requestEnvelope(configFile: '.codex/missing.toml'),
              );
              _expectFailure(
                await _inspect(['--request', missingConfig.path, '--cwd', cwd]),
                exitCode: 1,
                phase: MambaExecutionPhase.run,
                leaf: 'inspect',
              );

              final missingRole = _write(
                sandbox,
                'missing-role.json',
                _requestEnvelope(roleKey: 'ghost'),
              );
              _expectFailure(
                await _inspect(['--request', missingRole.path, '--cwd', cwd]),
                exitCode: 1,
                phase: MambaExecutionPhase.run,
                leaf: 'inspect',
              );

              _write(
                sandbox,
                p.join('.codex', 'config.toml'),
                '[agents.reviewer]\n'
                'description = "d"\n'
                'config_file = "agents/missing.toml"\n',
              );
              final missingDefinition = _write(
                sandbox,
                'missing-definition.json',
                _requestEnvelope(),
              );
              _expectFailure(
                await _inspect([
                  '--request',
                  missingDefinition.path,
                  '--cwd',
                  cwd,
                ]),
                exitCode: 3,
                phase: MambaExecutionPhase.run,
                leaf: 'inspect',
              );
            });
          },
        );

        test('a malformed declaring config is incomplete analysis', () async {
          await _withSandbox((sandbox) async {
            _writeBound(sandbox, configToml: '[agents.reviewer\nbroken = ');
            final request = _writeRequest(sandbox);
            _expectFailure(
              await _inspect([
                '--request',
                request.path,
                '--cwd',
                '${sandbox.path}${Platform.pathSeparator}',
              ]),
              exitCode: 3,
              phase: MambaExecutionPhase.run,
              leaf: 'inspect',
            );
          });
        });

        test(
          'bound inspection reads only the selected config and definition',
          () async {
            await _withSandbox((sandbox) async {
              _writeBound(sandbox);
              _write(
                sandbox,
                p.join('.codex', 'agents', 'decoy.toml'),
                'description = "$_decoySentinel"\n',
              );
              final request = _writeRequest(sandbox);
              final report = _decodeObject(
                _expectSuccess(
                  await _inspect([
                    '--request',
                    request.path,
                    '--cwd',
                    '${sandbox.path}${Platform.pathSeparator}',
                    '--format',
                    'json',
                    '--show-instructions',
                  ]),
                ).output!,
              );
              final output = jsonEncode(report);
              expect(output, contains(_boundSentinel));
              expect(output, isNot(contains(_decoySentinel)));
            });
          },
        );

        group('request envelope', () {
          Future<void> expectRequestRejected(
            Directory sandbox,
            String raw, {
            int exitCode = 1,
          }) async {
            _writeBound(sandbox);
            final request = _write(sandbox, 'request.json', raw);
            final result = _expectFailure(
              await _inspect([
                '--request',
                request.path,
                '--cwd',
                '${sandbox.path}${Platform.pathSeparator}',
              ]),
              exitCode: exitCode,
              phase: MambaExecutionPhase.run,
              leaf: 'inspect',
            );
            _expectNotJson(result.message);
          }

          test('malformed JSON is rejected with status one', () async {
            await _withSandbox((sandbox) async {
              await expectRequestRejected(sandbox, '{not json');
            });
          });

          test('duplicate keys are rejected', () async {
            await _withSandbox((sandbox) async {
              await expectRequestRejected(
                sandbox,
                '{"schemaVersion": 1, "schemaVersion": 1, '
                '"operation": "inspect", '
                '"source": {"kind": "codex-role", "configFile": '
                '".codex/config.toml", "roleKey": "reviewer"}, '
                '"context": {"workingDirectory": "./"}}',
              );
            });
          });

          test('unknown envelope fields are rejected', () async {
            await _withSandbox((sandbox) async {
              await expectRequestRejected(
                sandbox,
                _requestEnvelope(extraEnvelope: {'unexpected': true}),
              );
            });
          });

          test('an operation mismatch is rejected', () async {
            await _withSandbox((sandbox) async {
              await expectRequestRejected(
                sandbox,
                _requestEnvelope(operation: 'validate'),
              );
            });
          });

          test('unsupported source kinds are rejected', () async {
            await _withSandbox((sandbox) async {
              await expectRequestRejected(
                sandbox,
                _requestEnvelope(kind: 'claude-file'),
              );
            });
          });

          test('missing working directory context is rejected', () async {
            await _withSandbox((sandbox) async {
              final raw = jsonEncode({
                'schemaVersion': 1,
                'operation': 'inspect',
                'source': {
                  'kind': 'codex-role',
                  'configFile': '.codex/config.toml',
                  'roleKey': 'reviewer',
                },
                'context': <String, Object?>{},
              });
              await expectRequestRejected(sandbox, raw);
            });
          });

          test('blank role keys and schema mismatches are rejected', () async {
            await _withSandbox((sandbox) async {
              await expectRequestRejected(
                sandbox,
                _requestEnvelope(roleKey: ''),
              );
            });
            await _withSandbox((sandbox) async {
              await expectRequestRejected(
                sandbox,
                _requestEnvelope(schemaVersion: 2),
              );
            });
          });

          test('over-depth requests are rejected', () async {
            await _withSandbox((sandbox) async {
              final opening = List<String>.filled(40, '{"a": ').join();
              final closing = List<String>.filled(40, '}').join();
              final nested = '${opening}1$closing';
              await expectRequestRejected(sandbox, nested, exitCode: 3);
            });
          });

          test('over-cap requests are rejected', () async {
            await _withSandbox((sandbox) async {
              final raw = '{"schemaVersion": 1, "operation": "inspect"x'
                  .padRight(_requestSizeLimit + 1, ' ');
              await expectRequestRejected(sandbox, raw, exitCode: 3);
            });
          });
          test(
            'request node budgets are exhausted before schema validation',
            () async {
              await _withSandbox((sandbox) async {
                final nodes = List<String>.filled(100001, 'null').join(',');
                await expectRequestRejected(
                  sandbox,
                  '{"extra":[$nodes]}',
                  exitCode: 3,
                );
              });
            },
          );
        });
      });

      group('bounds and inertness', () {
        test(
          'exactly 1 MiB definitions pass and cap+1 is budget exhaustion',
          () async {
            await _withSandbox((sandbox) async {
              final exact = _writeBytes(
                sandbox,
                'exact.md',
                _definitionBytes(_definitionSizeLimit),
              );
              _expectSuccess(
                await _validate([exact.path, '--harness', 'claude']),
              );

              final exactMultibyte = _writeBytes(
                sandbox,
                'exact-multibyte.md',
                _definitionBytes(_definitionSizeLimit, multibyte: true),
              );
              _expectSuccess(
                await _validate([exactMultibyte.path, '--harness', 'claude']),
              );

              final over = _writeBytes(
                sandbox,
                'over.md',
                _definitionBytes(_definitionSizeLimit + 1),
              );
              final result = _expectFailure(
                await _validate([
                  over.path,
                  '--harness',
                  'claude',
                  '--format',
                  'json',
                ]),
                exitCode: 3,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
              _expectNotJson(result.message);
            });
          },
        );

        test(
          'exactly 64 KiB frontmatter passes and cap+1 is budget exhaustion',
          () async {
            await _withSandbox((sandbox) async {
              final exact = _write(
                sandbox,
                'exact.md',
                _claudeWithFrontmatterBytes(_frontmatterSizeLimit),
              );
              _expectSuccess(
                await _validate([exact.path, '--harness', 'claude']),
              );

              final over = _write(
                sandbox,
                'over.md',
                _claudeWithFrontmatterBytes(_frontmatterSizeLimit + 1),
              );
              _expectFailure(
                await _validate([over.path, '--harness', 'claude']),
                exitCode: 3,
                phase: MambaExecutionPhase.run,
                leaf: 'validate',
              );
            });
          },
        );

        test('invalid UTF-8 fails without replacement decoding', () async {
          await _withSandbox((sandbox) async {
            final file = _writeBytes(sandbox, 'agent.md', <int>[
              0x2D,
              0x2D,
              0x2D,
              0x0A,
              0xFF,
            ]);
            _expectFailure(
              await _validate([file.path, '--harness', 'claude']),
              exitCode: 2,
              phase: MambaExecutionPhase.run,
              leaf: 'validate',
            );
          });
        });

        test('a linked selection is refused with status four without reading '
            'its target', () async {
          await _withSandbox((sandbox) async {
            final target = _write(sandbox, 'target.md', _claudeDefinition());
            final link = p.join(sandbox.path, 'linked.md');
            if (!await _tryCreateLink(link, target.path)) {
              markTestSkipped('file symlink creation is unavailable');
              return;
            }
            _expectFailure(
              await _validate([link, '--harness', 'claude']),
              exitCode: 4,
              phase: MambaExecutionPhase.run,
              leaf: 'validate',
            );
          });
        });

        test('an inaccessible definition is an incomplete read when the host '
            'supports chmod', () async {
          if (Platform.isWindows) {
            markTestSkipped(
              'portable unreadable-file setup is unavailable on Windows',
            );
            return;
          }
          await _withSandbox((sandbox) async {
            final file = _write(sandbox, 'agent.md', _claudeDefinition());
            final changed = await Process.run('chmod', ['000', file.path]);
            if (changed.exitCode != 0) {
              markTestSkipped('chmod is unavailable');
              return;
            }
            try {
              _expectFailure(
                await _inspect([file.path, '--harness', 'claude']),
                exitCode: 3,
                phase: MambaExecutionPhase.run,
                leaf: 'inspect',
              );
            } finally {
              await Process.run('chmod', ['600', file.path]);
            }
          });
        });

        test(
          'success, rejection, and help preserve every sandbox byte',
          () async {
            await _withSandbox((sandbox) async {
              final bound = _writeBound(sandbox);
              final claude = _write(sandbox, 'agent.md', _claudeDefinition());
              final request = _writeRequest(sandbox);
              final sentinel = _write(sandbox, 'sentinel.txt', 'do not change');
              final before = _snapshot(sandbox);

              final cwd = '${sandbox.path}${Platform.pathSeparator}';
              _expectSuccess(
                await _inspect([claude.path, '--harness', 'claude']),
              );
              _expectSuccess(
                await _validate([claude.path, '--harness', 'claude']),
              );
              _expectSuccess(
                await _inspect(['--request', request.path, '--cwd', cwd]),
              );
              claude.writeAsStringSync(_claudeDefinition(name: null));
              _expectFailure(
                await _validate([claude.path, '--harness', 'claude']),
                exitCode: 2,
              );
              _expectSuccess(await _inspect(const ['--help']));
              _expectFailure(
                await _inspect([bound.role.path, '--harness', 'bogus']),
                exitCode: 1,
              );

              final after = _snapshot(sandbox);
              expect(
                after.keys.toSet(),
                equals(before.keys.toSet()),
                reason: 'no files, caches, logs, or backups are created',
              );
              for (final key in before.keys) {
                if (key == 'agent.md') continue;
                expect(after[key], before[key], reason: key);
              }
              expect(sentinel.readAsStringSync(), 'do not change');
            });
          },
        );

        test(
          'definitions are closed after success, malformed, and over-cap reads',
          () async {
            await _withSandbox((sandbox) async {
              final file = _write(sandbox, 'agent.md', _claudeDefinition());

              Future<void> expectClosed(String suffix) async {
                final renamed = p.join(sandbox.path, 'agent.md.$suffix');
                await file.rename(renamed);
                await File(renamed).rename(file.path);
              }

              _expectSuccess(
                await _validate([file.path, '--harness', 'claude']),
              );
              await expectClosed('after-success');

              file.writeAsBytesSync(<int>[0x2D, 0x2D, 0x2D, 0x0A, 0xFF]);
              _expectFailure(
                await _validate([file.path, '--harness', 'claude']),
                exitCode: 2,
              );
              await expectClosed('after-malformed');

              file.writeAsBytesSync(_definitionBytes(_definitionSizeLimit + 1));
              _expectFailure(
                await _validate([file.path, '--harness', 'claude']),
                exitCode: 3,
              );
              await expectClosed('after-over-cap');
            });
          },
        );
      });

      group('production smoke', () {
        test(
          'json inspect streams the privacy-preserving envelope on stdout',
          () async {
            await _withSandbox((sandbox) async {
              final file = _write(sandbox, 'agent.md', _claudeDefinition());
              final result = await _runProduction(sandbox, [
                'agent',
                'inspect',
                file.path,
                '--harness',
                'claude',
                '--format',
                'json',
              ]);
              expect(
                result.exitCode,
                0,
                reason: 'stdout=${result.stdout} stderr=${result.stderr}',
              );
              expect(result.stderr, isEmpty);
              expect(result.stdout, isNot(contains(_sentinel)));
              final report = _decodeObject(result.stdout);
              _expectEnvelope(
                report,
                command: 'agent inspect',
                outcome: 'inspected',
              );
              _expectReady(report, ready: true);
            });
          },
        );

        test(
          'validate rejects a failed candidate on stderr with status two',
          () async {
            await _withSandbox((sandbox) async {
              final file = _write(
                sandbox,
                'agent.md',
                _claudeDefinition(name: null),
              );
              final result = await _runProduction(sandbox, [
                'agent',
                'validate',
                file.path,
                '--harness',
                'claude',
                '--format',
                'json',
              ]);
              expect(result.exitCode, 2);
              expect(result.stdout, isEmpty);
              expect(result.stderr, isNotEmpty);
              _expectNotJson(result.stderr.trim());
            });
          },
        );

        test(
          'text inspect with --show-instructions prints the exact body',
          () async {
            await _withSandbox((sandbox) async {
              final file = _write(sandbox, 'agent.md', _claudeDefinition());
              final result = await _runProduction(sandbox, [
                'agent',
                'inspect',
                file.path,
                '--harness',
                'claude',
                '--show-instructions',
              ]);
              expect(
                result.exitCode,
                0,
                reason: 'stdout=${result.stdout} stderr=${result.stderr}',
              );
              expect(result.stderr, isEmpty);
              expect(result.stdout, contains(_claudeBody));
            });
          },
        );

        test('a bound-role json request inspects the selected role', () async {
          await _withSandbox((sandbox) async {
            _writeBound(sandbox);
            final request = _writeRequest(sandbox);
            final result = await _runProduction(sandbox, [
              'agent',
              'inspect',
              '--request',
              request.path,
              '--cwd',
              '${sandbox.path}${Platform.pathSeparator}',
              '--format',
              'json',
            ]);
            expect(
              result.exitCode,
              0,
              reason: 'stdout=${result.stdout} stderr=${result.stderr}',
            );
            expect(result.stderr, isEmpty);
            expect(result.stdout, isNot(contains(_boundSentinel)));
            final report = _decodeObject(result.stdout);
            _expectEnvelope(
              report,
              command: 'agent inspect',
              outcome: 'inspected',
            );
            expect(_dataOf(report)['profile'], _codexProfile);
            _expectReady(report, ready: true);
          });
        });

        test(
          'an over-cap definition fails incompletely with status three',
          () async {
            await _withSandbox((sandbox) async {
              final file = _writeBytes(
                sandbox,
                'over.md',
                _definitionBytes(_definitionSizeLimit + 1),
              );
              final result = await _runProduction(sandbox, [
                'agent',
                'validate',
                file.path,
                '--harness',
                'claude',
                '--format',
                'json',
              ]);
              expect(
                result.exitCode,
                3,
                reason: 'stdout=${result.stdout} stderr=${result.stderr}',
              );
              expect(result.stdout, isEmpty);
              expect(result.stderr, isNotEmpty);
              _expectNotJson(result.stderr.trim());
            });
          },
        );
      });
    });
  });
}
