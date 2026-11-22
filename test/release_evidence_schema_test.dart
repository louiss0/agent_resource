import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

const _liveHarness = <String>[
  'skill invocation by the target harness',
  'manual-only Prompt behavior',
  'MCP server connectivity and credential authentication',
  'Context consumption by the harness',
];

Map<String, Object?> _scenario(String name, int exitCode) => <String, Object?>{
  'scenario': name,
  'verification': 'native',
  'arguments': const <Object?>[],
  'exitCode': exitCode,
  'stdoutBytes': 0,
  'stderrBytes': 0,
  'rawStreamsRetained': false,
};

Map<String, Object?> _bundle(String os) {
  final results = <Map<String, Object?>>[
    for (var status = 0; status <= 7; status++)
      _scenario('built-status-$status', status),
    _scenario('built-skill-link-install', 0),
    _scenario('authenticated-success', 0)..['credentialsRedacted'] = true,
    _scenario('wrong-credentials', 3)..['credentialsRedacted'] = true,
    _scenario('untrusted-certificate', 3)..['credentialsRedacted'] = true,
    _scenario('hostname-mismatch', 3)..['credentialsRedacted'] = true,
    _scenario('cross-origin-redirect-refused', 3)
      ..['credentialsRedacted'] = true,
    _scenario('https-downgrade-refused', 3)..['credentialsRedacted'] = true,
    for (final source in const ['claude', 'codex', 'pi'])
      for (final target in const ['claude', 'codex', 'pi'])
        if (source != target)
          _scenario('built-convert-$source-to-$target-apply', 0),
  ];
  return <String, Object?>{
    'schemaVersion': 1,
    'qualificationScope': 'native-job',
    'revision': 'a' * 40,
    'selectedSdk': '3.13.2',
    'dependencyLockSha256': 'b' * 64,
    'artifact': <String, Object?>{
      'path': os == 'windows' ? 'agent_resource.exe' : 'agent_resource',
      'sha256': 'c' * 64,
      'byteLength': 1,
    },
    'environment': <String, Object?>{
      'operatingSystem': os,
      'operatingSystemVersion': 'test-runner',
      'architecture': 'x64',
      'trueDirectorySymlink': true,
    },
    'job': <String, Object?>{
      'runId': '1',
      'job': 'native-lifecycle',
      'repository': 'louiss0/agent_resource',
      'serverUrl': 'https://github.com',
    },
    'blockers': const <Object?>[],
    'results': results,
    'httpsGitQualification': <String, Object?>{
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
      'verification': 'native',
    },
    'observedStatuses': const <Object?>[0, 1, 2, 3, 4, 5, 6, 7],
    'missingStatuses': const <Object?>[],
    'deferredStatuses': const <Object?>[],
    'unverifiedLiveHarness': _liveHarness,
    'rawNativeDocumentsRetained': false,
    'runtimeActivationVerified': false,
    'runtimeEquivalenceVerified': false,
  };
}

Future<Map<String, Object?>> _decide(
  Directory temp,
  List<Map<String, Object?>> bundles,
) async {
  final paths = <String>[];
  for (var i = 0; i < bundles.length; i++) {
    final path = '${temp.path}${Platform.pathSeparator}evidence-$i.json';
    File(path).writeAsStringSync(jsonEncode(bundles[i]));
    paths.add(path);
  }
  final output = '${temp.path}${Platform.pathSeparator}release-decision.json';
  final result = await Process.run(Platform.resolvedExecutable, [
    'run',
    'test${Platform.pathSeparator}support${Platform.pathSeparator}release_decision.dart',
    output,
    ...paths,
  ]);
  final decoded =
      jsonDecode(File(output).readAsStringSync()) as Map<String, Object?>;
  decoded['_exitCode'] = result.exitCode;
  return decoded;
}

List<String> _codes(Map<String, Object?> decision) =>
    (decision['blockers']! as List<Object?>)
        .whereType<Map<String, Object?>>()
        .map((blocker) => blocker['code']! as String)
        .toList();

void main() {
  group('release evidence verification classes', () {
    test('the gate emits a verification class per check and the '
        'unverified live-harness boundary', () {
      final gate = File(
        'test${Platform.pathSeparator}support${Platform.pathSeparator}release_gate.dart',
      ).readAsStringSync();
      expect(gate, contains("'verification': 'native'"));
      expect(gate, contains("'unverifiedLiveHarness'"));
      for (final behavior in _liveHarness) {
        expect(gate, contains(behavior), reason: behavior);
      }
    });

    test('the integrated decision accepts classified evidence', () async {
      final temp = Directory.systemTemp.createTempSync('release-decision');
      addTearDown(() => temp.deleteSync(recursive: true));
      final decision = await _decide(temp, <Map<String, Object?>>[
        _bundle('windows'),
        _bundle('macos'),
        _bundle('linux'),
      ]);
      expect(_codes(decision), isEmpty, reason: jsonEncode(decision));
      expect(decision['qualified'], isTrue);
    });

    test('a check without a verification class is rejected', () async {
      final temp = Directory.systemTemp.createTempSync('release-decision');
      addTearDown(() => temp.deleteSync(recursive: true));
      final windows = _bundle('windows');
      (windows['results']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .first
          .remove('verification');
      final decision = await _decide(temp, <Map<String, Object?>>[
        windows,
        _bundle('macos'),
        _bundle('linux'),
      ]);
      expect(_codes(decision), contains('EXECUTION_EVIDENCE_INVALID'));
      expect(decision['qualified'], isFalse);
    });

    test('missing live-harness boundary is rejected', () async {
      final temp = Directory.systemTemp.createTempSync('release-decision');
      addTearDown(() => temp.deleteSync(recursive: true));
      final windows = _bundle('windows')..remove('unverifiedLiveHarness');
      final decision = await _decide(temp, <Map<String, Object?>>[
        windows,
        _bundle('macos'),
        _bundle('linux'),
      ]);
      expect(_codes(decision), contains('LIVE_HARNESS_BOUNDARY_MISSING'));
      expect(decision['qualified'], isFalse);
    });

    test('HTTPS evidence without a verification class is rejected', () async {
      final temp = Directory.systemTemp.createTempSync('release-decision');
      addTearDown(() => temp.deleteSync(recursive: true));
      final windows = _bundle('windows');
      (windows['httpsGitQualification']! as Map<String, Object?>).remove(
        'verification',
      );
      final decision = await _decide(temp, <Map<String, Object?>>[
        windows,
        _bundle('macos'),
        _bundle('linux'),
      ]);
      expect(_codes(decision), contains('VERIFICATION_CLASS_MISSING'));
      expect(decision['qualified'], isFalse);
    });
  });
}
