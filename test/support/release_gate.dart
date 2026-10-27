import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'process_test_support.dart';

/// Executes release evidence against the actual compiled production artifact.
/// The report is sanitized: raw native documents, instructions, stdout, and
/// stderr are asserted but never retained in the evidence bundle.
Future<void> main(List<String> args) async {
  if (args.length < 2 ||
      args.length > 3 ||
      (args.length == 3 && args[2] != '--require-qualified')) {
    throw ArgumentError(
      'Usage: release_gate.dart <production-executable> <evidence.json> '
      '[--require-qualified]',
    );
  }
  final requireQualified = args.length == 3;
  final executable = File(args[0]).absolute;
  final evidenceFile = File(args[1]).absolute;
  if (!executable.existsSync()) {
    throw StateError(
      'Production executable does not exist: ${executable.path}',
    );
  }
  final sandbox = await Directory.systemTemp.createTemp(
    'agent-resource-release-',
  );
  final results = <Map<String, Object?>>[];
  final blockers = <Map<String, Object?>>[];
  try {
    final work = Directory(p.join(sandbox.path, 'work'))..createSync();
    final home = Directory(p.join(sandbox.path, 'home'))..createSync();
    final environment = isolatedEnvironment(sandbox);
    Future<CliProcessResult> run(
      String scenario,
      Directory cwd,
      List<String> arguments, {
      String? input,
    }) async {
      final result = await runProcess(
        executable.path,
        arguments,
        workingDirectory: cwd,
        environment: environment,
        timeout: const Duration(seconds: 30),
        standardInput: input,
      );
      results.add(<String, Object?>{
        'scenario': scenario,
        'arguments': arguments
            .map((value) => value.replaceAll(sandbox.path, '<sandbox>'))
            .toList(),
        'exitCode': result.exitCode,
        'stdoutBytes': utf8.encode(result.stdout).length,
        'stderrBytes': utf8.encode(result.stderr).length,
        'rawStreamsRetained': false,
      });
      return result;
    }

    final inspectionContext = <String>[
      '--cwd',
      '${work.path}${p.separator}',
      '--format',
      'json',
    ];
    final context = <String>[
      '--cwd',
      '${work.path}${p.separator}',
      '--project-root',
      '${work.path}${p.separator}',
      '--home',
      '${home.path}${p.separator}',
      '--format',
      'json',
    ];
    const privateInstruction = 'PRIVATE-INSTRUCTION-RELEASE-GATE';
    final valid = File(p.join(sandbox.path, 'valid.md'))
      ..writeAsStringSync('''---
name: reviewer
description: Reviews.
tools: [Read]
---
$privateInstruction
''');
    final inspected = await run('built-inspect-graph', work, [
      'agent',
      'inspect',
      valid.path,
      '--harness',
      'claude',
      ...inspectionContext,
    ]);
    _expect(
      inspected.exitCode == 0,
      'Built graph inspection failed.',
      inspected,
    );
    _expect(
      inspected.stderr.isEmpty,
      'Graph inspection wrote stderr.',
      inspected,
    );
    _expect(
      !inspected.stdout.contains(privateInstruction),
      'Default output exposed instructions.',
      inspected,
    );
    final inspection = _json(inspected);
    _expect(
      inspection['command'] == 'agent inspect',
      'Unexpected inspect envelope.',
      inspected,
    );
    _expect(
      (inspection['data']! as Map<String, Object?>)['graph']
          is Map<String, Object?>,
      'Graph evidence missing.',
      inspected,
    );

    final invalid = File(p.join(sandbox.path, 'invalid.md'))
      ..writeAsStringSync('---\ndescription: Missing name.\n---\nBody.\n');
    final correctness = await run('built-status-2', work, [
      'agent',
      'validate',
      invalid.path,
      '--harness',
      'claude',
      ...inspectionContext,
    ]);
    _expect(
      correctness.exitCode == 2,
      'Correctness failure did not return status 2.',
      correctness,
    );
    _expect(
      correctness.stdout.isEmpty,
      'Failed validation emitted stdout.',
      correctness,
    );
    _expect(
      correctness.stderr.isNotEmpty,
      'Failed validation omitted diagnostics.',
      correctness,
    );

    final usage = await run('built-status-1', work, const [
      'unsupported-command',
    ]);
    _expect(
      usage.exitCode == 1,
      'Usage failure did not return status 1.',
      usage,
    );
    _expect(usage.stdout.isEmpty, 'Usage failure emitted stdout.', usage);

    final oversized = File(p.join(sandbox.path, 'oversized.md'));
    final prefix = utf8.encode('---\nname: large\ndescription: Large.\n---\n');
    oversized.writeAsBytesSync(<int>[
      ...prefix,
      ...List<int>.filled(1048576 - prefix.length + 1, 120),
    ]);
    final incomplete = await run('built-status-3', work, [
      'agent',
      'inspect',
      oversized.path,
      '--harness',
      'claude',
      ...inspectionContext,
    ]);
    _expect(
      incomplete.exitCode == 3,
      'Budget exhaustion did not return status 3.',
      incomplete,
    );
    _expect(
      incomplete.stdout.isEmpty,
      'Incomplete analysis emitted stdout.',
      incomplete,
    );

    final installed = await run('built-install-positive', work, [
      'agent',
      'install',
      valid.path,
      '--harness',
      'claude',
      ...context,
    ]);
    _expect(installed.exitCode == 0, 'Built installation failed.', installed);
    final installation =
        (_json(installed)['data']! as Map<String, Object?>)['installationId']!
            as String;
    final refused = await run('built-status-4', work, [
      'agent',
      'remove',
      installation,
      ...context,
    ]);
    _expect(
      refused.exitCode == 4,
      'Approval refusal did not return status 4.',
      refused,
    );
    _expect(
      refused.stdout.isEmpty,
      'Approval refusal emitted stdout.',
      refused,
    );
    final cancelled = await run('built-status-7', work, [
      'agent',
      'remove',
      installation,
      '--cwd',
      '${work.path}${p.separator}',
      '--project-root',
      '${work.path}${p.separator}',
      '--home',
      '${home.path}${p.separator}',
      '--interactive',
    ], input: 'n\n');
    _expect(
      cancelled.exitCode == 7,
      'Cancellation did not return status 7.',
      cancelled,
    );
    _expect(
      cancelled.stdout.isEmpty,
      'Cancellation emitted stdout.',
      cancelled,
    );

    final installedLocation =
        (_json(installed)['data']! as Map<String, Object?>)['location']!
            as String;
    final editRequest = File(p.join(sandbox.path, 'edit-request.json'))
      ..writeAsStringSync(
        jsonEncode(<String, Object?>{
          'schemaVersion': 1,
          'operation': 'edit',
          'source': <String, Object?>{
            'kind': 'managed-agent',
            'installationId': installation,
          },
          'target': <String, Object?>{
            'harness': 'claude',
            'installationId': installation,
            'output': installedLocation,
          },
          'context': <String, Object?>{'workingDirectory': './'},
          'definition': <String, Object?>{
            'description': 'Edited in the artifact gate.',
          },
          'instructions': <Object?>['Edited instructions.'],
        }),
      );
    final editPlanned = await run('built-edit-plan', work, [
      'agent',
      'edit',
      editRequest.path,
      ...context,
    ]);
    _expect(
      editPlanned.exitCode == 0,
      'Managed edit planning failed.',
      editPlanned,
    );
    final editPlan = _json(editPlanned)['data']! as Map<String, Object?>;
    final editApplied = await run('built-edit-apply', work, [
      'agent',
      'edit',
      editRequest.path,
      '--apply',
      '--plan-id',
      editPlan['planId']! as String,
      '--yes',
      ...context,
    ]);
    _expect(
      editApplied.exitCode == 0,
      'Managed edit apply failed.',
      editApplied,
    );
    _expect(
      File(installedLocation)
          .readAsStringSync()
          .contains('Edited instructions.'),
      'Managed edit did not publish reviewed instructions.',
      editApplied,
    );

    if (Platform.isWindows) {
      final replacement = File(p.join(sandbox.path, 'replacement.md'))
        ..writeAsStringSync('''---
name: reviewer
description: Replacement during a native lock fixture.
---
Replacement instructions.
''');
      final locked = File(installedLocation).openSync();
      try {
        locked.lockSync(FileLock.exclusive);
        final restoredAttempt = await run(
          'built-rare-restored-or-recovery-attempt',
          work,
          [
            'agent',
            'replace',
            installation,
            replacement.path,
            '--yes',
            ...context,
          ],
        );
        _expect(
          restoredAttempt.exitCode != 1 &&
              restoredAttempt.exitCode != 2 &&
              restoredAttempt.exitCode != 3 &&
              restoredAttempt.exitCode != 7,
          'Rare native failure fixture produced an unrelated outcome.',
          restoredAttempt,
        );
      } finally {
        try {
          locked.unlockSync();
        } on FileSystemException {
          // Closing also releases the native lock.
        }
        locked.closeSync();
      }
    }

    for (final source in const ['claude', 'codex', 'pi']) {
      for (final target in const ['claude', 'codex', 'pi']) {
        if (source == target) continue;
        await _conversion(
          source: source,
          target: target,
          sandbox: sandbox,
          home: home,
          run: run,
        );
      }
    }

    final skillSource = Directory(p.join(sandbox.path, 'skill-copy'))
      ..createSync();
    File(p.join(skillSource.path, 'SKILL.md')).writeAsStringSync('''---
name: release-copy
description: Copy lifecycle fixture.
---
Original body.
''');
    final skillInstalled = await run('built-skill-copy-install', work, [
      'skill',
      'install',
      '${skillSource.path}${p.separator}',
      '--destination',
      'claude',
      ...context,
    ]);
    _expect(
      skillInstalled.exitCode == 0,
      'Skill copy install failed.',
      skillInstalled,
    );
    final skillId =
        (_json(skillInstalled)['data']!
                as Map<String, Object?>)['installationId']!
            as String;
    File(p.join(skillSource.path, 'SKILL.md')).writeAsStringSync('''---
name: release-copy
description: Copy lifecycle fixture.
---
Replacement body.
''');
    final skillReplaced = await run('built-skill-copy-replace', work, [
      'skill',
      'replace',
      skillId,
      '${skillSource.path}${p.separator}',
      '--yes',
      ...context,
    ]);
    _expect(
      skillReplaced.exitCode == 0,
      'Skill copy replacement failed.',
      skillReplaced,
    );
    final backups = await run('built-skill-backup-list', work, [
      'skill',
      'backup',
      'list',
      ...context,
    ]);
    _expect(backups.exitCode == 0, 'Skill backup listing failed.', backups);
    final adopted = Directory(
      p.join(home.path, '.claude', 'skills', 'release-adopted'),
    )..createSync(recursive: true);
    File(p.join(adopted.path, 'SKILL.md')).writeAsStringSync('''---
name: release-adopted
description: Adoption lifecycle fixture.
---
Adopted body.
''');
    final skillAdopted = await run('built-skill-adopt', work, [
      'skill',
      'adopt',
      '${adopted.path}${p.separator}',
      '--destination',
      'claude',
      ...context,
    ]);
    _expect(skillAdopted.exitCode == 0, 'Skill adoption failed.', skillAdopted);

    final linkCapability = await _directoryLinkCapability(sandbox);
    if (linkCapability) {
      final linkedSource = Directory(p.join(sandbox.path, 'skill-linked'))
        ..createSync();
      File(p.join(linkedSource.path, 'SKILL.md')).writeAsStringSync('''---
name: release-linked
description: Linked lifecycle fixture.
---
Linked body.
''');
      final linked = await run('built-skill-link-install', work, [
        'skill',
        'install',
        '${linkedSource.path}${p.separator}',
        '--destination',
        'claude',
        '--mode',
        'link',
        ...context,
      ]);
      _expect(
        linked.exitCode == 0,
        'True linked Skill installation failed.',
        linked,
      );
      final linkEntry = p.join(
        home.path,
        '.claude',
        'skills',
        'release-linked',
      );
      _expect(
        FileSystemEntity.typeSync(linkEntry, followLinks: false) ==
            FileSystemEntityType.link,
        'Linked Skill workflow did not produce a true link entry.',
        linked,
      );
    }
    if (Platform.isWindows && !linkCapability) {
      blockers.add(<String, Object?>{
        'code': 'WINDOWS_DIRECTORY_SYMLINK_UNAVAILABLE',
        'message': 'A true directory symlink could not be created; linked-Skill native qualification remains blocked.',
      });
    }
    final observed =
        results.map((result) => result['exitCode']! as int).toSet().toList()
          ..sort();
    final missing = <int>[
      for (var status = 0; status <= 7; status++)
        if (!observed.contains(status)) status,
    ];
    for (final status in missing) {
      blockers.add(<String, Object?>{
        'code': 'PRODUCTION_STATUS_EVIDENCE_MISSING',
        'status': status,
        'message':
            'No reproducible real built-production status $status was observed in this job.',
      });
    }
    final lockfile = File(p.join(_packageRoot().path, 'pubspec.lock'));
    final evidence = <String, Object?>{
      'schemaVersion': 1,
      'revision': Platform.environment['GITHUB_SHA'] ?? 'local-working-tree',
      'artifact': <String, Object?>{
        'path': executable.path.replaceAll(sandbox.path, '<sandbox>'),
        'sha256': sha256.convert(executable.readAsBytesSync()).toString(),
        'byteLength': executable.lengthSync(),
      },
      'selectedSdk': Platform.version,
      'dependencyLockSha256': sha256
          .convert(lockfile.readAsBytesSync())
          .toString(),
      'environment': <String, Object?>{
        'operatingSystem': Platform.operatingSystem,
        'operatingSystemVersion': Platform.operatingSystemVersion,
        'architecture':
            Platform.environment['RUNNER_ARCH'] ??
            Platform.environment['PROCESSOR_ARCHITECTURE'] ??
            'unknown',
        'filesystem': 'native-runner-temp',
        'trueDirectorySymlink': linkCapability,
      },
      'job': <String, Object?>{
        'runId': Platform.environment['GITHUB_RUN_ID'],
        'job': Platform.environment['GITHUB_JOB'],
        'repository': Platform.environment['GITHUB_REPOSITORY'],
        'serverUrl': Platform.environment['GITHUB_SERVER_URL'],
      },
      'results': results,
      'observedStatuses': observed,
      'missingStatuses': missing,
      'blockers': blockers,
      'qualified': blockers.isEmpty,
      'runtimeActivationVerified': false,
      'runtimeEquivalenceVerified': false,
      'rawNativeDocumentsRetained': false,
    };
    evidenceFile.parent.createSync(recursive: true);
    evidenceFile.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(evidence)}\n',
    );
    stdout.writeln('Release evidence: ${evidenceFile.path}');
    stdout.writeln('Observed statuses: ${observed.join(', ')}');
    stdout.writeln(
      'Qualified: ${blockers.isEmpty}; blockers: ${blockers.length}',
    );
    if (requireQualified && blockers.isNotEmpty) {
      exitCode = 2;
    }
  } finally {
    await sandbox.delete(recursive: true);
  }
}

Future<void> _conversion({
  required String source,
  required String target,
  required Directory sandbox,
  required Directory home,
  required Future<CliProcessResult> Function(
    String scenario,
    Directory cwd,
    List<String> arguments, {
    String? input,
  })
  run,
}) async {
  final root = Directory(p.join(sandbox.path, 'convert-$source-to-$target'))
    ..createSync();
  final project = Directory(p.join(root.path, 'project'))..createSync();
  final extension = source == 'codex' ? '.toml' : '.md';
  final sourceFile = File(p.join(root.path, 'source$extension'));
  const instructions = 'Review correctness.\n';
  sourceFile.writeAsStringSync(switch (source) {
    'claude' =>
      '''---
name: reviewer
description: Reviews changes.
model: claude-sonnet
effort: high
tools: [Read, Grep]
---
$instructions''',
    'codex' =>
      '''name = "reviewer"
description = "Reviews changes."
model = "openai/gpt-5"
model_reasoning_effort = "high"
developer_instructions = "Review correctness.\\n"
''',
    _ =>
      '''---
name: reviewer
description: Reviews changes.
model: kimi-coding/k3
thinking: high
tools: read, grep
---
$instructions''',
  });
  final sourceBytes = sourceFile.readAsBytesSync();
  final output =
      '.${target == 'pi' ? 'pi' : target}/agents/reviewer${target == 'codex' ? '.toml' : '.md'}';
  final definition = <String, Object?>{
    'model': switch (target) {
      'claude' => 'claude-sonnet',
      'codex' => 'openai/gpt-5',
      _ => 'kimi-coding/k3',
    },
    switch (target) {
      'claude' => 'effort',
      'codex' => 'model_reasoning_effort',
      _ => 'thinking',
    }: 'high',
    if (target == 'pi') 'tools': 'read, grep',
    if (target == 'claude') 'tools': <Object?>['Read'],
  };
  final request = File(p.join(root.path, 'request.json'))
    ..writeAsStringSync(
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'operation': 'convert',
        'source': <String, Object?>{
          'kind': 'native-file',
          'path': sourceFile.path,
          'harness': source,
        },
        'target': <String, Object?>{'harness': target, 'output': output},
        'context': <String, Object?>{'workingDirectory': './'},
        'definition': definition,
        'decisions': <Object?>[
          'map:model',
          'map:effort',
          if (target == 'pi' || target == 'claude') 'map:tools',
          if (source != 'codex' && target == 'codex') 'omit:tools',
        ],
      }),
    );
  final context = <String>[
    '--cwd',
    '${project.path}${p.separator}',
    '--project-root',
    '${project.path}${p.separator}',
    '--home',
    '${home.path}${p.separator}',
    '--format',
    'json',
  ];
  final before = _snapshot(project);
  final planned = await run('built-convert-$source-to-$target-plan', project, [
    'agent',
    'convert',
    request.path,
    ...context,
  ]);
  _expect(
    planned.exitCode == 0,
    'Conversion planning failed for $source to $target.',
    planned,
  );
  final plan = _json(planned);
  final data = plan['data']! as Map<String, Object?>;
  _expect(
    data['ready'] == true,
    'Conversion was not ready for $source to $target.',
    planned,
  );
  _expect(
    _snapshot(project).toString() == before.toString(),
    'Conversion planning wrote artifacts.',
    planned,
  );
  _expect(
    !planned.stdout.contains('Review correctness.'),
    'Conversion plan exposed instructions.',
    planned,
  );
  final applied = await run('built-convert-$source-to-$target-apply', project, [
    'agent',
    'convert',
    request.path,
    '--apply',
    '--plan-id',
    data['planId']! as String,
    '--yes',
    ...context,
  ]);
  _expect(
    applied.exitCode == 0,
    'Conversion apply failed for $source to $target.',
    applied,
  );
  _expect(
    _json(applied)['outcome'] == 'converted',
    'Unexpected conversion outcome.',
    applied,
  );
  _expect(
    sourceFile.readAsBytesSync().toString() == sourceBytes.toString(),
    'Conversion modified its source.',
    applied,
  );
  final validated = await run(
    'built-convert-$source-to-$target-validate',
    project,
    [
      'agent',
      'validate',
      output,
      '--harness',
      target,
      '--cwd',
      '${project.path}${p.separator}',
      '--format',
      'json',
    ],
  );
  _expect(
    validated.exitCode == 0,
    'Published conversion was invalid for $source to $target.',
    validated,
  );
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
        _ => type.toString(),
      };
      if (type == FileSystemEntityType.directory) visit(Directory(entity.path));
    }
  }

  visit(root);
  final keys = entries.keys.toList()..sort();
  return <String, String>{for (final key in keys) key: entries[key]!};
}

Future<bool> _directoryLinkCapability(Directory sandbox) async {
  final target = Directory(p.join(sandbox.path, 'link-target'))..createSync();
  final link = Link(p.join(sandbox.path, 'link-entry'));
  try {
    await link.create(target.path);
    return FileSystemEntity.typeSync(link.path, followLinks: false) ==
        FileSystemEntityType.link;
  } on FileSystemException {
    return false;
  } on UnsupportedError {
    return false;
  }
}

Map<String, Object?> _json(CliProcessResult result) {
  try {
    return jsonDecode(result.stdout) as Map<String, Object?>;
  } on Object {
    throw StateError('Expected JSON stdout, got status ${result.exitCode}.');
  }
}

void _expect(bool condition, String message, CliProcessResult result) {
  if (!condition) {
    throw StateError(
      '$message Status ${result.exitCode}; stdout ${result.stdout.length} bytes; '
      'stderr: ${result.stderr}',
    );
  }
}

Directory _packageRoot() {
  var current = Directory.current.absolute;
  while (true) {
    if (File(p.join(current.path, 'pubspec.yaml')).existsSync()) return current;
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Package root not found.');
    }
    current = parent;
  }
}
