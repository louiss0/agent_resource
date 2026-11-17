import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'lifecycle_state_service.dart';
import 'parent_config_service.dart';

/// Retires in-flight MCP parent-unit evidence from the parent-configuration
/// state directory, now that MCP registrations are no longer an `agent config`
/// write target.
///
/// The operation is reviewed: calling it with [apply] `false` inventories the
/// evidence and reports a redacted account without writing anything; with
/// [apply] `true` it drains only MCP-owned evidence. It refuses to drain while
/// any MCP parent transaction is in a non-terminal/recoverable phase, and it
/// never rewrites a native harness file or prints a credential value. The
/// classification of "MCP-owned" is based only on change-unit keys and the
/// transaction phase, never on stored values.
interface class McpParentRetirementService {
  McpParentRetirementService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : fs = fileSystem,
       io = LifecycleIO(fs: fileSystem);

  final fslib.FileSystem fs;
  final LifecycleIO io;

  /// Phases after which no recovery or cleanup work remains. Every other
  /// phase (including an unknown or missing one) is treated as recoverable.
  static const _terminalTransactionPhases = <String>{
    'committed',
    'failedRestored',
  };

  Future<ParentResult> drain({
    required LifecycleOptions options,
    required bool apply,
  }) async {
    final stateRoot = LifecycleContext.resolve(
      options,
      fileSystem: fs,
    ).stateRoot();

    final ledgerPath = fs.path.join(stateRoot, 'parent-units.json');
    final hadLedger =
        io.type(ledgerPath, followLinks: false) == FileSystemEntityType.file;
    final records = _readRecords(ledgerPath);
    final backups = _readBackups(stateRoot);
    final transactions = _readTransactions(stateRoot);

    // Classify MCP-owned evidence by its unit keys (never its values).
    final drainedBackupIds = <String>{};
    final mcpTouchedBackupIds = <String>{};
    for (final backup in backups) {
      final id = backup['backupId'];
      if (id is! String) continue;
      final units = _unitsOf(backup);
      if (units.any(isMcpParentUnit)) mcpTouchedBackupIds.add(id);
      // A mixed backup carries non-MCP evidence too, so it is never drained.
      if (units.isNotEmpty && units.every(isMcpParentUnit)) {
        drainedBackupIds.add(id);
      }
    }

    bool isMcpTransaction(_Transaction txn) {
      final backupId = txn.record['backupId'];
      if (backupId is String && mcpTouchedBackupIds.contains(backupId)) {
        return true;
      }
      if (_unitsOf(txn.record).any(isMcpParentUnit)) return true;
      final file = txn.record['file'];
      if (file is String) {
        final base = fs.path.basename(file).toLowerCase();
        if (base == '.mcp.json' || base == 'mcp.json') return true;
      }
      return false;
    }

    bool isTerminal(_Transaction txn) {
      final phase = txn.record['phase'];
      return phase is String && _terminalTransactionPhases.contains(phase);
    }

    // Fail closed: a half-completed MCP operation is never silently discarded.
    final pendingIds = <String>[];
    final drainingTransactions = <_Transaction>[];
    final preservedTransactionIds = <String>[];
    for (final txn in transactions) {
      final mcp = isMcpTransaction(txn);
      if (mcp && !isTerminal(txn)) {
        pendingIds.add(txn.id);
      } else if (mcp) {
        drainingTransactions.add(txn);
      } else {
        preservedTransactionIds.add(txn.id);
      }
    }
    if (pendingIds.isNotEmpty) {
      pendingIds.sort();
      throw MambaException(
        'MCP parent transactions are still in flight and must be resolved '
        'with the existing parent-config recovery, restore, or cleanup path '
        'before draining. Pending transaction IDs: ${pendingIds.join(', ')}. '
        'No evidence was removed and no native file was changed.',
        exitCode: 4,
      );
    }

    // Prune MCP unit evidence from the ledger. Non-MCP units and records are
    // preserved; a record is dropped only when every unit it owns is MCP.
    final drainedRecordIds = <String>[];
    final preservedRecordIds = <String>[];
    final prunedUnitNames = <String>[];
    final keptRecords = <Map<String, Object?>>[];
    for (final record in records) {
      final units = record['units'] is List
          ? (record['units']! as List<Object?>)
                .whereType<Map<String, Object?>>()
                .toList()
          : <Map<String, Object?>>[];
      final keptUnits = <Map<String, Object?>>[];
      for (final unit in units) {
        final name = unit['unit'];
        if (name is String && isMcpParentUnit(name)) {
          prunedUnitNames.add(name);
        } else {
          keptUnits.add(unit);
        }
      }
      final keptBackupIds = record['backupIds'] is List
          ? (record['backupIds']! as List<Object?>)
                .whereType<String>()
                .where((id) => !drainedBackupIds.contains(id))
                .toList()
          : <String>[];
      final id = record['parentId'] is String
          ? record['parentId']! as String
          : '';
      if (keptUnits.isEmpty) {
        drainedRecordIds.add(id);
        continue;
      }
      keptRecords.add(<String, Object?>{
        ...record,
        'units': keptUnits,
        'backupIds': keptBackupIds,
      });
      preservedRecordIds.add(id);
    }

    final preservedBackupIds = <String>[
      for (final backup in backups)
        if (backup['backupId'] is String &&
            !drainedBackupIds.contains(backup['backupId']))
          backup['backupId']! as String,
    ];

    final drainedRecords = drainedRecordIds..sort();
    final preservedRecords = preservedRecordIds..sort();
    final drainedBackups = drainedBackupIds.toList()..sort();
    final drainedTransactions =
        drainingTransactions.map((txn) => txn.id).toList()..sort();
    preservedBackupIds.sort();
    preservedTransactionIds.sort();
    prunedUnitNames.sort();

    if (apply) {
      _applyDrain(
        ledgerPath: ledgerPath,
        hadLedger: hadLedger,
        keptRecords: keptRecords,
        drainedBackupIds: drainedBackupIds,
        drainedTransactionPaths: [
          for (final txn in drainingTransactions) txn.path,
        ],
        stateRoot: stateRoot,
      );
    }

    return ParentResult(
      command: 'agent config drain-mcp',
      outcome: apply ? 'drained' : 'inventoried',
      data: <String, Object?>{
        'scope': options.scope.name,
        'writes': apply,
        'reviewRequired': !apply,
        'redaction': 'credential-and-value-data-omitted',
        'nativeFilesWritten': const <String>[],
        'drained': <String, Object?>{
          'records': drainedRecords,
          'recordUnits': prunedUnitNames,
          'backups': drainedBackups,
          'transactions': drainedTransactions,
        },
        'preserved': <String, Object?>{
          'records': preservedRecords,
          'backups': preservedBackupIds,
          'transactions': preservedTransactionIds,
        },
      },
    );
  }

  void _applyDrain({
    required String ledgerPath,
    required bool hadLedger,
    required List<Map<String, Object?>> keptRecords,
    required Set<String> drainedBackupIds,
    required List<String> drainedTransactionPaths,
    required String stateRoot,
  }) {
    // Only the management ledger is rewritten; no native harness file is
    // ever touched. Avoid creating a ledger where none existed.
    if (hadLedger) {
      io.write(
        ledgerPath,
        utf8.encode(
          jsonEncode(<String, Object?>{
            'schemaVersion': 1,
            'records': keptRecords,
          }),
        ),
      );
    }
    for (final id in drainedBackupIds) {
      final directory = fs.path.join(stateRoot, 'parent-backups', id);
      if (io.type(directory, followLinks: false) !=
          FileSystemEntityType.notFound) {
        io.delete(directory);
      }
    }
    for (final path in drainedTransactionPaths) {
      if (io.type(path, followLinks: false) != FileSystemEntityType.notFound) {
        io.delete(path);
      }
    }
  }

  List<Map<String, Object?>> _readRecords(String ledgerPath) {
    if (io.type(ledgerPath, followLinks: false) != FileSystemEntityType.file) {
      return <Map<String, Object?>>[];
    }
    final document = _readObject(ledgerPath);
    _requireVersion(document, 'parent-unit ledger');
    final records = document['records'];
    if (records is! List) return <Map<String, Object?>>[];
    return records.whereType<Map<String, Object?>>().toList();
  }

  List<Map<String, Object?>> _readBackups(String stateRoot) {
    final root = fs.path.join(stateRoot, 'parent-backups');
    if (io.type(root, followLinks: false) != FileSystemEntityType.directory) {
      return <Map<String, Object?>>[];
    }
    final result = <Map<String, Object?>>[];
    for (final entity in io.list(root)) {
      if (io.type(entity.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        continue;
      }
      final metadata = fs.path.join(entity.path, 'backup.json');
      if (io.type(metadata, followLinks: false) != FileSystemEntityType.file) {
        throw MambaException(
          'Parent backup metadata is missing; MCP evidence was not changed.',
          exitCode: 4,
        );
      }
      final record = _readObject(metadata);
      _requireVersion(record, 'parent backup');
      result.add(record);
    }
    return result;
  }

  List<_Transaction> _readTransactions(String stateRoot) {
    final root = fs.path.join(stateRoot, 'parent-transactions');
    if (io.type(root, followLinks: false) != FileSystemEntityType.directory) {
      return <_Transaction>[];
    }
    final result = <_Transaction>[];
    for (final entity in io.list(root)) {
      if (io.type(entity.path, followLinks: false) !=
              FileSystemEntityType.file ||
          !entity.path.endsWith('.json')) {
        continue;
      }
      final record = _readObject(entity.path);
      _requireVersion(record, 'parent transaction');
      final id = record['transactionId'] is String
          ? record['transactionId']! as String
          : fs.path.basenameWithoutExtension(entity.path);
      result.add(_Transaction(id, entity.path, record));
    }
    return result;
  }

  Map<String, Object?> _readObject(String path) {
    final bytes = io.read(path, parentDocumentLimit);
    if (bytes.length > parentDocumentLimit) {
      throw MambaException(
        'Parent retirement evidence exceeds 8 MiB.',
        exitCode: 3,
      );
    }
    try {
      return parseStrictJsonObject(utf8.decode(bytes, allowMalformed: false));
    } on FormatException catch (error) {
      throw MambaException(
        'Unreadable parent retirement evidence: ${error.message}',
        exitCode: 4,
      );
    }
  }

  // Explicit compatibility rule: an explicitly newer/unknown version is never
  // silently drained. Legacy evidence without a version is still classifiable
  // by unit keys and is preserved or drained accordingly.
  void _requireVersion(Map<String, Object?> document, String kind) {
    final version = document['schemaVersion'];
    if (version != null && version != 1) {
      throw MambaException(
        'Unsupported $kind version; MCP parent evidence was not changed.',
        exitCode: 4,
      );
    }
  }

  List<String> _unitsOf(Map<String, Object?> artifact) {
    final raw = artifact['units'];
    if (raw is! List) return const <String>[];
    return <String>[
      for (final entry in raw)
        if (entry is Map && entry['unit'] is String) entry['unit'] as String,
    ];
  }
}

final class _Transaction {
  const _Transaction(this.id, this.path, this.record);
  final String id;
  final String path;
  final Map<String, Object?> record;
}
