import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Aggregates per-native-job evidence into the only release-level verdict.
/// Per-job deferrals are accepted only when the capable Windows bundle actually
/// observed statuses 5/6 on the same revision/SDK/dependency graph.
Future<void> main(List<String> args) async {
  if (args.length < 4) {
    throw ArgumentError(
      'Usage: release_decision.dart <decision.json> <windows.json> '
      '<macos.json> <linux.json>',
    );
  }
  final output = File(args[0]);
  final evidenceHashes = <String, String>{};
  final bundles = <Map<String, Object?>>[];
  final blockers = <Map<String, Object?>>[];
  for (final path in args.skip(1)) {
    final file = File(path);
    if (!file.existsSync()) {
      blockers.add(_blocker('EVIDENCE_MISSING', 'Missing evidence: $path'));
      continue;
    }
    final bytes = file.readAsBytesSync();
    evidenceHashes[path] = sha256.convert(bytes).toString();
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, Object?>) {
      blockers.add(
        _blocker('EVIDENCE_INVALID', 'Invalid evidence object: $path'),
      );
      continue;
    }
    if (decoded['schemaVersion'] != 1 ||
        decoded['qualificationScope'] != 'native-job' ||
        decoded['rawNativeDocumentsRetained'] != false) {
      blockers.add(
        _blocker('EVIDENCE_UNSAFE', 'Unsafe evidence schema/content: $path'),
      );
    }
    bundles.add(<String, Object?>{...decoded, '_path': path});
  }

  final byOs = <String, Map<String, Object?>>{};
  final observedByOs = <String, Set<int>>{};
  for (final bundle in bundles) {
    final environment = bundle['environment'];
    final os = environment is Map<String, Object?>
        ? environment['operatingSystem']
        : null;
    if (os is! String || byOs.containsKey(os)) {
      blockers.add(
        _blocker(
          'NATIVE_JOB_AMBIGUOUS',
          'Missing or duplicate native OS evidence: $os',
        ),
      );
      continue;
    }
    byOs[os] = bundle;
    if (bundle['blockers'] is! List<Object?> ||
        (bundle['blockers']! as List<Object?>).isNotEmpty) {
      blockers.add(
        _blocker('NATIVE_JOB_BLOCKED', '$os reports mandatory blockers.'),
      );
    }
    if (bundle['revision'] is! String ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(bundle['revision']! as String)) {
      blockers.add(
        _blocker(
          'REVISION_PROVENANCE_MISSING',
          '$os lacks a committed revision.',
        ),
      );
    }
    final artifact = bundle['artifact'];
    final artifactPath = artifact is Map<String, Object?>
        ? artifact['path']
        : null;
    if (artifact is! Map<String, Object?> ||
        artifact['sha256'] is! String ||
        (artifact['sha256']! as String).isEmpty ||
        artifactPath is! String) {
      blockers.add(
        _blocker(
          'ARTIFACT_IDENTITY_MISSING',
          '$os lacks artifact integrity evidence.',
        ),
      );
    } else if ((os == 'windows' && !artifactPath.endsWith('.exe')) ||
        (os != 'windows' && artifactPath.endsWith('.exe'))) {
      blockers.add(
        _blocker(
          'ARTIFACT_PLATFORM_MISMATCH',
          '$os artifact identity does not match its native platform.',
        ),
      );
    }
    if (environment is! Map<String, Object?> ||
        !_nativeEnvironmentMatches(os, environment)) {
      blockers.add(
        _blocker(
          'NATIVE_ENVIRONMENT_MISMATCH',
          '$os environment provenance is inconsistent.',
        ),
      );
    }
    final job = bundle['job'];
    if (job is! Map<String, Object?> ||
        job['repository'] is! String ||
        (job['repository']! as String).isEmpty ||
        job['runId'] is! String ||
        (job['runId']! as String).isEmpty ||
        job['serverUrl'] is! String ||
        (job['serverUrl']! as String).isEmpty) {
      blockers.add(
        _blocker('JOB_PROVENANCE_MISSING', '$os lacks CI job provenance.'),
      );
    }

    final resultStatuses = <int>{};
    if (bundle['results'] is! List<Object?> ||
        (bundle['results']! as List<Object?>).isEmpty) {
      blockers.add(
        _blocker(
          'EXECUTION_EVIDENCE_MISSING',
          '$os has no executed scenarios.',
        ),
      );
    } else {
      for (final result in bundle['results']! as List<Object?>) {
        if (result is! Map<String, Object?> ||
            result['scenario'] is! String ||
            result['exitCode'] is! int ||
            result['rawStreamsRetained'] != false) {
          blockers.add(
            _blocker(
              'EXECUTION_EVIDENCE_INVALID',
              '$os has unsafe or incomplete scenario evidence.',
            ),
          );
          continue;
        }
        resultStatuses.add(result['exitCode']! as int);
      }
    }
    observedByOs[os] = resultStatuses;
    final claimed = <int>{
      if (bundle['observedStatuses'] is List<Object?>)
        for (final status in bundle['observedStatuses']! as List<Object?>)
          if (status is int) status,
    };
    if (!_sameStatuses(claimed, resultStatuses)) {
      blockers.add(
        _blocker(
          'STATUS_INDEX_MISMATCH',
          '$os observed-status index does not match executed results.',
        ),
      );
    }
    final deferred = <int>{
      if (bundle['deferredStatuses'] is List<Object?>)
        for (final status in bundle['deferredStatuses']! as List<Object?>)
          if (status is int) status,
    };
    if (deferred.isNotEmpty) {
      if (os == 'windows') {
        blockers.add(
          _blocker(
            'INVALID_DEFERRAL',
            'The capable Windows job cannot defer its required rare statuses.',
          ),
        );
      }
      if (deferred.any((status) => status != 5 && status != 6)) {
        blockers.add(
          _blocker('INVALID_DEFERRAL', '$os defers a status other than 5/6.'),
        );
      }
      if (bundle['deferredEvidenceScope'] != 'capable-native-windows-job') {
        blockers.add(
          _blocker(
            'DEFERRAL_PROVENANCE_MISSING',
            '$os lacks an explicit capable-job deferral scope.',
          ),
        );
      }
    }
    for (final source in const ['claude', 'codex', 'pi']) {
      for (final target in const ['claude', 'codex', 'pi']) {
        if (source == target) continue;
        final scenario = 'built-convert-$source-to-$target-apply';
        if (!_hasSuccessfulScenario(bundle, scenario)) {
          blockers.add(
            _blocker(
              'CONVERSION_EVIDENCE_MISSING',
              '$os lacks $source-to-$target publication evidence.',
            ),
          );
        }
      }
    }
  }

  for (final os in const ['windows', 'macos', 'linux']) {
    if (!byOs.containsKey(os)) {
      blockers.add(
        _blocker(
          'NATIVE_JOB_MISSING',
          'Required native $os evidence is absent.',
        ),
      );
    }
  }
  if (bundles.isNotEmpty) {
    final revision = bundles.first['revision'];
    final sdk = bundles.first['selectedSdk'];
    final lock = bundles.first['dependencyLockSha256'];
    final firstJob = bundles.first['job'];
    final runId = firstJob is Map<String, Object?> ? firstJob['runId'] : null;
    final repository = firstJob is Map<String, Object?>
        ? firstJob['repository']
        : null;
    for (final bundle in bundles.skip(1)) {
      if (bundle['revision'] != revision) {
        blockers.add(
          _blocker('REVISION_MISMATCH', 'Evidence revisions differ.'),
        );
      }
      if (bundle['selectedSdk'] != sdk) {
        blockers.add(_blocker('SDK_MISMATCH', 'Evidence SDK versions differ.'));
      }
      if (bundle['dependencyLockSha256'] != lock) {
        blockers.add(
          _blocker('DEPENDENCY_MISMATCH', 'Evidence lockfile hashes differ.'),
        );
      }
      final job = bundle['job'];
      if (job is! Map<String, Object?> ||
          job['runId'] != runId ||
          job['repository'] != repository) {
        blockers.add(
          _blocker(
            'JOB_MISMATCH',
            'Native evidence does not come from one workflow run/repository.',
          ),
        );
      }
    }
  }

  final observed = observedByOs.values.fold<Set<int>>(
    <int>{},
    (all, statuses) => all..addAll(statuses),
  );
  for (var status = 0; status <= 7; status++) {
    if (!observed.contains(status)) {
      blockers.add(
        _blocker(
          'PRODUCTION_STATUS_EVIDENCE_MISSING',
          'No native bundle observed status $status.',
          status,
        ),
      );
    }
  }
  final windowsObserved = observedByOs['windows'] ?? const <int>{};
  for (final bundle in bundles) {
    if (bundle['deferredStatuses'] is! List<Object?>) continue;
    for (final status in bundle['deferredStatuses']! as List<Object?>) {
      if (status is int && !windowsObserved.contains(status)) {
        blockers.add(
          _blocker(
            'DEFERRED_EVIDENCE_MISSING',
            'Deferred status $status was not observed on native Windows.',
            status,
          ),
        );
      }
    }
  }
  final windows = byOs['windows'];
  final windowsEnvironment = windows?['environment'];
  if (windowsEnvironment is! Map<String, Object?> ||
      windowsEnvironment['trueDirectorySymlink'] != true ||
      windows == null ||
      !_hasSuccessfulScenario(windows, 'built-skill-link-install')) {
    blockers.add(
      _blocker(
        'WINDOWS_DIRECTORY_SYMLINK_UNAVAILABLE',
        'True Windows directory-symlink evidence is missing.',
      ),
    );
  }

  final result = <String, Object?>{
    'schemaVersion': 1,
    'qualificationScope': 'integrated-native-release',
    'revision': bundles.isEmpty ? null : bundles.first['revision'],
    'selectedSdk': bundles.isEmpty ? null : bundles.first['selectedSdk'],
    'dependencyLockSha256': bundles.isEmpty
        ? null
        : bundles.first['dependencyLockSha256'],
    'evidenceSha256': evidenceHashes,
    'artifactSha256': <String, Object?>{
      for (final entry in byOs.entries) entry.key: _artifactHash(entry.value),
    },
    'observedStatuses': observed.toList()..sort(),
    'blockers': blockers,
    'qualified': blockers.isEmpty,
    'runtimeActivationVerified': false,
    'runtimeEquivalenceVerified': false,
  };
  output.parent.createSync(recursive: true);
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(result)}\n',
  );
  stdout.writeln('Release decision: ${output.path}');
  stdout.writeln(
    'Qualified: ${blockers.isEmpty}; blockers: ${blockers.length}',
  );
  if (blockers.isNotEmpty) exitCode = 2;
}

bool _nativeEnvironmentMatches(String os, Map<String, Object?> environment) {
  final operatingSystem = environment['operatingSystem'];
  final version = environment['operatingSystemVersion'];
  final architecture = environment['architecture'];
  if (operatingSystem != os ||
      version is! String ||
      version.isEmpty ||
      architecture is! String ||
      architecture.isEmpty ||
      architecture == 'unknown') {
    return false;
  }
  // macOS Dart may report only "Version … (Build …)" rather than naming
  // macOS or Darwin. The explicit Platform.operatingSystem field is the
  // native identity; the version string need only be present and nonempty.
  return true;
}

bool _sameStatuses(Set<int> left, Set<int> right) =>
    left.length == right.length && left.containsAll(right);

bool _hasSuccessfulScenario(Map<String, Object?> bundle, String scenario) {
  if (bundle['results'] is! List<Object?>) return false;
  return (bundle['results']! as List<Object?>).any(
    (result) =>
        result is Map<String, Object?> &&
        result['scenario'] == scenario &&
        result['exitCode'] == 0,
  );
}

Object? _artifactHash(Map<String, Object?> bundle) {
  final artifact = bundle['artifact'];
  return artifact is Map<String, Object?> ? artifact['sha256'] : null;
}

Map<String, Object?> _blocker(String code, String message, [int? status]) =>
    <String, Object?>{'code': code, 'status': status, 'message': message};
