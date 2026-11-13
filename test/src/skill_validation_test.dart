import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_resource/src/skill_validation.dart';
import 'package:file/file.dart' as f;
import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

const _markerSizeLimit = 1048576;
const _frontmatterSizeLimit = 65536;
const _profile = 'agentskills-core-strict-ascii-v1';
const _baseline = '69ef37e9424c0a7ea9dd2293b559e43ec8176379';

f.FileSystem get _fs =>
    Zone.current[#fs] as f.FileSystem? ?? const LocalFileSystem();
path.Context get p => _fs.path;
String _absoluteLexical(String value) =>
    p.normalize(_fs.directory(value).absolute.path);

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

Future<T> _withParent<T>(Future<T> Function(f.Directory parent) body) async {
  final fs = MemoryFileSystem.test(style: FileSystemStyle.posix);
  final parent = fs.directory('/sandbox')..createSync();
  fs.currentDirectory = parent;
  return runZoned(() => body(parent), zoneValues: {#fs: fs});
}

Future<T> _withLocalParent<T>(
  Future<T> Function(f.Directory parent) body,
) async {
  const fs = LocalFileSystem();
  final parent = await fs.systemTempDirectory.createTemp(
    'agent-resource-validate-',
  );
  try {
    return await runZoned(() => body(parent), zoneValues: {#fs: fs});
  } finally {
    await parent.delete(recursive: true);
  }
}

Future<T> _withSkill<T>(
  Future<T> Function(f.Directory skill) body, {
  String directoryName = 'valid-skill',
  List<int>? bytes,
  String? marker,
  bool local = false,
}) => (local ? _withLocalParent : _withParent)((parent) async {
  final skill = _fs.directory(p.join(parent.path, directoryName))
    ..createSync(recursive: true);
  if (bytes != null || marker != null) {
    _fs
        .file(p.join(skill.path, 'SKILL.md'))
        .writeAsBytesSync(bytes ?? utf8.encode(marker!));
  }
  return body(skill);
});

Future<T> _withRoot<T>(Future<T> Function(f.Directory root) body) =>
    _withParent(body);
Future<T> _withLocalRoot<T>(Future<T> Function(f.Directory root) body) =>
    _withLocalParent(body);

Map<String, String> _snapshot(f.Directory root) {
  final entries = <String, String>{'.': 'directory'};

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

ValidationReport _expectSuccess(ValidationReport report) {
  expect(report.valid, isTrue, reason: report.toJson().toString());
  return report;
}

ValidationReport _expectFailure(ValidationReport report) {
  expect(report.valid, isFalse, reason: report.toJson().toString());
  return report;
}

Map<String, Object?> _reportFromSuccess(ValidationReport report) =>
    report.toJson();
Map<String, Object?> _reportFromInvalid(ValidationReport report) =>
    report.toJson();

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
    await _fs.link(link).create(target);
    return true;
  } on FileSystemException {
    return false;
  } on UnsupportedError {
    return false;
  }
}

void main() {
  group('validateSkill strict core profile', () {
    test(
      'reports success and invalid results without mutating files',
      () async {
        await _withParent((parent) async {
          final skill = _fs.directory(p.join(parent.path, 'valid-skill'))
            ..createSync();
          final marker = _fs.file(p.join(skill.path, 'SKILL.md'))
            ..writeAsStringSync(_marker());
          _fs
              .file(p.join(skill.path, 'sentinel'))
              .writeAsStringSync('unchanged');
          final before = _snapshot(parent);
          expect(validateSkill(skill.path, fs: _fs).valid, isTrue);
          expect(_snapshot(parent), before);
          marker.writeAsStringSync('---\ndescription: invalid\n---\n');
          final invalidBefore = _snapshot(parent);
          expect(validateSkill(skill.path, fs: _fs).valid, isFalse);
          expect(_snapshot(parent), invalidBefore);
          marker.writeAsStringSync(_marker());
          expect(validateSkill(skill.path, fs: _fs).diagnostics, isEmpty);
          expect(_snapshot(parent), before);
        });
      },
    );

    test('missing and file roots throw operational exceptions', () async {
      await _withRoot((root) async {
        final file = _fs.file(p.join(root.path, 'file'))
          ..writeAsStringSync('x');
        for (final selected in [p.join(root.path, 'missing'), file.path]) {
          expect(
            () => validateSkill(selected, fs: _fs),
            throwsA(isA<MambaException>()),
          );
        }
      });
    });

    test('unreadable root fails when host permissions permit', () async {
      if (Platform.isWindows) {
        markTestSkipped(
          'portable unreadable-directory setup is unavailable on Windows',
        );
        return;
      }
      await _withLocalRoot((root) async {
        final changed = await Process.run('chmod', ['000', root.path]);
        if (changed.exitCode != 0) {
          markTestSkipped('chmod is unavailable');
          return;
        }
        try {
          expect(
            () => validateSkill(root.path, fs: _fs),
            throwsA(isA<MambaException>()),
          );
        } finally {
          await Process.run('chmod', ['700', root.path]);
        }
      });
    });

    test('returns the complete valid report with no diagnostics', () async {
      await _withSkill((skill) async {
        final result = _expectSuccess(validateSkill(skill.path, fs: _fs));
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
            from: _fs.currentDirectory.path,
          );
          final report = _reportFromSuccess(
            _expectSuccess(validateSkill(argument, fs: _fs)),
          );
          expect(report['path'], _absoluteLexical(argument));
        }, marker: _marker());
      },
    );

    test('invalid content returns a report', () async {
      await _withSkill((skill) async {
        final result = _expectFailure(validateSkill(skill.path, fs: _fs));
        final report = _reportFromInvalid(result);
        _expectReportShape(
          report,
          path: _absoluteLexical(skill.path),
          valid: false,
        );
        _expectDiagnostic(report, 'NAME_REQUIRED', field: 'name');
      }, marker: '---\ndescription: valid\n---\n');
    });

    test('marker body is opaque and resources are not read', () async {
      await _withSkill(
        (skill) async {
          _fs
              .directory(p.join(skill.path, 'references', 'unreadable'))
              .createSync(recursive: true);
          _fs
              .file(p.join(skill.path, 'references', 'not-a-file'))
              .writeAsStringSync(
                'this is intentionally not a resource for validation',
              );
          _fs.file(p.join(skill.path, 'scripts', 'run.sh'))
            ..parent.createSync(recursive: true)
            ..writeAsStringSync('exit 99\n');
          final report = _reportFromSuccess(
            _expectSuccess(validateSkill(skill.path, fs: _fs)),
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
      'marker handles close before rename after success and invalid reads',
      () async {
        await _withSkill(
          (skill) async {
            final marker = _fs.file(p.join(skill.path, 'SKILL.md'));
            _expectSuccess(validateSkill(skill.path, fs: _fs));
            final renamed = p.join(skill.path, 'SKILL.md.after-success');
            await marker.rename(renamed);
            await _fs.file(renamed).rename(marker.path);

            marker.writeAsBytesSync(<int>[0x2D, 0x2D, 0x2D, 0x0A, 0xFF]);
            _expectFailure(validateSkill(skill.path, fs: _fs));
            final renamedAfterInvalid = p.join(
              skill.path,
              'SKILL.md.after-invalid',
            );
            await marker.rename(renamedAfterInvalid);
            await _fs.file(renamedAfterInvalid).rename(marker.path);

            marker.writeAsBytesSync(
              List<int>.filled(_markerSizeLimit + 1, 0x78),
            );
            _expectFailure(validateSkill(skill.path, fs: _fs));
            final renamedAfterOversize = p.join(
              skill.path,
              'SKILL.md.after-oversize',
            );
            await marker.rename(renamedAfterOversize);
            await _fs.file(renamedAfterOversize).rename(marker.path);
          },
          marker: _marker(),
          local: true,
        );
      },
    );

    test('accepts strict UTF-8 BOM and CRLF frontmatter', () async {
      await _withSkill((skill) async {
        final text = _marker().replaceAll('\n', '\r\n');
        final bytes = <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(text)];
        _fs.file(p.join(skill.path, 'SKILL.md')).writeAsBytesSync(bytes);
        final report = _reportFromSuccess(
          _expectSuccess(validateSkill(skill.path, fs: _fs)),
        );
        expect(report['valid'], isTrue);
      });
    });

    final cases = <({String name, String marker, String code, String field})>[
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
          final result = _expectFailure(validateSkill(skill.path, fs: _fs));
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
          _expectSuccess(validateSkill(skill.path, fs: _fs)),
        );
        expect(report['valid'], isTrue);
      }, marker: _marker(description: '😀' * 1024));
    });

    test('accepts the 64-scalar name boundary', () async {
      final name = 'a' * 64;
      await _withSkill(
        (skill) async {
          final report = _reportFromSuccess(
            _expectSuccess(validateSkill(skill.path, fs: _fs)),
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
              _expectFailure(validateSkill(skill.path, fs: _fs)),
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
          _expectFailure(validateSkill(skill.path, fs: _fs)),
        );
        _expectDiagnostic(report, 'SKILL_FILE_MISSING');
      });
    });

    test('directory marker is not read as a file', () async {
      await _withSkill((skill) async {
        _fs.directory(p.join(skill.path, 'SKILL.md')).createSync();
        final report = _reportFromInvalid(
          _expectFailure(validateSkill(skill.path, fs: _fs)),
        );
        _expectDiagnostic(report, 'SKILL_FILE_TYPE');
      });
    });

    test('explicit root links preserve their lexical selected path', () async {
      await _withLocalParent((parent) async {
        final target = _fs.directory(p.join(parent.path, 'valid-skill'))
          ..createSync();
        _fs
            .file(p.join(target.path, 'SKILL.md'))
            .writeAsStringSync(_marker(name: 'selected-link'));
        final linkPath = p.join(parent.path, 'selected-link');
        if (!await _tryCreateLink(linkPath, target.path)) {
          markTestSkipped('directory symlink creation is unavailable');
          return;
        }
        final report = _reportFromSuccess(
          _expectSuccess(validateSkill(linkPath, fs: _fs)),
        );
        expect(report['path'], _absoluteLexical(linkPath));
        expect(report['valid'], isTrue);
      });
    });

    test('linked marker is rejected before its target is read', () async {
      await _withLocalParent((parent) async {
        final skill = _fs.directory(p.join(parent.path, 'valid-skill'))
          ..createSync();
        final target = _fs.file(p.join(parent.path, 'target.md'))
          ..writeAsStringSync(_marker());
        final link = p.join(skill.path, 'SKILL.md');
        if (!await _tryCreateLink(link, target.path)) {
          markTestSkipped('file symlink creation is unavailable');
          return;
        }
        final report = _reportFromInvalid(
          _expectFailure(validateSkill(skill.path, fs: _fs)),
        );
        _expectDiagnostic(report, 'SKILL_FILE_LINK', category: 'product');
      });
    });

    test(
      'missing and unterminated frontmatter have separate diagnostics',
      () async {
        for (final fixture in <({String text, String code})>[
          (text: '# body only\n', code: 'FRONTMATTER_MISSING'),
          (text: '---\nname: valid-skill\n', code: 'FRONTMATTER_UNTERMINATED'),
        ]) {
          await _withSkill((skill) async {
            final report = _reportFromInvalid(
              _expectFailure(validateSkill(skill.path, fs: _fs)),
            );
            _expectDiagnostic(report, fixture.code);
          }, marker: fixture.text);
        }
      },
    );

    test(
      'rejects malformed YAML, duplicate keys, and non-mapping YAML',
      () async {
        for (final fixture in <({String text, String code})>[
          (
            text: '---\nname: [unterminated\ndescription: x\n---\n',
            code: 'YAML_INVALID',
          ),
          (
            text: '---\nname: valid-skill\nname: other\ndescription: x\n---\n',
            code: 'YAML_INVALID',
          ),
          (text: '---\n- item\n---\n', code: 'FRONTMATTER_MAPPING'),
        ]) {
          await _withSkill((skill) async {
            final report = _reportFromInvalid(
              _expectFailure(validateSkill(skill.path, fs: _fs)),
            );
            _expectDiagnostic(report, fixture.code);
          }, marker: fixture.text);
        }
      },
    );

    test('rejects non-string top-level YAML keys', () async {
      await _withSkill((skill) async {
        final report = _reportFromInvalid(
          _expectFailure(validateSkill(skill.path, fs: _fs)),
        );
        _expectDiagnostic(report, 'FRONTMATTER_KEYS', category: 'product');
      }, marker: '---\n1: value\nname: valid-skill\ndescription: x\n---\n');
    });

    test('enforces the marker and frontmatter byte caps', () async {
      await _withSkill(
        (skill) async {
          final report = _reportFromSuccess(
            _expectSuccess(validateSkill(skill.path, fs: _fs)),
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
          _expectFailure(validateSkill(skill.path, fs: _fs)),
        );
        _expectDiagnostic(report, 'FILE_SIZE_LIMIT', category: 'product');
      }, bytes: List<int>.filled(_markerSizeLimit + 1, 0x78));
      await _withSkill((skill) async {
        final report = _reportFromSuccess(
          _expectSuccess(validateSkill(skill.path, fs: _fs)),
        );
        expect(report['valid'], isTrue);
      }, marker: _sizedFrontmatter(_frontmatterSizeLimit));
      await _withSkill((skill) async {
        final report = _reportFromInvalid(
          _expectFailure(validateSkill(skill.path, fs: _fs)),
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
          _expectSuccess(validateSkill(skill.path, fs: _fs)),
        );
        expect(report['valid'], isTrue);
      }, bytes: _sizedMarkerBytes(_markerSizeLimit));
      await _withSkill((skill) async {
        final report = _reportFromInvalid(
          _expectFailure(validateSkill(skill.path, fs: _fs)),
        );
        _expectDiagnostic(
          report,
          'FRONTMATTER_SIZE_LIMIT',
          category: 'product',
        );
      }, marker: _sizedFrontmatter(_frontmatterSizeLimit + 1, multibyte: true));
    });

    test(
      'rejects invalid UTF-8 without decoding or reading resources',
      () async {
        await _withSkill((skill) async {
          final report = _reportFromInvalid(
            _expectFailure(validateSkill(skill.path, fs: _fs)),
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
              _expectSuccess(validateSkill(skill.path, fs: _fs)),
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
              _expectFailure(validateSkill(skill.path, fs: _fs)),
            );
            _expectDiagnostic(report, testCase.code, field: testCase.field);
          },
          marker:
              '---\nname: valid-skill\ndescription: valid\n${testCase.yaml}\n---\n',
        );
      });
    }
  });
}
