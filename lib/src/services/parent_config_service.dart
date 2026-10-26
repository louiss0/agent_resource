import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'lifecycle_state_service.dart';

const parentDocumentLimit = 8 * 1024 * 1024;
const parentDepthLimit = 64;
const parentNodeLimit = 100000;
const parentPlanFileLimit = 16;
const parentPlanAggregateLimit = 32 * 1024 * 1024;

enum ParentHarness { claude, codex }

enum ParentLayer { user, project, profile }

enum ParentOperation { inspect, plan, apply }

enum ParentAction { set, add, remove }

final class ParentChange {
  const new({required this.unit, required this.action, required this.value});

  final String unit;
  final ParentAction action;
  final Object? value;

  Map<String, Object?> canonical() => <String, Object?>{
    'unit': unit,
    'action': action.name,
    'value': value,
  };
}

final class ParentRequest {
  const new({
    required this.operation,
    required this.harness,
    required this.scope,
    required this.layer,
    required this.file,
    required this.changes,
    this.profile,
    this.planId,
    this.clientsStopped = false,
    this.adopt = false,
    this.affected = const <String>[],
  });

  final ParentOperation operation;
  final ParentHarness harness;
  final LifecycleScope scope;
  final ParentLayer layer;
  final String file;
  final List<ParentChange> changes;
  final String? profile;
  final String? planId;
  final bool clientsStopped;
  final bool adopt;
  final List<String> affected;
}

final class ParentResult {
  const new({
    required this.command,
    required this.outcome,
    required this.data,
    this.diagnostics = const <Map<String, Object?>>[],
  });

  final String command;
  final String outcome;
  final Map<String, Object?> data;
  final List<Map<String, Object?>> diagnostics;

  Map<String, Object?> envelope() => <String, Object?>{
    'schemaVersion': 1,
    'command': command,
    'outcome': outcome,
    'data': data,
    'diagnostics': diagnostics,
  };

  String renderText() {
    final buffer = StringBuffer()..writeln('$command: $outcome');
    void render(Object? value, String indent) {
      if (value is Map) {
        for (final entry in value.entries) {
          if (entry.value is Map || entry.value is List) {
            buffer.writeln('$indent${entry.key}:');
            render(entry.value, '$indent  ');
          } else {
            buffer.writeln('$indent${entry.key}: ${entry.value}');
          }
        }
      } else if (value is List) {
        if (value.isEmpty) buffer.writeln('$indent[]');
        for (final item in value) {
          buffer.writeln('$indent-');
          render(item, '$indent  ');
        }
      } else {
        buffer.writeln('$indent$value');
      }
    }

    render(data, '');
    return buffer.toString();
  }
}

final class ParentConfigService {
  ParentConfigService({this.io = const LifecycleIO()});

  final LifecycleIO io;
  static final _inProcess = <String, Future<void>>{};

  Future<ParentResult> inspect({
    required ParentRequest request,
    required LifecycleOptions options,
  }) async {
    final context = _ParentContext.resolve(request, options);
    final source = _readSource(context);
    final selected = <Map<String, Object?>>[];
    for (final change in request.changes) {
      _validateChange(context.harness, change);
      final value = _selectedUnit(context, source, change.unit);
      selected.add(<String, Object?>{
        'unit': change.unit,
        ..._redactedUnit(change.unit, value),
      });
    }
    return ParentResult(
      command: 'agent config inspect',
      outcome: 'inspected',
      data: <String, Object?>{
        'harness': context.harness.name,
        'scope': context.scope.name,
        'layer': context.layer.name,
        'profile': context.profile,
        'file': context.file,
        'exists': source != null,
        'eligibility': 'eligible',
        'authority': 'ordinary-user-file',
        'fingerprint': source?.digest,
        'selectedUnits': selected,
        'runtime': 'notVerified',
        'writes': false,
      },
    );
  }

  Future<ParentResult> plan({
    required ParentRequest request,
    required LifecycleOptions options,
  }) async {
    if (request.changes.isEmpty) {
      throw MambaException('A parent plan requires at least one change.');
    }
    final context = _ParentContext.resolve(request, options);
    final source = _readSource(context);
    final records = _readRecords(context.stateRoot);
    _checkOwnership(context, records, request);
    final planned = <Map<String, Object?>>[];
    final proposed = <String, Object?>{};
    for (final change in request.changes) {
      _validateChange(context.harness, change);
      final before = _selectedUnit(context, source, change.unit);
      final after = _applyIntent(before, change, context);
      planned.add(<String, Object?>{
        'unit': change.unit,
        'action': change.action.name,
        'before': _redactedUnit(change.unit, before),
        'after': _redactedUnit(change.unit, after),
        'ownership': request.adopt ? 'adopt' : 'managed',
        'conflict': false,
      });
      proposed[change.unit] = after;
    }
    final candidate = _patch(context, source, request.changes, proposed);
    _validateCandidate(context, candidate, proposed);
    final planId = _planId(context, source, request, planned);
    return ParentResult(
      command: 'agent config plan',
      outcome: 'planned',
      data: <String, Object?>{
        'planId': planId,
        'harness': context.harness.name,
        'scope': context.scope.name,
        'layer': context.layer.name,
        'profile': context.profile,
        'file': context.file,
        'sourceFingerprint': source?.digest,
        'candidateFingerprint': sha256.convert(candidate).toString(),
        'changes': planned,
        'knownAffected': request.affected,
        'impacts': _impacts(context, request),
        'backupExpected': source != null,
        'approvalRequired': true,
        'clientsStoppedAcknowledgementRequired': true,
        'writes': false,
      },
    );
  }

  Future<ParentResult> apply({
    required ParentRequest request,
    required LifecycleOptions options,
  }) async {
    if (!request.clientsStopped) {
      throw MambaException(
        'Parent configuration apply requires --clients-stopped acknowledgement.',
        exitCode: 4,
      );
    }
    if (!options.approved) {
      throw MambaException(
        'Parent configuration apply requires explicit approval.',
        exitCode: 4,
      );
    }
    if (request.planId == null || request.planId!.isEmpty) {
      throw MambaException('Parent apply requires the reviewed --plan ID.');
    }
    final planRequest = ParentRequest(
      operation: ParentOperation.plan,
      harness: request.harness,
      scope: request.scope,
      layer: request.layer,
      file: request.file,
      profile: request.profile,
      changes: request.changes,
      adopt: request.adopt,
      affected: request.affected,
    );
    final context = _ParentContext.resolve(request, options);
    final current = _readSource(context);
    final records = _readRecords(context.stateRoot);
    _checkOwnership(context, records, request);
    final reconstructed = await plan(request: planRequest, options: options);
    final expectedPlanId = reconstructed.data['planId'];
    if (expectedPlanId != request.planId) {
      throw MambaException(
        'The plan ID does not match current source, context, changes, and decisions.',
        exitCode: 4,
      );
    }
    final candidate = _patch(
      context,
      current,
      request.changes,
      <String, Object?>{
        for (final change in request.changes)
          change.unit: _applyIntent(
            _selectedUnit(context, current, change.unit),
            change,
            context,
          ),
      },
    );
    return _serialized(context.stateRoot, () async {
      final source = _readSource(context);
      if (source?.digest != current?.digest) {
        throw MambaException(
          'The parent document changed after planning; no automatic rebase exists.',
          exitCode: 4,
        );
      }
      final backup = source == null
          ? null
          : _createBackup(
              context,
              source,
              request,
              currentUnits: _unitEvidence(
                context,
                source,
                request.changes.map((change) => change.unit).toSet(),
              ),
            );
      final parentId = _matchingParentId(context);
      final transactionId = _newId('ptr');
      final transaction = p.join(
        context.stateRoot,
        'parent-transactions',
        '$transactionId.json',
      );
      final staged = _stagingPath(context, transactionId);
      var liveChanged = false;
      try {
        _privateDirectory(context.stateRoot);
        _privateDirectory(p.dirname(transaction));
        _privateDirectory(p.dirname(staged));
        io.write(staged, candidate);
        _validateCandidate(
          context,
          io.read(staged, parentDocumentLimit),
          <String, Object?>{
            for (final change in request.changes)
              change.unit: _unitValueFromText(context, candidate, change.unit),
          },
        );
        _writeJson(transaction, <String, Object?>{
          'schemaVersion': 1,
          'transactionId': transactionId,
          'parentId': parentId,
          'operation': 'config-apply',
          'file': context.file,
          'scope': context.scope.name,
          'backupId': backup?.backupId,
          'sourceFingerprint': source?.digest,
          'candidateFingerprint': sha256.convert(candidate).toString(),
          'phase': 'prepared',
        });
        if (io.type(context.file, followLinks: false) !=
            FileSystemEntityType.notFound) {
          final quarantine = _quarantinePath(context, transactionId);
          _privateDirectory(p.dirname(quarantine));
          io.rename(context.file, quarantine);
          liveChanged = true;
        }
        io.createDirectory(p.dirname(context.file));
        io.rename(staged, context.file);
        _advance(transaction, 'published');
        final published = io.read(context.file, parentDocumentLimit);
        if (sha256.convert(published).toString() !=
            sha256.convert(candidate).toString()) {
          throw MambaException('Published parent bytes did not verify.');
        }
        final now = _readSource(context)!;
        final evidence = _unitEvidence(
          context,
          now,
          request.changes.map((change) => change.unit).toSet(),
        );
        final record = <String, Object?>{
          'schemaVersion': 1,
          'parentId': parentId,
          'harness': context.harness.name,
          'scope': context.scope.name,
          'layer': context.layer.name,
          'profile': context.profile,
          'file': context.file,
          'fingerprint': now.digest,
          'units': evidence,
          'backupIds': [if (backup != null) backup.backupId],
          'lifecycle': 'live',
        };
        _upsertRecord(context.stateRoot, record);
        _advance(transaction, 'committedCleanupPending');
        final quarantine = _quarantinePath(context, transactionId);
        if (io.type(quarantine, followLinks: false) !=
            FileSystemEntityType.notFound) {
          io.delete(quarantine);
        }
        _advance(transaction, 'committed');
        return ParentResult(
          command: 'agent config apply',
          outcome: 'applied',
          data: <String, Object?>{
            'planId': request.planId,
            'parentId': parentId,
            'transactionId': transactionId,
            'backupId': backup?.backupId,
            'file': context.file,
            'sourceFingerprint': now.digest,
            'clientsStopped': true,
            'runtime': 'notVerified',
            'backupRetained': backup != null,
          },
        );
      } catch (error) {
        final quarantine = _quarantinePath(context, transactionId);
        if (!liveChanged) {
          if (error is MambaException) rethrow;
          throw MambaException(
            'Parent apply failed before live changes; evidence $transaction. $error',
          );
        }
        try {
          if (io.type(context.file, followLinks: false) !=
              FileSystemEntityType.notFound) {
            final failed = '$quarantine.failed-new';
            io.rename(context.file, failed);
          }
          if (io.type(quarantine, followLinks: false) !=
              FileSystemEntityType.notFound) {
            io.rename(quarantine, context.file);
          }
          _advance(transaction, 'failedRestored');
          throw MambaException(
            'Parent apply failed and the prior document was restored: $error',
            exitCode: 5,
          );
        } on MambaException {
          rethrow;
        } on Object {
          _advance(transaction, 'recoveryRequired');
          throw MambaException(
            'Parent apply requires recovery; evidence $transaction. $error',
            exitCode: 6,
          );
        }
      }
    });
  }

  List<Map<String, Object?>> records(LifecycleOptions options) =>
      _readRecords(_optionsContext(options).stateRoot);

  Future<ParentResult> backupList(LifecycleOptions options) async {
    final context = _optionsContext(options);
    final backups = _readBackups(context.stateRoot)
        .where((backup) => backup['retention'] == 'retained')
        .map((backup) {
          final units = (backup['units']! as List<Object?>)
              .cast<Map<String, Object?>>()
              .map(
                (unit) => <String, Object?>{
                  'unit': unit['unit'],
                  'present': unit['present'],
                  ..._redactedUnit(unit['unit']! as String, unit['value']),
                  'digest': unit['digest'],
                },
              )
              .toList();
          return <String, Object?>{
            ...backup,
            'units': units,
            'restorePlanId': _restorePlanId(
              backup['backupId']! as String,
              _readPath(backup['file']! as String),
              (backup['units']! as List<Object?>).cast<Map<String, Object?>>(),
            ),
          };
        })
        .toList();
    return ParentResult(
      command: 'agent backup list',
      outcome: 'inventoried',
      data: <String, Object?>{
        'scope': options.scope.name,
        'parentBackups': backups,
      },
    );
  }

  bool hasBackup(LifecycleOptions options, String backupId) {
    final state = _optionsContext(options).stateRoot;
    return _readBackups(state).any((backup) => backup['backupId'] == backupId);
  }

  String restorePlanId(LifecycleOptions options, String backupId) {
    final context = _optionsContext(options);
    final backup = _backupRecord(context.stateRoot, backupId);
    final source = _readPath(backup['file']! as String);
    final units = (backup['units']! as List<Object?>)
        .cast<Map<String, Object?>>();
    return _restorePlanId(backupId, source, units);
  }

  Future<ParentResult> restore({
    required LifecycleOptions options,
    required String backupId,
    required String planId,
    required bool clientsStopped,
  }) async {
    if (options.dryRun) {
      final context = _optionsContext(options);
      final backup = _backupRecord(context.stateRoot, backupId);
      final source = _readPath(backup['file']! as String);
      final units = (backup['units']! as List<Object?>)
          .cast<Map<String, Object?>>();
      return ParentResult(
        command: 'agent backup restore',
        outcome: 'planned',
        data: <String, Object?>{
          'backupId': backupId,
          'file': backup['file'],
          'restorePlanId': _restorePlanId(backupId, source, units),
          'units': [
            for (final unit in units)
              <String, Object?>{
                'unit': unit['unit'],
                'present': unit['present'],
              },
          ],
          'clientsStoppedAcknowledgementRequired': true,
          'writes': false,
        },
      );
    }
    if (!options.approved) {
      throw MambaException(
        'Parent backup restore requires approval.',
        exitCode: 4,
      );
    }
    if (!clientsStopped) {
      throw MambaException(
        'Parent backup restore requires --clients-stopped acknowledgement.',
        exitCode: 4,
      );
    }
    final context = _optionsContext(options);
    final backup = _backupRecord(context.stateRoot, backupId);
    final file = backup['file']! as String;
    final scope = LifecycleScope.values.byName(backup['scope']! as String);
    if (scope != context.scope) {
      throw MambaException('The backup belongs to another scope.', exitCode: 4);
    }
    final currentSource = _readPath(file);
    final units = (backup['units']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final currentId = _restorePlanId(backupId, currentSource, units);
    if (currentId != planId) {
      throw MambaException(
        'The restore plan ID does not match the current document and evidence.',
        exitCode: 4,
      );
    }
    final changes = <ParentChange>[];
    for (final unit in units) {
      changes.add(
        unit['present'] == true
            ? ParentChange(
                unit: unit['unit']! as String,
                action: ParentAction.set,
                value: unit['value'],
              )
            : ParentChange(
                unit: unit['unit']! as String,
                action: ParentAction.remove,
                value: null,
              ),
      );
    }
    final record = _recordForBackup(context.stateRoot, backupId);
    final contextRequest = ParentRequest(
      operation: ParentOperation.apply,
      harness: ParentHarness.values.byName(record['harness']! as String),
      scope: scope,
      layer: ParentLayer.values.byName(record['layer']! as String),
      profile: record['profile'] as String?,
      file: file,
      changes: changes,
      adopt: true,
    );
    final resolved = _ParentContext.resolve(contextRequest, options);
    final candidate = _patch(
      resolved,
      currentSource,
      changes,
      <String, Object?>{
        for (final change in changes)
          change.unit: change.action == ParentAction.remove
              ? null
              : change.value,
      },
    );
    _validateCandidate(resolved, candidate, <String, Object?>{
      for (final change in changes) change.unit: change.value,
    });
    final actionPlan = _restorePlanId(backupId, currentSource, units);
    if (actionPlan != planId) {
      throw MambaException(
        'Restore plan changed before publication.',
        exitCode: 4,
      );
    }
    return _serialized(context.stateRoot, () async {
      if (_readPath(file)?.digest != currentSource?.digest) {
        throw MambaException(
          'The parent document changed before restore.',
          exitCode: 4,
        );
      }
      final outgoing = currentSource == null
          ? null
          : _createBackup(
              resolved,
              currentSource,
              contextRequest,
              currentUnits: _unitEvidence(
                resolved,
                currentSource,
                changes.map((change) => change.unit).toSet(),
              ),
            );
      final transactionId = _newId('ptr');
      final staged = _stagingPath(resolved, transactionId);
      final transaction = p.join(
        context.stateRoot,
        'parent-transactions',
        '$transactionId.json',
      );
      _privateDirectory(p.dirname(staged));
      _privateDirectory(p.dirname(transaction));
      io.write(staged, candidate);
      _writeJson(transaction, <String, Object?>{
        'schemaVersion': 1,
        'transactionId': transactionId,
        'operation': 'config-restore',
        'file': file,
        'backupId': backupId,
        'sourceFingerprint': currentSource?.digest,
        'phase': 'prepared',
      });
      final quarantine = _quarantinePath(resolved, transactionId);
      if (currentSource != null) {
        _privateDirectory(p.dirname(quarantine));
        io.rename(file, quarantine);
      }
      io.createDirectory(p.dirname(file));
      io.rename(staged, file);
      _advance(transaction, 'published');
      final now = _readPath(file)!;
      final record = _recordForBackup(context.stateRoot, backupId);
      record['fingerprint'] = now.digest;
      record['units'] = _unitEvidence(
        resolved,
        now,
        changes.map((change) => change.unit).toSet(),
      );
      record['backupIds'] = <String>{
        ...(record['backupIds']! as List<Object?>).cast<String>(),
        if (outgoing != null) outgoing.backupId,
      }.toList();
      _upsertRecord(context.stateRoot, record);
      _advance(transaction, 'committedCleanupPending');
      if (io.type(quarantine, followLinks: false) !=
          FileSystemEntityType.notFound) {
        io.delete(quarantine);
      }
      _advance(transaction, 'committed');
      return ParentResult(
        command: 'agent backup restore',
        outcome: 'restored',
        data: <String, Object?>{
          'backupId': backupId,
          'outgoingBackupId': outgoing?.backupId,
          'parentId': record['parentId'],
          'file': file,
          'clientsStopped': true,
        },
      );
    });
  }

  Future<ParentResult> cleanup({
    required LifecycleOptions options,
    required String backupId,
  }) async {
    if (options.dryRun) {
      final context = _optionsContext(options);
      final backup = _backupRecord(context.stateRoot, backupId);
      return ParentResult(
        command: 'agent backup cleanup',
        outcome: 'planned',
        data: <String, Object?>{
          'backupId': backupId,
          'integrity': _backupIntegrity(backup),
          'secureErasure': false,
          'writes': false,
        },
      );
    }
    if (!options.approved) {
      throw MambaException(
        'Parent backup cleanup requires approval.',
        exitCode: 4,
      );
    }
    final context = _optionsContext(options);
    final backup = _backupRecord(context.stateRoot, backupId);
    if (backup['retention'] != 'retained') {
      throw MambaException('The parent backup is not retained.', exitCode: 4);
    }
    if (_backupIntegrity(backup) != 'unchanged') {
      throw MambaException('The parent backup record changed.', exitCode: 4);
    }
    return _serialized(context.stateRoot, () async {
      final current = _backupRecord(context.stateRoot, backupId);
      if (current['retention'] != 'retained' ||
          _backupIntegrity(current) != 'unchanged') {
        throw MambaException(
          'The parent backup changed before cleanup.',
          exitCode: 4,
        );
      }
      current['retention'] = 'cleaned';
      _writeJson(
        p.join(context.stateRoot, 'parent-backups', backupId, 'backup.json'),
        current,
      );
      final record = _recordForBackup(context.stateRoot, backupId);
      record['backupIds'] = (record['backupIds']! as List<Object?>)
          .cast<String>()
          .where((id) => id != backupId)
          .toList();
      _upsertRecord(context.stateRoot, record);
      return ParentResult(
        command: 'agent backup cleanup',
        outcome: 'cleaned',
        data: <String, Object?>{
          'backupId': backupId,
          'retention': 'cleaned',
          'secureErasure': false,
        },
      );
    });
  }

  // --- Reading, planning, patching ---------------------------------------

  ParentSource? _readSource(_ParentContext context) => _readPath(context.file);

  ParentSource? _readPath(String file) {
    final type = io.type(file, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The parent source is not a regular file.',
        exitCode: 4,
      );
    }
    final bytes = io.read(file, parentDocumentLimit);
    if (bytes.length > parentDocumentLimit) {
      throw MambaException('The parent document exceeds 8 MiB.', exitCode: 3);
    }
    final text = utf8.decode(bytes, allowMalformed: false);
    _structureLimit(text);
    final digest = sha256.convert(bytes).toString();
    return ParentSource(bytes: bytes, text: text, digest: digest);
  }

  void _structureLimit(String text) {
    var depth = 0;
    var nodes = 0;
    var quoted = false;
    var escaped = false;
    for (final unit in text.codeUnits) {
      if (quoted) {
        if (escaped) {
          escaped = false;
        } else if (unit == 0x5C) {
          escaped = true;
        } else if (unit == 0x22) {
          quoted = false;
        }
        continue;
      }
      if (unit == 0x22) quoted = true;
      if (unit == 0x7B || unit == 0x5B) {
        depth++;
        if (depth > parentDepthLimit) {
          throw MambaException(
            'Parent document parse depth exceeds 64.',
            exitCode: 3,
          );
        }
      } else if (unit == 0x7D || unit == 0x5D) {
        depth--;
      }
      if (unit == 0x2C || unit == 0x3A) {
        nodes++;
        if (nodes > parentNodeLimit) {
          throw MambaException(
            'Parent document node budget exhausted.',
            exitCode: 3,
          );
        }
      }
    }
  }

  Object? _selectedUnit(
    _ParentContext context,
    ParentSource? source,
    String unit,
  ) {
    if (source == null) return null;
    return _unitValueFromText(context, source.bytes, unit);
  }

  Object? _unitValueFromText(
    _ParentContext context,
    List<int> bytes,
    String unit,
  ) {
    if (context.harness == ParentHarness.claude) {
      final document = _JsonDocument.parse(utf8.decode(bytes));
      return document.valueAt(unit.split('.'));
    }
    final map = TomlDocument.parse(utf8.decode(bytes)).toMap();
    return _tomlValueAt(map, unit.split('.'));
  }

  Object? _applyIntent(
    Object? before,
    ParentChange change,
    _ParentContext context,
  ) {
    final isArray = _isMembershipUnit(context.harness, change.unit);
    switch (change.action) {
      case ParentAction.set:
        if (isArray) {
          throw MambaException(
            'Membership unit ${change.unit} requires add or remove.',
            exitCode: 4,
          );
        }
        _validateUnitValue(context.harness, change.unit, change.value);
        return change.value;
      case ParentAction.add:
      case ParentAction.remove:
        if (!isArray) {
          throw MambaException(
            'Unit ${change.unit} does not support membership actions.',
            exitCode: 4,
          );
        }
        if (change.value == null || change.value is! String) {
          throw MambaException(
            'Membership changes require a string value.',
            exitCode: 4,
          );
        }
        final current = before is List
            ? before.cast<Object?>().toList()
            : <Object?>[];
        if (change.action == ParentAction.add) {
          if (!current.contains(change.value)) current.add(change.value);
        } else {
          current.remove(change.value);
        }
        return current;
    }
  }

  List<int> _patch(
    _ParentContext context,
    ParentSource? source,
    List<ParentChange> changes,
    Map<String, Object?> proposed,
  ) {
    var text =
        source?.text ?? (context.harness == ParentHarness.claude ? '{}\n' : '');
    if (context.harness == ParentHarness.claude) {
      var document = _JsonDocument.parse(text);
      for (final change in changes) {
        document = document.setUnit(
          change.unit.split('.'),
          proposed[change.unit],
          remove: change.action == ParentAction.remove,
        );
      }
      text = document.text;
    } else {
      text = _TomlEditor(text).apply(changes, proposed);
    }
    final bytes = utf8.encode(text);
    if (bytes.length > parentDocumentLimit) {
      throw MambaException(
        'The proposed parent document exceeds 8 MiB.',
        exitCode: 3,
      );
    }
    return bytes;
  }

  void _validateCandidate(
    _ParentContext context,
    List<int> bytes,
    Map<String, Object?> proposed,
  ) {
    final text = utf8.decode(bytes, allowMalformed: false);
    _structureLimit(text);
    if (context.harness == ParentHarness.claude) {
      final document = _JsonDocument.parse(text);
      for (final entry in proposed.entries) {
        final actual = document.valueAt(entry.key.split('.'));
        if (jsonEncode(actual) != jsonEncode(entry.value)) {
          throw MambaException(
            'The proposed JSON candidate did not preserve ${entry.key}.',
            exitCode: 2,
          );
        }
      }
    } else {
      final map = TomlDocument.parse(text).toMap();
      for (final entry in proposed.entries) {
        final actual = _tomlValueAt(map, entry.key.split('.'));
        if (jsonEncode(actual) != jsonEncode(entry.value)) {
          throw MambaException(
            'The proposed TOML candidate did not preserve ${entry.key}.',
            exitCode: 2,
          );
        }
      }
    }
  }

  void _validateChange(ParentHarness harness, ParentChange change) {
    final unit = change.unit;
    if (unit.isEmpty ||
        unit.split('.').any((part) => part.isEmpty || part == '*')) {
      throw MambaException('A parent unit must be a concrete dotted key.');
    }
    _validateUnitName(harness, unit);
    if (!_isMembershipUnit(harness, unit) &&
        change.action != ParentAction.set &&
        change.action != ParentAction.remove) {
      throw MambaException(
        'Scalar/map unit $unit does not support ${change.action.name}.',
      );
    }
    if (change.action != ParentAction.remove) {
      _validateUnitValue(harness, unit, change.value);
    }
    if (_containsCredentialLiteral(unit, change.value)) {
      throw MambaException(
        'New credential literals are unsupported; use an evidenced reference.',
        exitCode: 4,
      );
    }
  }

  void _validateUnitName(ParentHarness harness, String unit) {
    final parts = unit.split('.');
    const claudeScalars = <String>{
      'model',
      'effortLevel',
      'permissions.defaultMode',
      'sandbox.enabled',
      'sandbox.failIfUnavailable',
      'sandbox.autoAllowBashIfSandboxed',
      'sandbox.allowUnsandboxedCommands',
      'sandbox.network.allowUnixSockets',
      'sandbox.network.allowLocalBinding',
    };
    const claudeArrays = <String>{
      'permissions.allow',
      'permissions.deny',
      'permissions.ask',
      'permissions.additionalDirectories',
      'sandbox.excludedCommands',
      'sandbox.filesystem.allowWrite',
      'sandbox.filesystem.denyWrite',
      'sandbox.filesystem.allowRead',
      'sandbox.filesystem.denyRead',
      'sandbox.network.allowedDomains',
      'sandbox.network.deniedDomains',
    };
    const codexScalars = <String>{
      'approval_policy',
      'sandbox_mode',
      'model',
      'model_provider',
      'default_permissions',
      'model_reasoning_effort',
      'model_verbosity',
      'approvals_reviewer',
    };
    const codexArrays = <String>{};
    final scalars = harness == ParentHarness.claude
        ? claudeScalars
        : codexScalars;
    final arrays = harness == ParentHarness.claude ? claudeArrays : codexArrays;
    if (scalars.contains(unit) || arrays.contains(unit)) return;
    if (harness == ParentHarness.claude) {
      if (parts.length == 2 && parts[0] == 'env') return;
      if (unit.startsWith('mcpServers.')) {
        _validateClaudeMcpUnit(parts);
        return;
      }
    } else {
      if (unit.startsWith('mcp_servers.')) {
        _validateCodexMcpUnit(parts);
        return;
      }
      if (unit.startsWith('agents.') &&
          parts.length == 3 &&
          (parts[2] == 'description' || parts[2] == 'config_file')) {
        return;
      }
      if (unit.startsWith('model_providers.') && parts.length == 2) return;
      if (unit.startsWith('permissions.') && parts.length == 2) return;
    }
    throw MambaException(
      'Unsupported ${harness.name} parent unit: $unit',
      exitCode: 4,
    );
  }

  void _validateClaudeMcpUnit(List<String> parts) {
    if (parts.length == 2) return; // whole selected server entry
    if (parts.length == 3 &&
        const {'command', 'url', 'type', 'args'}.contains(parts[2])) {
      return;
    }
    throw MambaException(
      'Unsupported Claude MCP unit: ${parts.join('.')}',
      exitCode: 4,
    );
  }

  void _validateCodexMcpUnit(List<String> parts) {
    if (parts.length == 3 &&
        const {
          'command',
          'url',
          'args',
          'env',
          'env_vars',
          'bearer_token_env_var',
        }.contains(parts[2])) {
      return;
    }
    throw MambaException(
      'Unsupported Codex MCP unit: ${parts.join('.')}',
      exitCode: 4,
    );
  }

  bool _isMembershipUnit(ParentHarness harness, String unit) {
    if (harness == ParentHarness.claude) {
      return const {
        'permissions.allow',
        'permissions.deny',
        'permissions.ask',
        'permissions.additionalDirectories',
        'sandbox.excludedCommands',
        'sandbox.filesystem.allowWrite',
        'sandbox.filesystem.denyWrite',
        'sandbox.filesystem.allowRead',
        'sandbox.filesystem.denyRead',
        'sandbox.network.allowedDomains',
        'sandbox.network.deniedDomains',
      }.contains(unit);
    }
    return unit == 'mcp_servers.*.args';
  }

  void _validateUnitValue(ParentHarness harness, String unit, Object? value) {
    final boolUnit = const {
      'sandbox.enabled',
      'sandbox.failIfUnavailable',
      'sandbox.autoAllowBashIfSandboxed',
      'sandbox.allowUnsandboxedCommands',
      'sandbox.network.allowUnixSockets',
      'sandbox.network.allowLocalBinding',
    }.contains(unit);
    if (boolUnit && value is! bool) {
      throw MambaException('$unit requires a boolean value.', exitCode: 2);
    }
    if (const {
          'approval_policy',
          'sandbox_mode',
          'default_permissions',
        }.contains(unit) &&
        value is! String) {
      throw MambaException('$unit requires a string value.', exitCode: 2);
    }
    if (unit == 'sandbox_mode') {
      const supported = {'read-only', 'workspace-write', 'danger-full-access'};
      if (!supported.contains(value)) {
        throw MambaException('Unsupported Codex sandbox mode.', exitCode: 2);
      }
    }
    if (unit == 'approval_policy' &&
        value is String &&
        !const {'on-request', 'never'}.contains(value)) {
      throw MambaException('Unsupported Codex approval policy.', exitCode: 2);
    }
    if (unit.endsWith('.args') && value is! List) {
      throw MambaException('$unit requires an array value.', exitCode: 2);
    }
    if (unit.startsWith('mcpServers.') &&
        unit.split('.').length == 2 &&
        value is! Map) {
      throw MambaException(
        'A whole MCP server unit requires an object.',
        exitCode: 2,
      );
    }
  }

  bool _containsCredentialLiteral(String unit, Object? value) {
    if (value == null) return false;
    final lower = unit.toLowerCase();
    final sensitiveUnit =
        lower.contains('token') ||
        lower.contains('secret') ||
        lower.contains('password') ||
        lower.contains('apikey') ||
        lower.contains('api_key') ||
        lower.contains('authorization') ||
        unit.startsWith('env.') &&
            RegExp(
              r'KEY|TOKEN|SECRET|PASSWORD',
              caseSensitive: false,
            ).hasMatch(unit.substring(4));
    String? sensitiveKey;
    Object? inspect = value;
    if (value is Map) {
      for (final entry in value.entries) {
        if (RegExp(
          r'token|secret|password|api[_-]?key|authorization|header',
          caseSensitive: false,
        ).hasMatch(entry.key.toString())) {
          sensitiveKey = entry.key.toString();
          inspect = entry.value;
          break;
        }
      }
    }
    if (!sensitiveUnit && sensitiveKey == null) return false;
    if (inspect is String) {
      return !(inspect.startsWith(r'${') || inspect.startsWith('env:'));
    }
    return inspect != null;
  }

  Map<String, Object?> _redactedUnit(String unit, Object? value) {
    if (_containsCredentialLiteral(unit, value)) {
      return <String, Object?>{'redacted': true};
    }
    return <String, Object?>{'value': value};
  }

  List<Map<String, Object?>> _unitEvidence(
    _ParentContext context,
    ParentSource source,
    Set<String> units,
  ) => [
    for (final unit in units)
      <String, Object?>{
        'unit': unit,
        'present': _selectedUnit(context, source, unit) != null,
        'value':
            _containsCredentialLiteral(
              unit,
              _selectedUnit(context, source, unit),
            )
            ? null
            : _selectedUnit(context, source, unit),
        'digest': _selectedUnit(context, source, unit) == null
            ? null
            : sha256
                  .convert(
                    utf8.encode(
                      jsonEncode(_selectedUnit(context, source, unit)),
                    ),
                  )
                  .toString(),
      },
  ];

  String _planId(
    _ParentContext context,
    ParentSource? source,
    ParentRequest request,
    List<Map<String, Object?>> changes,
  ) => sha256
      .convert(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'schemaVersion': 1,
            'operation': 'plan',
            'request': <String, Object?>{
              'harness': request.harness.name,
              'scope': request.scope.name,
              'layer': request.layer.name,
              'profile': request.profile,
              'file': context.file,
              'adopt': request.adopt,
              'affected': request.affected,
              'changes': [
                for (final change in request.changes) change.canonical(),
              ],
            },
            'context': <String, Object?>{
              'cwd': context.cwd,
              'projectRoot': context.projectRoot,
              'home': context.home,
              'claudeRoot': context.claudeRoot,
              'codexRoot': context.codexRoot,
            },
            'source': source?.digest,
            'changes': changes,
            'impacts': _impacts(context, request),
          }),
        ),
      )
      .toString();

  String _restorePlanId(
    String backupId,
    ParentSource? source,
    List<Map<String, Object?>> units,
  ) => sha256
      .convert(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'operation': 'restore',
            'backupId': backupId,
            'source': source?.digest,
            'units': units,
          }),
        ),
      )
      .toString();

  List<String> _impacts(_ParentContext context, ParentRequest request) {
    final result = <String>[];
    for (final change in request.changes) {
      if (change.unit == 'approval_policy' ||
          change.unit == 'sandbox_mode' ||
          change.unit == 'default_permissions') {
        result.add(
          'Changing ${change.unit} may restrict or broaden existing child Agents; '
          'runtime enforcement remains unverified.',
        );
      }
      if (change.unit == 'model_provider' &&
          context.scope == LifecycleScope.project) {
        result.add(
          'Codex ignores project model_provider settings; plan a user source instead.',
        );
      }
      if (change.unit.startsWith('agents.')) {
        result.add(
          'Removing a registration does not delete its referenced definition or other roles.',
        );
      }
    }
    return result;
  }

  void _checkOwnership(
    _ParentContext context,
    List<Map<String, Object?>> records,
    ParentRequest request,
  ) {
    for (final record in records) {
      if (record['file'] != context.file) continue;
      final sameRecord = record['parentId'] == _matchingParentId(context);
      final owned = (record['units']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .map((unit) => unit['unit']! as String)
          .toSet();
      for (final change in request.changes) {
        for (final other in owned) {
          final exact = change.unit == other;
          final overlap =
              exact ||
              change.unit.startsWith('$other.') ||
              other.startsWith('${change.unit}.');
          if (!overlap) continue;
          if (!sameRecord) {
            throw MambaException(
              'Unit ${change.unit} conflicts with another selected-unit owner.',
              exitCode: 4,
            );
          }
          if (request.adopt && !exact) {
            throw MambaException(
              'Adoption must select an exact existing unit, not an overlapping parent/child.',
              exitCode: 4,
            );
          }
          if (!request.adopt && !exact) {
            throw MambaException(
              'Units ${change.unit} and $other overlap within one document.',
              exitCode: 4,
            );
          }
        }
      }
    }
  }

  String _matchingParentId(_ParentContext context) => sha256
      .convert(utf8.encode('${context.scope.name}\n${context.file}'))
      .toString();

  // --- Ledger and backups ------------------------------------------------

  List<Map<String, Object?>> _readRecords(String state) {
    final file = p.join(state, 'parent-units.json');
    if (io.type(file, followLinks: false) == FileSystemEntityType.notFound) {
      return <Map<String, Object?>>[];
    }
    final document =
        _StrictJsonValue.parse(utf8.decode(io.read(file, parentDocumentLimit)))
                .value
            as Map<String, Object?>;
    if (document['schemaVersion'] != 1) {
      throw MambaException('Unsupported parent-unit ledger.', exitCode: 4);
    }
    return (document['records']! as List<Object?>).cast<Map<String, Object?>>();
  }

  void _upsertRecord(String state, Map<String, Object?> record) {
    final records = _readRecords(state);
    final index = records.indexWhere(
      (current) => current['parentId'] == record['parentId'],
    );
    if (index < 0) {
      records.add(record);
    } else {
      final existing = records[index];
      final merged = <String, Map<String, Object?>>{
        for (final unit
            in (existing['units']! as List<Object?>)
                .cast<Map<String, Object?>>())
          unit['unit']! as String: unit,
        for (final unit
            in (record['units']! as List<Object?>).cast<Map<String, Object?>>())
          unit['unit']! as String: unit,
      };
      record['units'] = merged.values.toList();
      record['backupIds'] = <String>{
        ...(existing['backupIds']! as List<Object?>).cast<String>(),
        ...(record['backupIds']! as List<Object?>).cast<String>(),
      }.toList();
      records[index] = record;
    }
    _writeJson(p.join(state, 'parent-units.json'), <String, Object?>{
      'schemaVersion': 1,
      'records': records,
    });
  }

  _ParentBackup _createBackup(
    _ParentContext context,
    ParentSource source,
    ParentRequest request, {
    required List<Map<String, Object?>> currentUnits,
  }) {
    final id = _newId('pbk');
    final directory = p.join(context.stateRoot, 'parent-backups', id);
    _privateDirectory(directory);
    final units = [
      for (final unit in currentUnits)
        <String, Object?>{
          'unit': unit['unit'],
          'present':
              _selectedUnit(context, source, unit['unit']! as String) != null,
          'value': _selectedUnit(context, source, unit['unit']! as String),
          'digest':
              _selectedUnit(context, source, unit['unit']! as String) == null
              ? null
              : sha256
                    .convert(
                      utf8.encode(
                        jsonEncode(
                          _selectedUnit(
                            context,
                            source,
                            unit['unit']! as String,
                          ),
                        ),
                      ),
                    )
                    .toString(),
        },
    ];
    final record = <String, Object?>{
      'schemaVersion': 1,
      'backupId': id,
      'parentId': _matchingParentId(context),
      'scope': context.scope.name,
      'harness': context.harness.name,
      'layer': context.layer.name,
      'profile': context.profile,
      'file': context.file,
      'sourceFingerprint': source.digest,
      'units': units,
      'retention': 'retained',
    };
    record['artifactDigest'] = _backupDigest(record);
    _writeJson(p.join(directory, 'backup.json'), record);
    return _ParentBackup(id, record);
  }

  String _backupDigest(Map<String, Object?> record) => sha256
      .convert(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'backupId': record['backupId'],
            'parentId': record['parentId'],
            'scope': record['scope'],
            'harness': record['harness'],
            'layer': record['layer'],
            'profile': record['profile'],
            'file': record['file'],
            'sourceFingerprint': record['sourceFingerprint'],
            'units': record['units'],
          }),
        ),
      )
      .toString();

  String _backupIntegrity(Map<String, Object?> record) =>
      _backupDigest(record) == record['artifactDigest']
      ? 'unchanged'
      : 'changed';

  List<Map<String, Object?>> _readBackups(String state) {
    final root = p.join(state, 'parent-backups');
    if (io.type(root, followLinks: false) == FileSystemEntityType.notFound) {
      return <Map<String, Object?>>[];
    }
    final result = <Map<String, Object?>>[];
    for (final entity in io.list(root)) {
      if (io.type(entity.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      final metadata = p.join(entity.path, 'backup.json');
      if (io.type(metadata, followLinks: false) != FileSystemEntityType.file) {
        throw MambaException('Parent backup metadata is missing.', exitCode: 4);
      }
      final record =
          _StrictJsonValue.parse(
                utf8.decode(io.read(metadata, parentDocumentLimit)),
              ).value
              as Map<String, Object?>;
      result.add(record);
    }
    return result;
  }

  Map<String, Object?> _backupRecord(String state, String id) {
    final record = _readBackups(state)
        .where((backup) => backup['backupId'] == id);
    if (record.length != 1) {
      throw MambaException(
        'No parent backup $id exists in this scope.',
        exitCode: 4,
      );
    }
    return record.single;
  }

  Map<String, Object?> _recordForBackup(String state, String id) {
    final backup = _backupRecord(state, id);
    final records = _readRecords(state)
        .where((record) => record['parentId'] == backup['parentId']);
    if (records.length != 1) {
      throw MambaException('The backup parent record is missing.', exitCode: 4);
    }
    return records.single;
  }

  // --- Filesystem/private/coordination -----------------------------------

  String _stagingPath(_ParentContext context, String transactionId) => p.join(
    p.dirname(context.file),
    '.agent-resource-parent',
    'staging',
    transactionId,
    'candidate',
  );

  String _quarantinePath(_ParentContext context, String transactionId) =>
      p.join(
        p.dirname(context.file),
        '.agent-resource-parent',
        'quarantine',
        transactionId,
        'original',
      );

  void _privateDirectory(String path) {
    if (io.type(path, followLinks: false) == FileSystemEntityType.notFound) {
      io.createDirectory(path);
    }
    if (io.type(path, followLinks: false) != FileSystemEntityType.directory) {
      throw MambaException(
        'Private parent storage is not a directory.',
        exitCode: 4,
      );
    }
    if (Platform.isWindows) {
      final username = Platform.environment['USERNAME'];
      if (username == null || username.trim().isEmpty) {
        throw MambaException(
          'Cannot establish a private Windows owner for parent storage.',
          exitCode: 4,
        );
      }
      final ProcessResult result;
      try {
        result = Process.runSync('icacls', [
          path,
          '/inheritance:r',
          '/grant:r',
          '$username:(OI)(CI)F',
          'SYSTEM:(OI)(CI)F',
          'Administrators:(OI)(CI)F',
        ]);
      } on ProcessException catch (error) {
        throw MambaException(
          'Could not establish private parent storage: ${error.message}',
          exitCode: 4,
        );
      }
      if (result.exitCode != 0) {
        throw MambaException(
          'Could not establish private parent storage before writing sensitive bytes.',
          exitCode: 4,
        );
      }
    } else {
      final ProcessResult result;
      try {
        result = Process.runSync('chmod', ['700', path]);
      } on ProcessException catch (error) {
        throw MambaException(
          'Could not establish private parent storage: ${error.message}',
          exitCode: 4,
        );
      }
      if (result.exitCode != 0 || FileStat.statSync(path).mode & 0x3F != 0) {
        throw MambaException(
          'Could not establish private parent storage before writing sensitive bytes.',
          exitCode: 4,
        );
      }
    }
  }

  Future<T> _serialized<T>(String state, Future<T> Function() body) async {
    final key = p.normalize(state);
    final previous = _inProcess[key] ?? Future<void>.value();
    final done = Completer<void>.sync();
    _inProcess[key] = done.future;
    await previous;
    RandomAccessFile? lock;
    try {
      _privateDirectory(p.join(state, 'coordination'));
      lock = File(p.join(state, 'coordination', 'parent.lock'))
          .openSync(mode: FileMode.write);
      lock.lockSync(FileLock.exclusive);
      return await body();
    } catch (error) {
      if (error is FileSystemException) {
        throw MambaException(
          'Could not coordinate parent configuration: ${error.message}',
          exitCode: 4,
        );
      }
      rethrow;
    } finally {
      if (lock != null) {
        try {
          lock.unlockSync();
        } on FileSystemException {
          // Closing releases the lock.
        }
        lock.closeSync();
      }
      done.complete();
      if (identical(_inProcess[key], done.future)) _inProcess.remove(key);
    }
  }

  void _writeJson(String path, Object? value) {
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > parentDocumentLimit) {
      throw MambaException(
        'Parent management document exceeds 8 MiB.',
        exitCode: 3,
      );
    }
    _privateDirectory(p.dirname(path));
    final temporary = '$path.${_newId('tmp')}.tmp';
    io.write(temporary, bytes);
    io.rename(temporary, path);
  }

  void _advance(String path, String phase) {
    final current =
        _StrictJsonValue.parse(utf8.decode(io.read(path, parentDocumentLimit)))
                .value
            as Map<String, Object?>;
    current['phase'] = phase;
    _writeJson(path, current);
  }

  static String _newId(String prefix) {
    final bytes = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    return '${prefix}_${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
  }
}

Map<String, Object?> parseStrictJsonObject(String text) {
  final value = _StrictJsonValue.parse(text).value;
  if (value is! Map<String, Object?>) {
    throw MambaException('Expected a JSON object.');
  }
  return value;
}

ParentRequest parseParentRequest(String requestFile, String workingDirectory) {
  final path = p.normalize(
    p.isAbsolute(requestFile)
        ? requestFile
        : p.join(workingDirectory, requestFile),
  );
  final file = File(path);
  if (!file.existsSync()) {
    throw MambaException('Parent request does not exist: $path');
  }
  final bytes = file.readAsBytesSync();
  if (bytes.length > parentDocumentLimit) {
    throw MambaException('Parent request exceeds 8 MiB.', exitCode: 3);
  }
  final Map<String, Object?> map;
  try {
    final parsed = _StrictJsonValue.parse(
      utf8.decode(bytes, allowMalformed: false),
    ).value;
    if (parsed is! Map<String, Object?>) {
      throw const FormatException('A parent request must be a JSON object.');
    }
    map = parsed;
  } on FormatException catch (error) {
    throw MambaException('Invalid parent request: ${error.message}');
  }
  const allowed = <String>{
    'schemaVersion',
    'operation',
    'source',
    'changes',
    'planId',
    'clientsStopped',
    'affected',
  };
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw MambaException('Unknown parent request field: $key');
    }
  }
  if (map['schemaVersion'] != 1) {
    throw MambaException('Parent request schemaVersion must be 1.');
  }
  final operationName = map['operation'];
  if (operationName is! String) {
    throw MambaException('Parent request operation must be a string.');
  }
  final operation = ParentOperation.values.where(
    (value) => value.name == operationName,
  );
  if (operation.length != 1) {
    throw MambaException(
      'Unsupported parent request operation: $operationName',
    );
  }
  final source = map['source'];
  if (source is! Map<String, Object?>) {
    throw MambaException('Parent request source must be an object.');
  }
  const sourceKeys = <String>{
    'harness',
    'scope',
    'layer',
    'file',
    'profile',
    'adopt',
  };
  for (final key in source.keys) {
    if (!sourceKeys.contains(key)) {
      throw MambaException('Unknown parent source field: $key');
    }
  }
  ParentHarness harnessFrom(String? value) {
    final matches = ParentHarness.values.where((item) => item.name == value);
    if (matches.length != 1) {
      throw MambaException('Parent source harness must be claude or codex.');
    }
    return matches.single;
  }

  LifecycleScope scopeFrom(Object? value) {
    final matches = LifecycleScope.values.where((item) => item.name == value);
    if (matches.length != 1 || matches.single == LifecycleScope.all) {
      throw MambaException('Parent source scope must be user or project.');
    }
    return matches.single;
  }

  ParentLayer layerFrom(Object? value) {
    final matches = ParentLayer.values.where((item) => item.name == value);
    if (matches.length != 1) {
      throw MambaException('Parent source layer is unsupported.');
    }
    return matches.single;
  }

  final requestFileValue = source['file'];
  if (requestFileValue is! String || requestFileValue.trim().isEmpty) {
    throw MambaException('Parent source file must be a nonblank string.');
  }
  final changes = <ParentChange>[];
  final rawChanges = map['changes'];
  if (rawChanges != null) {
    if (rawChanges is! List<Object?>) {
      throw MambaException('Parent request changes must be an array.');
    }
    for (final raw in rawChanges) {
      if (raw is! Map<String, Object?>) {
        throw MambaException('Each parent change must be an object.');
      }
      const changeKeys = <String>{'unit', 'action', 'value'};
      for (final key in raw.keys) {
        if (!changeKeys.contains(key)) {
          throw MambaException('Unknown parent change field: $key');
        }
      }
      final unit = raw['unit'];
      final action = raw['action'];
      if (unit is! String || action is! String) {
        throw MambaException('Parent change unit/action must be strings.');
      }
      final actions = ParentAction.values.where((item) => item.name == action);
      if (actions.length != 1) {
        throw MambaException('Unsupported parent change action: $action');
      }
      changes.add(
        ParentChange(unit: unit, action: actions.single, value: raw['value']),
      );
    }
  }
  final planId = map['planId'];
  if (planId != null && planId is! String) {
    throw MambaException('Parent request planId must be a string.');
  }
  final clientsStopped = map['clientsStopped'];
  if (clientsStopped != null && clientsStopped is! bool) {
    throw MambaException('Parent clientsStopped must be a boolean.');
  }
  final affected = map['affected'];
  if (affected != null && affected is! List<Object?>) {
    throw MambaException('Parent affected decisions must be an array.');
  }
  final adopt = source['adopt'];
  if (adopt != null && adopt is! bool) {
    throw MambaException('Parent source adopt must be a boolean.');
  }
  final profile = source['profile'];
  if (profile != null && (profile is! String || profile.trim().isEmpty)) {
    throw MambaException('Parent source profile must be a nonblank string.');
  }
  return ParentRequest(
    operation: operation.single,
    harness: harnessFrom(source['harness'] as String?),
    scope: scopeFrom(source['scope']),
    layer: layerFrom(source['layer']),
    file: requestFileValue,
    profile: profile as String?,
    changes: changes,
    planId: planId as String?,
    clientsStopped: clientsStopped == true,
    adopt: adopt == true,
    affected: affected == null
        ? const <String>[]
        : (affected as List<Object?>).cast<String>().toList(),
  );
}

final class _ParentBackup {
  const _ParentBackup(this.backupId, this.record);
  final String backupId;
  final Map<String, Object?> record;
}

final class ParentSource {
  const ParentSource({
    required this.bytes,
    required this.text,
    required this.digest,
  });
  final List<int> bytes;
  final String text;
  final String digest;
}

final class _ParentContext {
  const _ParentContext({
    required this.harness,
    required this.scope,
    required this.layer,
    required this.file,
    required this.stateRoot,
    required this.cwd,
    required this.projectRoot,
    required this.home,
    required this.claudeRoot,
    required this.codexRoot,
    this.profile,
  });

  factory _ParentContext.resolve(
    ParentRequest request,
    LifecycleOptions options,
  ) {
    if (options.scope == LifecycleScope.all || options.scope != request.scope) {
      throw MambaException(
        'The request scope must match one explicit mutation scope.',
        exitCode: 4,
      );
    }
    final lifecycle = LifecycleContext.resolve(options);
    final file = lifecycle.resolvePath(request.file);
    final claudeRoot = lifecycle.claudeConfigRoot();
    final codexRoot = lifecycle.codexRoot();
    final projectRoot = lifecycle.projectRoot;
    final home = lifecycle.requireHome();
    final inferred = _inferLayer(
      request,
      file,
      claudeRoot,
      codexRoot,
      projectRoot,
      home,
    );
    if (inferred != request.layer) {
      throw MambaException(
        'The request layer does not match the selected native source.',
        exitCode: 4,
      );
    }
    _requireEligible(file, request, projectRoot, home, claudeRoot, codexRoot);
    return _ParentContext(
      harness: request.harness,
      scope: request.scope,
      layer: request.layer,
      profile: request.profile,
      file: file,
      stateRoot: lifecycle.stateRoot(),
      cwd: lifecycle.cwd,
      projectRoot: projectRoot,
      home: home,
      claudeRoot: claudeRoot,
      codexRoot: codexRoot,
    );
  }

  final ParentHarness harness;
  final LifecycleScope scope;
  final ParentLayer layer;
  final String? profile;
  final String file;
  final String stateRoot;
  final String cwd;
  final String projectRoot;
  final String home;
  final String claudeRoot;
  final String codexRoot;
}

_ParentContext _optionsContext(LifecycleOptions options) {
  final context = LifecycleContext.resolve(options);
  return _ParentContext(
    harness: ParentHarness.claude,
    scope: options.scope,
    layer: ParentLayer.user,
    file: p.join(context.claudeConfigRoot(), 'settings.json'),
    stateRoot: context.stateRoot(),
    cwd: context.cwd,
    projectRoot: context.projectRoot,
    home: context.requireHome(),
    claudeRoot: context.claudeConfigRoot(),
    codexRoot: context.codexRoot(),
  );
}

ParentLayer _inferLayer(
  ParentRequest request,
  String file,
  String claudeRoot,
  String codexRoot,
  String projectRoot,
  String home,
) {
  final normalized = p.normalize(file);
  if (request.harness == ParentHarness.claude) {
    if (p.equals(normalized, p.join(claudeRoot, 'settings.json'))) {
      return ParentLayer.user;
    }
    if (p.equals(normalized, p.join(projectRoot, '.claude', 'settings.json')) ||
        p.equals(normalized, p.join(projectRoot, '.mcp.json'))) {
      return ParentLayer.project;
    }
  } else {
    if (p.equals(normalized, p.join(codexRoot, 'config.toml'))) {
      return ParentLayer.user;
    }
    if (request.profile != null &&
        p.equals(
          normalized,
          p.join(codexRoot, '${request.profile}.config.toml'),
        )) {
      return ParentLayer.profile;
    }
    if (p.equals(normalized, p.join(projectRoot, '.codex', 'config.toml'))) {
      return ParentLayer.project;
    }
  }
  throw MambaException(
    'The selected file is not an eligible native parent source for this scope.',
    exitCode: 4,
  );
}

void _requireEligible(
  String file,
  ParentRequest request,
  String projectRoot,
  String home,
  String claudeRoot,
  String codexRoot,
) {
  final normalized = p.normalize(file);
  final reserved = <String>[
    p.join(projectRoot, '.agent-resource'),
    p.join(home, '.agent-resource'),
  ];
  if (reserved.any(
    (path) => p.equals(path, normalized) || p.isWithin(path, normalized),
  )) {
    throw MambaException(
      'Reserved management state cannot be acquired as parent configuration.',
      exitCode: 4,
    );
  }
  if (p.basename(normalized) == 'auth.json' ||
      p.basename(normalized) == 'requirements.toml' ||
      normalized.toLowerCase().contains('managed') ||
      normalized.toLowerCase().contains('program files') ||
      normalized.startsWith('/etc/')) {
    throw MambaException(
      'Managed, authentication, and system-enforced sources are inspect-only.',
      exitCode: 4,
    );
  }
  if (request.harness == ParentHarness.codex &&
      request.scope == LifecycleScope.project &&
      normalized == p.join(projectRoot, '.codex', 'config.toml')) {
    // Project provider keys are explicitly ineffective in Codex.
    for (final change in request.changes) {
      if (change.unit == 'model_provider' ||
          change.unit.startsWith('model_providers.')) {
        throw MambaException(
          'Codex ignores project provider settings; plan a user source instead.',
          exitCode: 4,
        );
      }
    }
  }
}

Object? _tomlValueAt(Map<String, Object?> map, List<String> parts) {
  Object? current = map;
  for (final part in parts) {
    if (current is! Map) return null;
    if (!current.containsKey(part)) return null;
    current = current[part];
  }
  return current;
}

final class _StrictJsonValue {
  const _StrictJsonValue(this.value);
  final Object? value;

  static _StrictJsonValue parse(String source) {
    final parser = _StrictJsonParser(source);
    return _StrictJsonValue(parser.parse());
  }
}

final class _StrictJsonParser {
  _StrictJsonParser(this.source);
  final String source;
  var index = 0;
  var nodes = 0;

  Object? parse([int depth = 0]) {
    if (depth > 64) {
      throw const FormatException('JSON depth exceeds 64.');
    }
    if (++nodes > 100000) {
      throw const FormatException('JSON node budget exhausted.');
    }
    _space();
    if (index >= source.length) {
      throw const FormatException('Unexpected JSON end.');
    }
    final char = source.codeUnitAt(index);
    final Object? value;
    if (char == 0x7B) {
      value = _map(depth);
    } else if (char == 0x5B) {
      value = _array(depth);
    } else if (char == 0x22) {
      value = _string();
    } else if (source.startsWith('true', index)) {
      index += 4;
      value = true;
    } else if (source.startsWith('false', index)) {
      index += 5;
      value = false;
    } else if (source.startsWith('null', index)) {
      index += 4;
      value = null;
    } else {
      value = _number();
    }
    if (depth == 0) {
      _space();
      if (index != source.length) throw const FormatException('Trailing JSON.');
    }
    return value;
  }

  Map<String, Object?> _map(int depth) {
    index++;
    final result = <String, Object?>{};
    _space();
    if (_take(0x7D)) return result;
    while (true) {
      _space();
      if (index >= source.length || source.codeUnitAt(index) != 0x22) {
        throw const FormatException('Expected JSON key.');
      }
      final key = _string();
      if (result.containsKey(key)) {
        throw FormatException('Duplicate JSON key: $key.');
      }
      _space();
      if (!_take(0x3A)) throw const FormatException('Expected colon.');
      result[key] = parse(depth + 1);
      _space();
      if (_take(0x7D)) return result;
      if (!_take(0x2C)) throw const FormatException('Expected object comma.');
    }
  }

  List<Object?> _array(int depth) {
    index++;
    final result = <Object?>[];
    _space();
    if (_take(0x5D)) return result;
    while (true) {
      result.add(parse(depth + 1));
      _space();
      if (_take(0x5D)) return result;
      if (!_take(0x2C)) throw const FormatException('Expected array comma.');
    }
  }

  String _string() {
    final start = index;
    index++;
    while (index < source.length) {
      final char = source.codeUnitAt(index++);
      if (char == 0x22) {
        return jsonDecode(source.substring(start, index)) as String;
      }
      if (char == 0x5C) {
        if (index >= source.length) break;
        index++;
      } else if (char < 0x20) {
        throw const FormatException('Control character in JSON string.');
      }
    }
    throw const FormatException('Unterminated JSON string.');
  }

  num _number() {
    final match = RegExp(
      r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
    ).matchAsPrefix(source, index);
    if (match == null) throw const FormatException('Invalid JSON number.');
    index = match.end;
    return num.parse(match.group(0)!);
  }

  void _space() {
    while (index < source.length &&
        const [0x20, 0x09, 0x0A, 0x0D].contains(source.codeUnitAt(index))) {
      index++;
    }
  }

  bool _take(int char) {
    if (index < source.length && source.codeUnitAt(index) == char) {
      index++;
      return true;
    }
    return false;
  }
}

/// Source-preserving strict-JSON editor. Only approved member/value spans are
/// replaced; all other bytes remain unchanged.
final class _JsonDocument {
  _JsonDocument._(this.ast);
  final _JsonAst ast;
  String get text => ast.text;

  static _JsonDocument parse(String text) {
    if (text.trim().isEmpty) return _JsonDocument._(_JsonAst.empty());
    final ast = _JsonAst.parse(text);
    if (ast.root.value is! Map<String, Object?>) {
      throw MambaException(
        'Claude settings must be a JSON object.',
        exitCode: 2,
      );
    }
    return _JsonDocument._(ast);
  }

  Object? valueAt(List<String> path) {
    var current = ast.root.value;
    for (final part in path) {
      if (current is! Map || !current.containsKey(part)) return null;
      current = current[part];
    }
    return current;
  }

  _JsonDocument setUnit(
    List<String> path,
    Object? value, {
    required bool remove,
  }) {
    var current = _JsonDocument._(ast);
    if (current.valueAt(path) == null && remove) return current;
    final parent = current._objectAt(path.sublist(0, path.length - 1));
    if (parent == null) {
      final insertion = path.first;
      final existing = current.valueAt([insertion]);
      final subtree = existing is Map<String, Object?>
          ? Map<String, Object?>.from(existing)
          : <String, Object?>{};
      var cursor = subtree;
      for (final part in path.skip(1).take(path.length - 2)) {
        final next = <String, Object?>{};
        cursor[part] = next;
        cursor = next;
      }
      if (!remove) cursor[path.last] = value;
      return current.setUnit([insertion], subtree, remove: false);
    }
    final member = parent.members[path.last];
    if (member == null) {
      if (remove) return current;
      return current._insert(path, parent, value);
    }
    if (remove) {
      return current._remove(path, parent, member);
    }
    final target = member.value;
    if (target.value is List && value is List) {
      return current._membership(path, target, value);
    }
    final updated =
        '${text.substring(0, target.start)}${jsonEncode(value)}${text.substring(target.end)}';
    return _JsonDocument._(_JsonAst.parse(updated));
  }

  _JsonNode? _objectAt(List<String> path) {
    var node = ast.root;
    for (final part in path) {
      if (node.value is! Map<String, Object?>) return null;
      final member = node.members[part];
      if (member == null) return null;
      node = member.value;
    }
    return node.value is Map<String, Object?> ? node : null;
  }

  _JsonDocument _insert(List<String> path, _JsonNode parent, Object? value) {
    final member = '"${path.last}": ${jsonEncode(value)}';
    final close = parent.end - 1;
    String insertion;
    if (parent.members.isEmpty) {
      insertion = parent.multiline ? '\n  $member\n' : member;
    } else {
      final first = parent.members.values.first;
      final prefix = text.substring(parent.start + 1, first.keyStart);
      final newlineIndex = prefix.lastIndexOf('\n');
      if (newlineIndex >= 0) {
        final indent = prefix.substring(newlineIndex + 1);
        insertion = ',\n$indent$member';
      } else {
        insertion = ', $member';
      }
    }
    final updated =
        '${text.substring(0, close)}$insertion${text.substring(close)}';
    return _JsonDocument._(_JsonAst.parse(updated));
  }

  _JsonDocument _remove(
    List<String> path,
    _JsonNode parent,
    _JsonMember member,
  ) {
    final members = parent.members.values.toList();
    final index = members.indexOf(member);
    final int start;
    final int end;
    if (index < members.length - 1) {
      start = member.memberStart;
      end = members[index + 1].memberStart;
    } else if (index > 0) {
      start = members[index - 1].value.end;
      end = member.value.end;
    } else {
      start = member.memberStart;
      end = member.value.end;
    }
    final updated = text.substring(0, start) + text.substring(end);
    return _JsonDocument._(_JsonAst.parse(updated));
  }

  _JsonDocument _membership(
    List<String> path,
    _JsonNode array,
    List<Object?> desired,
  ) {
    final wanted = desired.map((item) => jsonEncode(item)).toSet();
    final existing = <String, _JsonNode>{};
    for (final item in array.items) {
      existing[jsonEncode(item.value)] = item;
    }
    var updated = text;
    for (final entry in existing.entries) {
      if (wanted.contains(entry.key)) continue;
      final index = array.items.indexOf(entry.value);
      final items = array.items;
      final int start;
      final int end;
      if (index < items.length - 1) {
        start = entry.value.start;
        end = items[index + 1].start;
      } else if (index > 0) {
        start = items[index - 1].end;
        end = entry.value.end;
      } else {
        start = entry.value.start;
        end = entry.value.end;
      }
      updated = updated.substring(0, start) + updated.substring(end);
      return _JsonDocument._(_JsonAst.parse(updated))
          .setUnit(path, desired, remove: false);
    }
    for (final item in desired) {
      if (existing.containsKey(jsonEncode(item))) continue;
      final close = array.end - 1;
      final insertion = array.items.isEmpty
          ? jsonEncode(item)
          : ', ${jsonEncode(item)}';
      updated =
          updated.substring(0, close) + insertion + updated.substring(close);
      return _JsonDocument._(_JsonAst.parse(updated))
          .setUnit(path, desired, remove: false);
    }
    return _JsonDocument._(_JsonAst.parse(updated));
  }
}

final class _JsonAst {
  _JsonAst._(this.text, this.root);
  final String text;
  final _JsonNode root;

  factory _JsonAst.empty() => _JsonAst._(
    '{}\n',
    _JsonNode(0, 2, const <String, Object?>{}, const {}, const [], false),
  );

  static _JsonAst parse(String text) {
    final parser = _JsonAstParser(text);
    final node = parser.node(0);
    parser.space();
    if (parser.index != text.length) {
      throw const FormatException('Trailing JSON content.');
    }
    if (node.value is! Map<String, Object?>) {
      throw const FormatException('Expected a JSON object.');
    }
    return _JsonAst._(text, node);
  }
}

final class _JsonNode {
  _JsonNode(
    this.start,
    this.end,
    this.value,
    this.members,
    this.items,
    this.multiline,
  );
  final int start;
  final int end;
  final Object? value;
  final Map<String, _JsonMember> members;
  final List<_JsonNode> items;
  final bool multiline;
}

final class _JsonMember {
  _JsonMember(this.key, this.keyStart, this.value, this.memberStart);
  final String key;
  final int keyStart;
  final _JsonNode value;
  final int memberStart;
}

final class _JsonAstParser {
  _JsonAstParser(this.source);
  final String source;
  var index = 0;
  var nodes = 0;

  _JsonNode node(int depth) {
    if (depth > 64) {
      throw const FormatException('JSON depth exceeds 64.');
    }
    if (++nodes > 100000) {
      throw const FormatException('JSON node budget exhausted.');
    }
    space();
    if (index >= source.length) {
      throw const FormatException('Unexpected JSON end.');
    }
    final char = source.codeUnitAt(index);
    if (char == 0x7B) return object(depth);
    if (char == 0x5B) return array(depth);
    final start = index;
    final value = _value();
    return _JsonNode(start, index, value, const {}, const [], false);
  }

  _JsonNode object(int depth) {
    final start = index++;
    final members = <String, _JsonMember>{};
    space();
    if (take(0x7D)) {
      return _JsonNode(
        start,
        index,
        const <String, Object?>{},
        members,
        const <_JsonNode>[],
        source.substring(start, index).contains('\n'),
      );
    }
    var memberStart = index;
    while (true) {
      space();
      final keyStart = index;
      final key = string();
      if (members.containsKey(key)) {
        throw FormatException('Duplicate JSON key: $key.');
      }
      space();
      if (!take(0x3A)) throw const FormatException('Expected colon.');
      final valueNode = node(depth + 1);
      members[key] = _JsonMember(key, keyStart, valueNode, memberStart);
      space();
      if (take(0x7D)) {
        return _JsonNode(
          start,
          index,
          _membersValue(members),
          members,
          const <_JsonNode>[],
          source.substring(start, index).contains('\n'),
        );
      }
      if (!take(0x2C)) throw const FormatException('Expected object comma.');
      memberStart = index;
    }
  }

  _JsonNode array(int depth) {
    final start = index++;
    final items = <_JsonNode>[];
    space();
    if (take(0x5D)) {
      return _JsonNode(
        start,
        index,
        <Object?>[],
        const <String, _JsonMember>{},
        items,
        source.substring(start, index).contains('\n'),
      );
    }
    while (true) {
      items.add(node(depth + 1));
      space();
      if (take(0x5D)) {
        return _JsonNode(
          start,
          index,
          [for (final item in items) item.value],
          const <String, _JsonMember>{},
          items,
          source.substring(start, index).contains('\n'),
        );
      }
      if (!take(0x2C)) throw const FormatException('Expected array comma.');
    }
  }

  Map<String, Object?> _membersValue(Map<String, _JsonMember> members) =>
      <String, Object?>{
        for (final entry in members.entries) entry.key: entry.value.value.value,
      };

  Object? _value() {
    if (index >= source.length) {
      throw const FormatException('Unexpected JSON end.');
    }
    final char = source.codeUnitAt(index);
    if (char == 0x22) return string();
    if (source.startsWith('true', index)) {
      index += 4;
      return true;
    }
    if (source.startsWith('false', index)) {
      index += 5;
      return false;
    }
    if (source.startsWith('null', index)) {
      index += 4;
      return null;
    }
    final match = RegExp(
      r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
    ).matchAsPrefix(source, index);
    if (match == null) throw const FormatException('Invalid JSON value.');
    index = match.end;
    return num.parse(match.group(0)!);
  }

  String string() {
    final start = index++;
    while (index < source.length) {
      final char = source.codeUnitAt(index++);
      if (char == 0x22) {
        return jsonDecode(source.substring(start, index)) as String;
      }
      if (char == 0x5C) {
        if (index >= source.length) break;
        index++;
      } else if (char < 0x20) {
        throw const FormatException('Control character in JSON string.');
      }
    }
    throw const FormatException('Unterminated JSON string.');
  }

  void space() {
    while (index < source.length &&
        const [0x20, 0x09, 0x0A, 0x0D].contains(source.codeUnitAt(index))) {
      index++;
    }
  }

  bool take(int char) {
    if (index < source.length && source.codeUnitAt(index) == char) {
      index++;
      return true;
    }
    return false;
  }
}

final class _TomlEditor {
  _TomlEditor(this.text);
  final String text;

  String apply(List<ParentChange> changes, Map<String, Object?> proposed) {
    var result = text;
    final newline = result.contains('\r\n') ? '\r\n' : '\n';
    if (result.isEmpty) result = '';
    for (final change in changes) {
      final parts = change.unit.split('.');
      final value = proposed[change.unit];
      final section = parts.length == 1
          ? null
          : parts.sublist(0, parts.length - 1);
      final key = parts.last;
      final range = _findKey(result, section, key);
      if (range != null) {
        if (change.action == ParentAction.remove) {
          result = result.substring(0, range.$1) + result.substring(range.$2);
        } else {
          final encoded = _tomlEncode(value);
          result =
              '${result.substring(0, range.$3)}$encoded${result.substring(range.$4)}';
        }
      } else if (change.action != ParentAction.remove) {
        final insertion = _sectionInsertion(result, section, newline);
        final header = insertion.$2
            ? (section == null ? '' : '[${section.join('.')}]$newline')
            : '';
        final line = '$header$key = ${_tomlEncode(value)}$newline';
        result =
            '${result.substring(0, insertion.$1)}$line${result.substring(insertion.$1)}';
      }
    }
    if (result.isNotEmpty && !result.endsWith('\n') && text.endsWith('\n')) {
      result += newline;
    }
    return result;
  }

  // (lineStart,lineEnd,valueStart,valueEnd) for an existing key assignment.
  (int, int, int, int)? _findKey(
    String source,
    List<String>? section,
    String key,
  ) {
    var currentSection = <String>[];
    var offset = 0;
    for (final line in source.split('\n')) {
      final raw = line.endsWith('\r')
          ? line.substring(0, line.length - 1)
          : line;
      final trimmed = raw.trim();
      if (trimmed.startsWith('[') && trimmed.endsWith(']')) {
        final inner = trimmed.substring(1, trimmed.length - 1).trim();
        currentSection = inner.split('.').map((part) => part.trim()).toList();
      } else if (_sameSection(currentSection, section)) {
        final equals = raw.indexOf('=');
        if (equals > 0) {
          final rawKey = raw.substring(0, equals).trim();
          if (rawKey == key || rawKey == '"$key"') {
            final lineStart = offset;
            final lineEnd = offset + line.length + 1;
            final valueStart = () {
              var cursor = offset + equals + 1;
              while (cursor < offset + raw.length &&
                  (raw[cursor - offset] == ' ' ||
                      raw[cursor - offset] == '\t')) {
                cursor++;
              }
              return cursor;
            }();
            var valueEnd = offset + raw.length;
            final comment = _tomlCommentStart(raw, equals + 1);
            if (comment >= 0) valueEnd = offset + comment;
            while (valueEnd > valueStart && raw[valueEnd - offset - 1] == ' ') {
              valueEnd--;
            }
            return (lineStart, lineEnd, valueStart, valueEnd);
          }
        }
      }
      offset += line.length + 1;
    }
    return null;
  }

  (int, bool) _sectionInsertion(
    String source,
    List<String>? section,
    String newline,
  ) {
    if (section == null) {
      final header = source.indexOf(RegExp(r'^\[', multiLine: true));
      return (header < 0 ? source.length : header, false);
    }
    final marker = '[${section.join('.')}]';
    final start = source.indexOf(marker);
    if (start < 0) {
      return (source.length, true);
    }
    final next = source.indexOf(
      RegExp(r'^\[', multiLine: true),
      start + marker.length,
    );
    final end = next < 0 ? source.length : next;
    return (end, false);
  }
}

bool _sameSection(List<String> left, List<String>? right) {
  if (right == null) return left.isEmpty;
  if (left.length != right.length) return false;
  for (var i = 0; i < left.length; i++) {
    if (left[i] != right[i]) return false;
  }
  return true;
}

int _tomlCommentStart(String line, int from) {
  var quoted = false;
  var escaped = false;
  for (var i = from; i < line.length; i++) {
    final char = line[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        quoted = false;
      }
    } else if (char == '"') {
      quoted = true;
    } else if (char == '#') {
      return i;
    }
  }
  return -1;
}

String _tomlEncode(Object? value) {
  if (value is String) return jsonEncode(value);
  if (value is num || value is bool) return '$value';
  if (value is List) return '[${value.map(_tomlEncode).join(', ')}]';
  if (value is Map) {
    return '{ ${value.entries.map((entry) => '${jsonEncode(entry.key.toString())} = ${_tomlEncode(entry.value)}').join(', ')} }';
  }
  throw MambaException('Unsupported TOML value type.', exitCode: 2);
}
