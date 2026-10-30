import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const _maximumLockBytes = 8 * 1024 * 1024;
const _maximumJsonDepth = 32;
const _maximumJsonNodes = 100000;

/// The versioned, machine-local pack records stored beside installations.
final class PackLockDocument {
  PackLockDocument({
    required this.installations,
    required this.packs,
    required this.snapshots,
    required this.approvals,
    required this.selections,
    required this.operations,
  });

  factory PackLockDocument.empty() => PackLockDocument(
    installations: <Map<String, Object?>>[],
    packs: <Map<String, Object?>>[],
    snapshots: <Map<String, Object?>>[],
    approvals: <Map<String, Object?>>[],
    selections: <Map<String, Object?>>[],
    operations: <Map<String, Object?>>[],
  );

  final int schemaVersion = 1;
  final List<Map<String, Object?>> installations;
  final List<Map<String, Object?>> packs;
  final List<Map<String, Object?>> snapshots;
  final List<Map<String, Object?>> approvals;
  final List<Map<String, Object?>> selections;
  final List<Map<String, Object?>> operations;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'installations': installations,
    'packs': packs,
    'snapshots': snapshots,
    'approvals': approvals,
    'selections': selections,
    'operations': operations,
  };
}

final class RecordedSnapshot {
  const RecordedSnapshot({
    required this.ref,
    required this.installationId,
    required this.installedAt,
    required this.activations,
    required this.contentDigest,
    required this.baseline,
    required this.sourceEvidence,
    required this.contentAvailable,
    this.noncurrentAt,
    this.retentionClass = 'source',
  });

  factory RecordedSnapshot.fromJson(Map<String, Object?> json) {
    final activations = json['activations'];
    final baseline = json['baseline'];
    final source = json['sourceEvidence'];
    final available = json['contentAvailable'];
    final noncurrent = json['noncurrentAt'];
    final retention = json['retentionClass'] ?? 'source';
    final digest = _requiredString(json, 'contentDigest');
    if (activations is! List || activations.any((value) => value is! String)) {
      throw const FormatException('Invalid snapshot activation history.');
    }
    if (baseline is! List) {
      throw const FormatException('Invalid snapshot baseline.');
    }
    if (source is! Map<String, Object?> || available is! bool) {
      throw const FormatException('Invalid snapshot evidence or availability.');
    }
    if (noncurrent != null && noncurrent is! String) {
      throw const FormatException('Invalid snapshot noncurrent timestamp.');
    }
    if (retention != 'source' && retention != 'localEdit') {
      throw const FormatException('Invalid snapshot retention class.');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw const FormatException('Invalid snapshot content digest.');
    }
    return RecordedSnapshot(
      ref: _requiredString(json, 'ref'),
      installationId: _requiredString(json, 'installationId'),
      installedAt: _requiredString(json, 'installedAt'),
      activations: List<String>.unmodifiable(activations.cast<String>()),
      contentDigest: digest,
      baseline: _records(baseline, 'snapshot baseline'),
      sourceEvidence: Map<String, Object?>.unmodifiable(source),
      contentAvailable: available,
      noncurrentAt: noncurrent as String?,
      retentionClass: retention as String,
    );
  }

  final String ref;
  final String installationId;
  final String installedAt;
  final List<String> activations;
  final String contentDigest;
  final List<Map<String, Object?>> baseline;
  final Map<String, Object?> sourceEvidence;
  Map<String, Object?> get editedEvidence => sourceEvidence;
  final bool contentAvailable;
  final String? noncurrentAt;
  final String retentionClass;

  Map<String, Object?> toJson() => <String, Object?>{
    'ref': ref,
    'installationId': installationId,
    'installedAt': installedAt,
    'activations': activations,
    'contentDigest': contentDigest,
    'baseline': baseline,
    'sourceEvidence': sourceEvidence,
    'contentAvailable': contentAvailable,
    'noncurrentAt': noncurrentAt,
    'retentionClass': retentionClass,
  };
}

/// Persistence and Recorded snapshot refs for the pack lifecycle service.
/// Reads and planning are nonmutating; only explicit record/cleanup calls write.
final class PackState {
  static final _random = Random.secure();

  PackState({required String stateDirectory, DateTime Function()? clock})
    : stateDirectory = p.normalize(stateDirectory),
      _clock = clock ?? DateTime.now;

  final String stateDirectory;
  final DateTime Function() _clock;

  String get lockPath => p.join(stateDirectory, 'installations.json');

  void updateRecordGroups({
    List<Map<String, Object?>>? packs,
    List<Map<String, Object?>>? approvals,
    List<Map<String, Object?>>? selections,
    List<Map<String, Object?>>? operations,
  }) {
    final current = read();
    final updated = PackLockDocument(
      installations: current.installations,
      packs: packs ?? current.packs,
      snapshots: current.snapshots,
      approvals: approvals ?? current.approvals,
      selections: selections ?? current.selections,
      operations: operations ?? current.operations,
    );
    _write(updated, updated.snapshots);
  }

  List<RecordedSnapshot> snapshots({String? installationId}) => [
    for (final record in read().snapshots)
      if (installationId == null || record['installationId'] == installationId)
        _available(RecordedSnapshot.fromJson(record)),
  ];

  String snapshotArtifactPath({
    required String installationId,
    required String ref,
  }) {
    final selected = snapshot(installationId: installationId, ref: ref);
    if (!selected.contentAvailable) {
      throw StateError(
        'Recorded snapshot content is unavailable locally: $ref',
      );
    }
    return p.join(
      stateDirectory,
      'snapshots',
      selected.contentDigest,
      'artifact',
    );
  }

  RecordedSnapshot snapshot({
    required String installationId,
    required String ref,
  }) {
    final matches = snapshots(installationId: installationId)
        .where((snapshot) => snapshot.ref == ref);
    if (matches.isEmpty) {
      throw FormatException(
        'Recorded snapshot ref does not belong to installation $installationId: $ref',
      );
    }
    if (matches.length != 1) {
      throw const FormatException('Duplicate Recorded snapshot ref.');
    }
    return matches.single;
  }

  RecordedSnapshot _available(RecordedSnapshot snapshot) => RecordedSnapshot(
    ref: snapshot.ref,
    installationId: snapshot.installationId,
    installedAt: snapshot.installedAt,
    activations: snapshot.activations,
    contentDigest: snapshot.contentDigest,
    baseline: snapshot.baseline,
    sourceEvidence: snapshot.sourceEvidence,
    contentAvailable:
        snapshot.contentAvailable &&
        Directory(
          p.join(
            stateDirectory,
            'snapshots',
            snapshot.contentDigest,
            'artifact',
          ),
        ).existsSync() &&
        _artifactDigest(
              p.join(
                stateDirectory,
                'snapshots',
                snapshot.contentDigest,
                'artifact',
              ),
            ) ==
            snapshot.contentDigest,
    noncurrentAt: snapshot.noncurrentAt,
    retentionClass: snapshot.retentionClass,
  );

  void markInstallationNoncurrent(String installationId) {
    final document = read();
    final timestamp = _timestamp(_clock());
    final snapshots = [
      for (final record in document.snapshots)
        RecordedSnapshot.fromJson(record),
    ];
    if (!snapshots.any(
      (snapshot) =>
          snapshot.installationId == installationId &&
          snapshot.noncurrentAt == null,
    )) {
      return;
    }
    _write(document, [
      for (final snapshot in snapshots)
        if (snapshot.installationId == installationId &&
            snapshot.noncurrentAt == null)
          _noncurrent(snapshot, timestamp).toJson()
        else
          snapshot.toJson(),
    ]);
  }

  RecordedSnapshot recordLocalEdit({
    required String installationId,
    required String artifactPath,
    required List<Map<String, Object?>> baseline,
    required Map<String, Object?> editedEvidence,
  }) {
    if (installationId.trim().isEmpty) {
      throw ArgumentError.value(
        installationId,
        'installationId',
        'Must not be blank.',
      );
    }
    final now = _clock().toUtc();
    final timestamp = _timestamp(now);
    final digest = _artifactDigest(artifactPath);
    final document = read();
    final snapshots = [
      for (final record in document.snapshots)
        RecordedSnapshot.fromJson(record),
    ];
    final existing = snapshots.where(
      (snapshot) =>
          snapshot.installationId == installationId &&
          snapshot.contentDigest == digest &&
          snapshot.retentionClass == 'localEdit',
    );
    _retainArtifact(
      artifactPath,
      p.join(stateDirectory, 'snapshots', digest, 'artifact'),
    );
    if (existing.isNotEmpty) {
      final original = existing.first;
      final updated = RecordedSnapshot(
        ref: original.ref,
        installationId: original.installationId,
        installedAt: original.installedAt,
        activations: [...original.activations, timestamp],
        contentDigest: original.contentDigest,
        baseline: original.baseline,
        sourceEvidence: original.sourceEvidence,
        contentAvailable: true,
        noncurrentAt: original.noncurrentAt,
        retentionClass: 'localEdit',
      );
      _write(document, [
        for (final snapshot in snapshots)
          if (snapshot == original) updated.toJson() else snapshot.toJson(),
      ]);
      return updated;
    }
    final snapshot = RecordedSnapshot(
      ref: _newRef(now, digest, snapshots),
      installationId: installationId,
      installedAt: timestamp,
      activations: [timestamp],
      contentDigest: digest,
      baseline: baseline,
      sourceEvidence: editedEvidence,
      contentAvailable: true,
      noncurrentAt: timestamp,
      retentionClass: 'localEdit',
    );
    _write(document, [...document.snapshots, snapshot.toJson()]);
    return snapshot;
  }

  List<String> cleanup({
    int retentionDays = 90,
    bool localEdits = false,
    Set<String> activeRecoveryRefs = const <String>{},
    Set<String>? installationIds,
    bool dryRun = false,
  }) {
    if (retentionDays < 1 || retentionDays > 36500) {
      throw ArgumentError.value(
        retentionDays,
        'retentionDays',
        'Must be 1..36500.',
      );
    }
    final document = read();
    final snapshots = [
      for (final record in document.snapshots)
        RecordedSnapshot.fromJson(record),
    ];
    final now = _clock().toUtc();
    final protectedRefs = _protectedRefs(document, activeRecoveryRefs);
    final candidates = <RecordedSnapshot>[];
    for (final snapshot in snapshots) {
      if (installationIds != null &&
          !installationIds.contains(snapshot.installationId)) {
        continue;
      }
      if (!snapshot.contentAvailable || protectedRefs.contains(snapshot.ref)) {
        continue;
      }
      if (snapshot.retentionClass == 'localEdit') {
        if (localEdits) candidates.add(snapshot);
        continue;
      }
      final noncurrent = snapshot.noncurrentAt;
      if (noncurrent == null) continue;
      final transition = DateTime.tryParse(noncurrent)?.toUtc();
      if (transition == null) {
        throw const FormatException('Invalid snapshot noncurrent timestamp.');
      }
      if (!now.isBefore(transition.add(Duration(days: retentionDays)))) {
        candidates.add(snapshot);
      }
    }
    final candidateDigests = candidates
        .map((snapshot) => snapshot.contentDigest)
        .toSet();
    final protectedDigests = snapshots
        .where((snapshot) => !candidates.contains(snapshot))
        .map((snapshot) => snapshot.contentDigest)
        .toSet();
    final prunable = candidates
        .where((snapshot) => !protectedDigests.contains(snapshot.contentDigest))
        .toList();
    if (prunable.isEmpty) return const <String>[];
    final pruned = prunable.toSet();
    final prunedRefs = prunable.map((snapshot) => snapshot.ref).toSet();
    if (dryRun) return List<String>.unmodifiable(prunedRefs);
    for (final digest in candidateDigests.intersection(
      prunable.map((snapshot) => snapshot.contentDigest).toSet(),
    )) {
      final root = Directory(p.join(stateDirectory, 'snapshots', digest));
      if (root.existsSync()) root.deleteSync(recursive: true);
    }
    _write(document, [
      for (final snapshot in snapshots)
        if (pruned.contains(snapshot))
          RecordedSnapshot(
            ref: snapshot.ref,
            installationId: snapshot.installationId,
            installedAt: snapshot.installedAt,
            activations: snapshot.activations,
            contentDigest: snapshot.contentDigest,
            baseline: snapshot.baseline,
            sourceEvidence: snapshot.sourceEvidence,
            contentAvailable: false,
            noncurrentAt: snapshot.noncurrentAt,
            retentionClass: snapshot.retentionClass,
          ).toJson()
        else
          snapshot.toJson(),
    ]);
    return List<String>.unmodifiable(prunedRefs);
  }

  RecordedSnapshot recordSnapshot({
    required String installationId,
    required String artifactPath,
    required List<Map<String, Object?>> baseline,
    required Map<String, Object?> sourceEvidence,
  }) {
    if (installationId.trim().isEmpty) {
      throw ArgumentError.value(
        installationId,
        'installationId',
        'Must not be blank.',
      );
    }
    final now = _clock().toUtc();
    final timestamp = _timestamp(now);
    final digest = _artifactDigest(artifactPath);
    final document = read();
    final snapshots = [
      for (final record in document.snapshots)
        RecordedSnapshot.fromJson(record),
    ];
    final existing = snapshots.where(
      (snapshot) =>
          snapshot.installationId == installationId &&
          snapshot.contentDigest == digest &&
          snapshot.retentionClass == 'source',
    );
    final retainedDirectory = p.join(
      stateDirectory,
      'snapshots',
      digest,
      'artifact',
    );
    _retainArtifact(artifactPath, retainedDirectory);
    if (existing.isNotEmpty) {
      final original = existing.first;
      final updated = RecordedSnapshot(
        ref: original.ref,
        installationId: original.installationId,
        installedAt: original.installedAt,
        activations: [...original.activations, timestamp],
        contentDigest: original.contentDigest,
        baseline: original.baseline,
        sourceEvidence: original.sourceEvidence,
        contentAvailable: true,
        noncurrentAt: null,
        retentionClass: original.retentionClass,
      );
      _write(document, [
        for (final snapshot in snapshots)
          if (snapshot == original)
            updated.toJson()
          else if (snapshot.installationId == installationId &&
              snapshot.noncurrentAt == null)
            _noncurrent(snapshot, timestamp).toJson()
          else
            snapshot.toJson(),
      ]);
      return updated;
    }
    final snapshot = RecordedSnapshot(
      ref: _newRef(now, digest, snapshots),
      installationId: installationId,
      installedAt: timestamp,
      activations: [timestamp],
      contentDigest: digest,
      baseline: baseline,
      sourceEvidence: sourceEvidence,
      contentAvailable: true,
    );
    _write(document, [
      for (final current in snapshots)
        if (current.installationId == installationId &&
            current.noncurrentAt == null)
          _noncurrent(current, timestamp).toJson()
        else
          current.toJson(),
      snapshot.toJson(),
    ]);
    return snapshot;
  }

  void _write(PackLockDocument document, List<Map<String, Object?>> snapshots) {
    final json = <String, Object?>{
      'schemaVersion': 1,
      'installations': document.installations,
      'packs': document.packs,
      'snapshots': snapshots,
      'approvals': document.approvals,
      'selections': document.selections,
      'operations': document.operations,
    };
    final bytes = utf8.encode(jsonEncode(json));
    if (bytes.length > _maximumLockBytes) {
      throw const FormatException('Installation ledger update exceeds 8 MiB.');
    }
    Directory(stateDirectory).createSync(recursive: true);
    final temporary = '$lockPath.${_random.nextInt(1 << 32)}.tmp';
    try {
      File(temporary).writeAsBytesSync(bytes, flush: true);
      File(temporary).renameSync(lockPath);
    } catch (_) {
      if (File(temporary).existsSync()) File(temporary).deleteSync();
      rethrow;
    }
  }

  PackLockDocument read() {
    if (FileSystemEntity.typeSync(lockPath, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return PackLockDocument.empty();
    }
    if (FileSystemEntity.typeSync(lockPath, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FormatException(
        'Installation ledger is not a regular file: $lockPath',
      );
    }
    final file = File(lockPath).openSync();
    final List<int> bytes;
    try {
      bytes = file.readSync(_maximumLockBytes + 1);
    } finally {
      file.closeSync();
    }
    if (bytes.length > _maximumLockBytes) {
      throw const FormatException('Installation ledger exceeds 8 MiB.');
    }
    final Object? decoded;
    try {
      decoded = _BoundedJsonParser(utf8.decode(bytes, allowMalformed: false))
          .parse();
    } on FormatException catch (error) {
      throw FormatException('Invalid installation ledger: ${error.message}');
    }
    final root = _object(decoded, 'installation ledger');
    if (root['schemaVersion'] != 1) {
      throw const FormatException(
        'Unsupported installation ledger schema. Use a compatible previous '
        'Agent Resource CLI to recover or remove this state; it was not modified.',
      );
    }
    return PackLockDocument(
      installations: _records(root['installations'], 'installations'),
      packs: _records(root['packs'] ?? const [], 'packs'),
      snapshots: _records(root['snapshots'] ?? const [], 'snapshots'),
      approvals: _records(root['approvals'] ?? const [], 'approvals'),
      selections: _records(root['selections'] ?? const [], 'selections'),
      operations: _records(root['operations'] ?? const [], 'operations'),
    );
  }
}

Set<String> _protectedRefs(
  PackLockDocument document,
  Set<String> explicitRecoveryRefs,
) {
  final refs = <String>{...explicitRecoveryRefs};
  void addRefs(Map<String, Object?> record) {
    for (final key in const [
      'snapshotRef',
      'currentSnapshotRef',
      'recoverySnapshotRef',
    ]) {
      final value = record[key];
      if (value is String) refs.add(value);
    }
    for (final key in const ['snapshotRefs', 'recoverySnapshotRefs']) {
      final value = record[key];
      if (value is List) refs.addAll(value.whereType<String>());
    }
  }

  for (final installation in document.installations) {
    if (installation['lifecycle'] != 'removed') addRefs(installation);
  }
  for (final operation in document.operations) {
    final active =
        operation['recovery'] == 'active' ||
        operation['recoveryRequired'] == true ||
        operation['status'] == 'active' ||
        operation['status'] == 'pending' ||
        operation['status'] == 'recoveryRequired';
    if (active) addRefs(operation);
  }
  return refs;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Snapshot $key must be a non-empty string.');
  }
  return value;
}

String _timestamp(DateTime value) => value.toUtc().toIso8601String();

String _refPrefix(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year.toString().padLeft(4, '0')}${two(value.month)}${two(value.day)}'
      'T${two(value.hour)}${two(value.minute)}${two(value.second)}.'
      '${value.millisecond.toString().padLeft(3, '0')}Z';
}

String _newRef(DateTime now, String digest, List<RecordedSnapshot> snapshots) {
  final prefix = _refPrefix(now);
  final refs = snapshots.map((snapshot) => snapshot.ref).toSet();
  var length = 8;
  while (refs.contains('$prefix~${digest.substring(0, length)}') &&
      length < digest.length) {
    length++;
  }
  return '$prefix~${digest.substring(0, length)}';
}

RecordedSnapshot _noncurrent(RecordedSnapshot snapshot, String timestamp) =>
    RecordedSnapshot(
      ref: snapshot.ref,
      installationId: snapshot.installationId,
      installedAt: snapshot.installedAt,
      activations: snapshot.activations,
      contentDigest: snapshot.contentDigest,
      baseline: snapshot.baseline,
      sourceEvidence: snapshot.sourceEvidence,
      contentAvailable: snapshot.contentAvailable,
      noncurrentAt: timestamp,
      retentionClass: snapshot.retentionClass,
    );

String _artifactDigest(String artifactPath) {
  final type = FileSystemEntity.typeSync(artifactPath, followLinks: false);
  if (type != FileSystemEntityType.directory) {
    throw ArgumentError.value(
      artifactPath,
      'artifactPath',
      'Must be a directory.',
    );
  }
  final entries = Directory(artifactPath).listSync(
    recursive: true,
    followLinks: false,
  )..sort((left, right) => left.path.compareTo(right.path));
  final output = BytesBuilder(copy: false);
  for (final entry in entries) {
    final relative = p.relative(entry.path, from: artifactPath);
    final entryType = FileSystemEntity.typeSync(entry.path, followLinks: false);
    if (entryType == FileSystemEntityType.link) {
      throw FormatException(
        'Snapshot artifacts cannot contain links: $relative',
      );
    }
    output.add(utf8.encode('$relative\x00$entryType\x00'));
    if (entryType == FileSystemEntityType.file) {
      output.add(File(entry.path).readAsBytesSync());
    }
    output.add(const [0]);
  }
  return sha256.convert(output.takeBytes()).toString();
}

void _retainArtifact(String source, String destination) {
  if (FileSystemEntity.typeSync(destination, followLinks: false) ==
      FileSystemEntityType.directory) {
    if (_artifactDigest(destination) == _artifactDigest(source)) return;
    throw FormatException(
      'Retained snapshot content does not match its digest.',
    );
  }
  final staging = '$destination.staging';
  if (FileSystemEntity.typeSync(staging, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError('Snapshot staging path already exists: $staging');
  }
  Directory(staging).createSync(recursive: true);
  try {
    _copyDirectory(source, staging);
    if (_artifactDigest(staging) != _artifactDigest(source)) {
      throw StateError('Retained snapshot verification failed.');
    }
    Directory(p.dirname(destination)).createSync(recursive: true);
    Directory(staging).renameSync(destination);
  } catch (_) {
    if (Directory(staging).existsSync()) {
      Directory(staging).deleteSync(recursive: true);
    }
    rethrow;
  }
}

void _copyDirectory(String source, String destination) {
  for (final entry in Directory(source).listSync(followLinks: false)) {
    final target = p.join(destination, p.basename(entry.path));
    final type = FileSystemEntity.typeSync(entry.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      Directory(target).createSync();
      _copyDirectory(entry.path, target);
    } else if (type == FileSystemEntityType.file) {
      File(entry.path).copySync(target);
    } else {
      throw FormatException(
        'Unsupported snapshot artifact entry: ${entry.path}',
      );
    }
  }
}

List<Map<String, Object?>> _records(Object? value, String label) {
  if (value is! List) {
    throw FormatException('$label must be an array.');
  }
  return List<Map<String, Object?>>.unmodifiable([
    for (final record in value) _object(record, '$label record'),
  ]);
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$label must be an object.');
  }
  return Map<String, Object?>.unmodifiable(value);
}

final class _BoundedJsonParser {
  _BoundedJsonParser(this.input);

  final String input;
  var index = 0;
  var nodes = 0;

  Object? parse() {
    final value = _value(0);
    _space();
    if (index != input.length) _fail();
    return value;
  }

  Object? _value(int depth) {
    if (++nodes > _maximumJsonNodes || depth > _maximumJsonDepth) _fail();
    _space();
    if (index >= input.length) _fail();
    switch (input.codeUnitAt(index)) {
      case 0x7b:
        return _object(depth);
      case 0x5b:
        return _array(depth);
      case 0x22:
        return _string();
      case 0x74:
        _literal('true');
        return true;
      case 0x66:
        _literal('false');
        return false;
      case 0x6e:
        _literal('null');
        return null;
      default:
        return _number();
    }
  }

  Map<String, Object?> _object(int depth) {
    final result = <String, Object?>{};
    index++;
    _space();
    if (_take(0x7d)) return result;
    while (true) {
      _space();
      if (index >= input.length || input.codeUnitAt(index) != 0x22) _fail();
      final key = _string();
      _space();
      if (!_take(0x3a)) _fail();
      result[key] = _value(depth + 1);
      _space();
      if (_take(0x7d)) return result;
      if (!_take(0x2c)) _fail();
    }
  }

  List<Object?> _array(int depth) {
    final result = <Object?>[];
    index++;
    _space();
    if (_take(0x5d)) return result;
    while (true) {
      result.add(_value(depth + 1));
      _space();
      if (_take(0x5d)) return result;
      if (!_take(0x2c)) _fail();
    }
  }

  String _string() {
    index++;
    final output = StringBuffer();
    while (index < input.length) {
      final code = input.codeUnitAt(index++);
      if (code == 0x22) return output.toString();
      if (code < 0x20) _fail();
      if (code != 0x5c) {
        output.writeCharCode(code);
        continue;
      }
      if (index >= input.length) _fail();
      final escaped = input.codeUnitAt(index++);
      const escapes = <int, String>{
        0x22: '"',
        0x5c: r'\',
        0x2f: '/',
        0x62: '\b',
        0x66: '\f',
        0x6e: '\n',
        0x72: '\r',
        0x74: '\t',
      };
      if (escapes.containsKey(escaped)) {
        output.write(escapes[escaped]);
      } else if (escaped == 0x75) {
        if (index + 4 > input.length) _fail();
        final hex = input.substring(index, index + 4);
        if (!RegExp(r'^[0-9a-fA-F]{4}$').hasMatch(hex)) _fail();
        output.writeCharCode(int.parse(hex, radix: 16));
        index += 4;
      } else {
        _fail();
      }
    }
    _fail();
  }

  num _number() {
    final match = RegExp(
      r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
    ).matchAsPrefix(input, index);
    if (match == null) _fail();
    index = match.end;
    return num.parse(match.group(0)!);
  }

  void _literal(String value) {
    if (!input.startsWith(value, index)) _fail();
    index += value.length;
  }

  void _space() {
    while (index < input.length &&
        const <int>[0x20, 0x09, 0x0a, 0x0d].contains(input.codeUnitAt(index))) {
      index++;
    }
  }

  bool _take(int code) {
    if (index < input.length && input.codeUnitAt(index) == code) {
      index++;
      return true;
    }
    return false;
  }

  Never _fail() => throw FormatException('Invalid JSON at offset $index.');
}
