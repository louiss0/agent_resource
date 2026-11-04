import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'process_test_support.dart';

/// Exercises the compiled CLI against real Git HTTPS and smart-HTTP transport.
/// Certificate verification remains enabled; all trust and credentials are
/// fixture-local. Raw requests, streams, and credentials are never returned.
Future<Map<String, Object?>> runHttpsGitGate({
  required Directory sandbox,
  required Map<String, String> environment,
  required void Function(String) onCredential,
  required Future<CliProcessResult> Function(
    String scenario,
    Directory cwd,
    List<String> arguments, {
    String? input,
    Map<String, String>? processEnvironment,
  })
  run,
}) async {
  final python =
      Platform.environment['AGENT_RESOURCE_TEST_PYTHON'] ??
      (Platform.isWindows ? 'python' : 'python3');
  final fixtureRoot = Directory(p.join(sandbox.path, 'https-git-fixture'))
    ..createSync();
  final fixture = await Process.start(
    python,
    [p.join(_packageRoot().path, 'test', 'support', 'https_git_fixture.py')],
    workingDirectory: fixtureRoot.path,
    environment: environment,
  );
  final lines = StreamIterator<String>(
    utf8.decoder.bind(fixture.stdout).transform(const LineSplitter()),
  );
  final errors = StringBuffer();
  final stderrDone = fixture.stderr
      .transform(utf8.decoder)
      .forEach(errors.write);
  Process? retained = fixture;
  final exited = fixture.exitCode.then((value) {
    if (retained == null) return;
    throw StateError('HTTPS Git fixture exited $value: $errors');
  });
  unawaited(exited.catchError((Object _) {}));
  try {
    fixture.stdin.writeln(jsonEncode({'root': fixtureRoot.path}));
    _require(await _next(lines, exited), 'HTTPS Git fixture did not start.');
    final config = jsonDecode(lines.current) as Map<String, dynamic>;
    final secret = config['secret']! as String;
    final username = config['username']! as String;
    onCredential(secret);
    final ca = config['ca']! as String;
    final scenarios = <String, Object?>{
      'authenticated-success': <String, Object?>{'expectedStatus': 0},
      'wrong-credentials': <String, Object?>{
        'expectedStatus': 3,
        'password': 'incorrect-disposable',
      },
      'untrusted-certificate': <String, Object?>{
        'expectedStatus': 3,
        'trusted': false,
      },
      'hostname-mismatch': <String, Object?>{
        'expectedStatus': 3,
        'hostname': '127.0.0.1',
      },
      'cross-origin-redirect-refused': <String, Object?>{
        'expectedStatus': 3,
        'source': config['cross'],
      },
      'https-downgrade-refused': <String, Object?>{
        'expectedStatus': 3,
        'source': config['down'],
      },
    };
    final outcomes = <Map<String, Object?>>[];
    final observedEvents = <Map<String, dynamic>>[];
    for (final entry in scenarios.entries) {
      final name = entry.key;
      final options = entry.value! as Map<String, Object?>;
      final project = Directory(p.join(sandbox.path, 'https-$name'))
        ..createSync();
      final source = Uri.parse(
        (options['source'] ?? config['primary'])! as String,
      );
      final credential = options['password'] as String? ?? secret;
      final uri = source.replace(
        host: options['hostname'] as String? ?? source.host,
        userInfo: '$username:$credential',
      );
      final childEnvironment = <String, String>{
        ...environment,
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
        'GIT_TERMINAL_PROMPT': '0',
        'GIT_ASKPASS': '',
        'SSH_ASKPASS': '',
        if (Platform.isWindows || Platform.isMacOS) ...{
          // The fixture CA is PEM. This selects only the child Git backend;
          // it neither installs trust nor relaxes certificate verification.
          'GIT_CONFIG_COUNT': '1',
          'GIT_CONFIG_KEY_0': 'http.sslBackend',
          'GIT_CONFIG_VALUE_0': 'openssl',
        },
        if (options['trusted'] != false) 'GIT_SSL_CAINFO': ca,
      };
      onCredential(uri.toString());
      final CliProcessResult result;
      try {
        result = await run(name, project, [
          'skill',
          'install',
          uri.toString(),
          '--source-kind',
          'resource',
          '--scope',
          'project',
          '--target',
          'codex',
          '--method',
          'canonical',
          '--yes',
          '--format',
          'json',
          '--cwd',
          '${project.path}${p.separator}',
          '--project-root',
          '${project.path}${p.separator}',
          '--home',
          '${p.join(sandbox.path, 'home')}${p.separator}',
        ], processEnvironment: childEnvironment);
      } on CliProcessTimeout catch (error) {
        throw StateError(
          error
              .toString()
              .replaceAll(uri.toString(), '<redacted>')
              .replaceAll(secret, '<redacted>')
              .replaceAll(credential, '<redacted>'),
        );
      }
      _require(
        result.exitCode == options['expectedStatus'],
        '$name returned ${result.exitCode}, expected ${options['expectedStatus']}: '
        '${result.stderr.replaceAll(secret, '<redacted>').replaceAll(credential, '<redacted>')}',
      );
      _require(
        !result.stdout.contains(secret) &&
            !result.stderr.contains(secret) &&
            !result.stdout.contains(credential) &&
            !result.stderr.contains(credential),
        '$name exposed a disposable credential.',
      );
      final success = name == 'authenticated-success';
      final installed = File(
        p.join(project.path, '.agents', 'skills', 'tls-demo', 'SKILL.md'),
      ).existsSync();
      _require(installed == success, '$name produced the wrong installation.');
      if (!success) {
        _require(project.listSync().isEmpty, '$name wrote target state.');
        _require(result.stdout.isEmpty, '$name wrote success output.');
      }
      final temporary = Directory(p.join(sandbox.path, 'temp'));
      _require(
        temporary.listSync().isEmpty,
        '$name retained acquisition temporary state.',
      );
      fixture.stdin.writeln('events');
      _require(
        await _next(lines, exited),
        '$name returned no sanitized transport observations.',
      );
      final currentEvents =
          (jsonDecode(lines.current) as Map<String, dynamic>)['events']!
              as List<dynamic>;
      for (final event in currentEvents) {
        if (event is! Map<String, dynamic>) {
          throw StateError('Invalid transport observation.');
        }
        observedEvents.add({...event, 'scenario': name});
      }
      outcomes.add({
        'scenario': name,
        'exitCode': result.exitCode,
        'installed': installed,
        'rawStreamsRetained': false,
        'credentialsRedacted': true,
      });
    }
    fixture.stdin.writeln('stop');
    await fixture.stdin.close();
    _require(
      await fixture.exitCode.timeout(const Duration(seconds: 15)) == 0,
      'HTTPS Git fixture did not stop cleanly.',
    );
    _require(
      await _next(lines, exited),
      'HTTPS Git fixture returned no observations.',
    );
    final observations = jsonDecode(lines.current) as Map<String, dynamic>;
    _require(
      (observations['events']! as List<dynamic>).isEmpty,
      'Unexpected requests remained after the final scenario.',
    );
    bool correctCredential(String server) => observedEvents.any(
      (event) =>
          event['server'] == server && event['authorizationCorrect'] == true,
    );
    _require(
      correctCredential('primary'),
      'Authenticated HTTPS Git success was not observed at the server.',
    );
    List<dynamic> requests(String scenario, [String? server]) => observedEvents
        .where(
          (event) =>
              event['scenario'] == scenario &&
              (server == null || event['server'] == server),
        )
        .toList();
    _require(
      requests('wrong-credentials', 'primary').any(
        (event) =>
            event['authorizationPresent'] == true &&
            event['authorizationCorrect'] == false,
      ),
      'The wrong-credential failure did not exercise authentication.',
    );
    for (final scenario in ['untrusted-certificate', 'hostname-mismatch']) {
      _require(
        requests(scenario).isEmpty,
        '$scenario reached HTTP instead of failing TLS verification.',
      );
    }
    _require(
      requests('cross-origin-redirect-refused', 'primary').isNotEmpty &&
          requests('cross-origin-redirect-refused', 'other-origin').isEmpty,
      'A refused cross-origin redirect was not contained at the primary origin.',
    );
    _require(
      requests('https-downgrade-refused', 'primary').isNotEmpty &&
          requests('https-downgrade-refused', 'plaintext').isEmpty,
      'A refused downgrade was not contained at the HTTPS origin.',
    );
    await stderrDone;
    _require(errors.isEmpty, 'HTTPS Git fixture failed: $errors');
    retained = null;
    return {
      'transport': 'real-git-smart-https',
      'certificateVerification': 'enabled',
      'trustScope': 'fixture-child-process-only',
      'credentialKind': 'synthetic-ephemeral',
      'gitRedirectPolicy': 'refused',
      'serverObservedAuthenticatedRequests': true,
      'crossOriginRequests': 0,
      'plaintextRequests': 0,
      'rawRequestsRetained': false,
      'rawCredentialsRetained': false,
      'scenarios': outcomes,
    };
  } finally {
    if (retained != null) {
      retained.kill();
      await retained.exitCode;
      await stderrDone;
    }
    await lines.cancel();
  }
}

Future<bool> _next(StreamIterator<String> lines, Future<void> exited) =>
    Future.any<bool>([
      lines.moveNext(),
      exited.then((_) => Completer<bool>().future),
    ]).timeout(const Duration(seconds: 60));

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Directory _packageRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    if (File(p.join(directory.path, 'pubspec.yaml')).existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Could not locate the package root.');
    }
    directory = parent;
  }
}
