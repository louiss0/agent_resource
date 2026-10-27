import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import '../skill_files.dart';
import 'native_link_service.dart';

const managementSchemaVersion = 1;
const maxManagementDocumentBytes = 8 * 1024 * 1024;
const maxManagementDepth = 32;
const maxManagementNodes = 100000;
const maxSkillEntries = 10000;
const maxSkillDepth = 32;
const maxSkillFileBytes = 64 * 1024 * 1024;
const maxSkillAggregateBytes = 256 * 1024 * 1024;
const maxManagementAggregateBytes = 64 * 1024 * 1024;
final _metadataBudgetZone = Object();

final class _MetadataBudget {
  var bytes = 0;
}

void _chargeManagementBytes(int count, Zone? zone) {
  final budget = zone?[_metadataBudgetZone];
  if (budget is! _MetadataBudget) return;
  budget.bytes += count;
  if (budget.bytes > maxManagementAggregateBytes) {
    throw MambaException(
      'Management metadata exceeds the 64 MiB per-transaction budget.',
      exitCode: 3,
    );
  }
}

enum LifecycleScope { project, user, all }

enum ArtifactKind {
  skillCopy('skill-copy'),
  skillLink('skill-link'),
  agentFile('agent-file');

  const ArtifactKind(this.wireName);
  final String wireName;
}

enum ModificationStatus {
  unchanged,
  changed,
  missing,
  unableToVerify,
  notVerified,
}

/// Captured process and request context. No environment lookup is deferred
/// until after a command has begun an operation.
final class LifecycleOptions {
  const new({
    required this.processWorkingDirectory,
    this.environment = const <String, String>{},
    this.scope = LifecycleScope.project,
    this.cwd,
    this.projectRoot,
    this.home,
    this.claudeConfigDir,
    this.codexHome,
    this.piAgentDir,
    this.stateDir,
    this.readRoots = const <String>[],
    this.dryRun = false,
    this.approved = false,
  });

  final String processWorkingDirectory;
  final Map<String, String> environment;
  final LifecycleScope scope;
  final String? cwd;
  final String? projectRoot;
  final String? home;
  final String? claudeConfigDir;
  final String? codexHome;
  final String? piAgentDir;
  final String? stateDir;
  final List<String> readRoots;
  final bool dryRun;
  final bool approved;

  LifecycleOptions copyWith({
    LifecycleScope? scope,
    bool? dryRun,
    bool? approved,
  }) => LifecycleOptions(
    processWorkingDirectory: processWorkingDirectory,
    environment: environment,
    scope: scope ?? this.scope,
    cwd: cwd,
    projectRoot: projectRoot,
    home: home,
    claudeConfigDir: claudeConfigDir,
    codexHome: codexHome,
    piAgentDir: piAgentDir,
    stateDir: stateDir,
    readRoots: readRoots,
    dryRun: dryRun ?? this.dryRun,
    approved: approved ?? this.approved,
  );
}

final class LifecycleContext {
  LifecycleContext._({
    required this.options,
    required this.cwd,
    required this.projectRoot,
    required this.home,
  });

  factory LifecycleContext.resolve(LifecycleOptions options) {
    final processCwd = _existingDirectory(
      options.processWorkingDirectory,
      options.processWorkingDirectory,
      'process working directory',
    );
    final cwd = _existingDirectory(
      options.cwd ?? processCwd,
      processCwd,
      'working directory',
    );
    final projectRoot = _projectRoot(options, cwd);
    final home = options.home == null
        ? null
        : _existingDirectory(options.home!, cwd, 'home directory');
    return LifecycleContext._(
      options: options,
      cwd: cwd,
      projectRoot: projectRoot,
      home: home,
    );
  }

  final LifecycleOptions options;
  final String cwd;
  final String projectRoot;
  final String? home;

  LifecycleScope get scope => options.scope;
  bool get dryRun => options.dryRun;
  bool get approved => options.approved;

  String resolvePath(String raw) {
    _rejectTerminalControls(raw);
    if (raw.trim().isEmpty) {
      throw MambaException('A filesystem path must not be blank.');
    }
    return p.normalize(p.isAbsolute(raw) ? raw : p.join(cwd, raw));
  }

  String requireHome() {
    final explicit = home;
    if (explicit != null) return explicit;
    final value = _environment('HOME') ?? _environment('USERPROFILE');
    if (value == null) {
      throw MambaException(
        'A home directory is required for user scope; supply --home.',
      );
    }
    return _existingDirectory(value, cwd, 'home directory');
  }

  String? _environment(String name) {
    final value = options.environment[name];
    return value == null || value.trim().isEmpty ? null : value;
  }

  String claudeConfigRoot() => resolvePath(
    options.claudeConfigDir ??
        _environment('CLAUDE_CONFIG_DIR') ??
        p.join(requireHome(), '.claude'),
  );

  String codexRoot() => resolvePath(
    options.codexHome ??
        _environment('CODEX_HOME') ??
        p.join(requireHome(), '.codex'),
  );

  String piAgentRoot() => resolvePath(
    options.piAgentDir ??
        _environment('PI_CODING_AGENT_DIR') ??
        p.join(requireHome(), '.pi', 'agent'),
  );

  String stateRoot([LifecycleScope? selectedScope]) {
    final selected = selectedScope ?? scope;
    if (selected == LifecycleScope.all) {
      throw MambaException('A mutation must select exactly one scope.');
    }
    if (selected == LifecycleScope.project) {
      return p.normalize(p.join(projectRoot, '.agent-resource'));
    }
    final explicit = options.stateDir;
    if (explicit != null) return resolvePath(explicit);
    if (Platform.isWindows) {
      final local = _environment('LOCALAPPDATA');
      if (local == null) {
        throw MambaException(
          'LOCALAPPDATA is required for user state; supply --state-dir.',
        );
      }
      return p.normalize(p.join(local, 'AgentResource'));
    }
    if (Platform.isMacOS) {
      return p.normalize(
        p.join(
          requireHome(),
          'Library',
          'Application Support',
          'AgentResource',
        ),
      );
    }
    final xdg = _environment('XDG_STATE_HOME');
    if (xdg != null && p.isAbsolute(xdg)) {
      return p.normalize(p.join(xdg, 'agent-resource'));
    }
    return p.normalize(
      p.join(requireHome(), '.local', 'state', 'agent-resource'),
    );
  }

  String claudeSkillsRoot() => scope == LifecycleScope.project
      ? p.join(projectRoot, '.claude', 'skills')
      : p.join(claudeConfigRoot(), 'skills');

  String codexSkillsRoot() => scope == LifecycleScope.project
      ? p.join(projectRoot, '.codex', 'skills')
      : p.join(codexRoot(), 'skills');

  String sharedSkillsRoot() => scope == LifecycleScope.project
      ? p.join(projectRoot, '.agents', 'skills')
      : p.join(requireHome(), '.agents', 'skills');

  String claudeAgentsRoot([String? boundary]) =>
      p.join(boundary ?? projectRoot, '.claude', 'agents');

  String codexAgentsRoot([String? boundary]) =>
      p.join(boundary ?? projectRoot, '.codex', 'agents');

  String piAgentsRoot() => scope == LifecycleScope.project
      ? p.join(projectRoot, '.pi', 'agents')
      : p.join(piAgentRoot(), 'agents');

  String piSharedAgentsRoot() {
    if (scope != LifecycleScope.project) {
      throw MambaException(
        'Pi shared Agent installation is unsupported at user scope.',
        exitCode: 4,
      );
    }
    return p.join(projectRoot, '.agents', 'agents');
  }

  static String _projectRoot(LifecycleOptions options, String cwd) {
    final explicit = options.projectRoot;
    if (explicit != null) {
      final root = _existingDirectory(explicit, cwd, 'project root');
      if (!p.equals(root, cwd) && !p.isWithin(root, cwd)) {
        throw MambaException(
          'The project root must contain the working directory.',
        );
      }
      return root;
    }
    var current = cwd;
    for (var step = 0; step < 64; step++) {
      final marker = p.join(current, '.git');
      final type = skillEntityType(marker, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.directory) {
        return current;
      }
      final parent = p.dirname(current);
      if (p.equals(parent, current)) return cwd;
      current = parent;
    }
    throw MambaException(
      'The project boundary search exceeds the 64-step budget.',
      exitCode: 3,
    );
  }

  static String _existingDirectory(String raw, String base, String label) {
    _rejectTerminalControls(raw);
    if (raw.trim().isEmpty) {
      throw MambaException('The $label path must not be blank.');
    }
    final path = p.normalize(p.isAbsolute(raw) ? raw : p.join(base, raw));
    final type = skillEntityType(path, followLinks: true);
    if (type == FileSystemEntityType.notFound) {
      throw MambaException('The $label does not exist: $path');
    }
    if (type != FileSystemEntityType.directory) {
      throw MambaException('The $label is not a directory: $path');
    }
    return path;
  }
}

final class LifecycleReplaceInput {
  const new({
    required this.options,
    required this.installationId,
    required this.source,
  });

  final LifecycleOptions options;
  final String installationId;
  final String source;
}

final class LifecycleIdInput {
  const new({required this.options, required this.id});

  final LifecycleOptions options;
  final String id;
}

final class LifecycleResult {
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
            buffer.writeln(
              '$indent${entry.key}: ${_terminalSafe(entry.value)}',
            );
          }
        }
      } else if (value is List) {
        if (value.isEmpty) buffer.writeln('$indent[]');
        for (final item in value) {
          buffer.writeln('$indent-');
          render(item, '$indent  ');
        }
      } else {
        buffer.writeln('$indent${_terminalSafe(value)}');
      }
    }

    render(data, '');
    render(<String, Object?>{'diagnostics': diagnostics}, '');
    return buffer.toString();
  }
}

final class LifecycleCandidate {
  const new({
    required this.name,
    required this.nativeForm,
    this.validatedProfiles = const <String>[],
    this.knownConsumers = const <String>[],
  });

  final String name;
  final String nativeForm;
  final List<String> validatedProfiles;
  final List<String> knownConsumers;
}

/// Native validation and uniqueness supplied by the Skill and Agent slices.
abstract interface class LifecycleResource {
  ArtifactKind get kind;

  void validateAuthority(InstallationRecord record, LifecycleContext context);

  Future<LifecycleCandidate> inspect(
    String path,
    LifecycleContext context, {
    String? expectedName,
  });

  Future<void> checkUnique(
    LifecycleContext context,
    String name, {
    required String nativeDestination,
    String? excludeInstallationId,
    String? excludePath,
  });
}

final class BaselineEntry {
  const new({
    required this.path,
    required this.type,
    required this.length,
    required this.sha256,
    required this.executable,
    required this.readOnly,
    this.target,
    this.nativeKind,
    this.originalParent,
  });

  factory BaselineEntry.fromJson(Object? value) {
    final map = _object(value, 'baseline entry');
    final entry = BaselineEntry(
      path: _relativePath(_string(map, 'path')),
      type: _enumValue(_string(map, 'type'), const [
        'file',
        'directory',
        'link',
      ]),
      length: _nonNegativeInteger(map, 'length'),
      sha256: _digest(map['sha256']),
      executable: _bool(map, 'executable'),
      readOnly: _bool(map, 'readOnly'),
      target: _nullableString(map, 'target'),
      nativeKind: _nullableString(map, 'nativeKind'),
      originalParent: map['originalParent'] == null
          ? null
          : _absolutePath(_string(map, 'originalParent')),
    );
    if (entry.type == 'link') {
      if (entry.path != '.' ||
          entry.length != 0 ||
          entry.sha256 != null ||
          entry.target == null ||
          entry.nativeKind == null ||
          entry.originalParent == null) {
        throw const FormatException('Invalid linked-entry baseline.');
      }
    } else if (entry.target != null ||
        entry.nativeKind != null ||
        entry.originalParent != null) {
      throw const FormatException('Unexpected link evidence in file baseline.');
    }
    return entry;
  }

  final String path;
  final String type;
  final int length;
  final String? sha256;
  final bool executable;
  final bool readOnly;
  final String? target;
  final String? nativeKind;
  final String? originalParent;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'type': type,
    'length': length,
    'sha256': sha256,
    'executable': executable,
    'readOnly': readOnly,
    if (target != null) 'target': target,
    if (nativeKind != null) 'nativeKind': nativeKind,
    if (originalParent != null) 'originalParent': originalParent,
  };
}

final class ArtifactBaseline {
  const new(this.entries);

  factory ArtifactBaseline.fromJson(Object? value) {
    final list = _list(value, 'baseline');
    return ArtifactBaseline([
      for (final entry in list) BaselineEntry.fromJson(entry),
    ]);
  }

  final List<BaselineEntry> entries;

  String get digest => sha256
      .convert(utf8.encode(jsonEncode([for (final e in entries) e.toJson()])))
      .toString();

  List<Map<String, Object?>> toJson() => [
    for (final entry in entries) entry.toJson(),
  ];
}

final class BackupRecord {
  const new({
    required this.backupId,
    required this.installationId,
    required this.transactionId,
    required this.kind,
    required this.scope,
    required this.location,
    required this.nativeRoot,
    required this.baseline,
    required this.artifactPath,
    required this.retention,
  });

  factory BackupRecord.fromJson(Object? value, String state) {
    final map = _object(value, 'backup');
    final backupId = _id(_string(map, 'backupId'), 'bak');
    final kindName = _enumValue(
      _string(map, 'artifactKind'),
      ArtifactKind.values.map((value) => value.wireName).toList(),
    );
    final kind = ArtifactKind.values.firstWhere(
      (value) => value.wireName == kindName,
    );
    final artifactPath = _absolutePath(_string(map, 'artifactPath'));
    final expectedDirectory = p.join(state, 'backups', backupId);
    if (!p.equals(p.dirname(artifactPath), expectedDirectory) ||
        p.basename(artifactPath) !=
            switch (kind) {
              ArtifactKind.skillCopy => 'artifact',
              ArtifactKind.skillLink => 'artifact-link.json',
              ArtifactKind.agentFile =>
                'artifact${p.extension(_string(map, 'location'))}',
            }) {
      throw const FormatException('Backup artifact path is not manager-owned.');
    }
    final scopeName = _enumValue(_string(map, 'scope'), const [
      'project',
      'user',
    ]);
    return BackupRecord(
      backupId: backupId,
      installationId: _id(_string(map, 'installationId'), 'ins'),
      transactionId: _id(_string(map, 'transactionId'), 'trx'),
      kind: kind,
      scope: LifecycleScope.values.firstWhere(
        (value) => value.name == scopeName,
      ),
      location: _absolutePath(_string(map, 'location')),
      nativeRoot: _absolutePath(_string(map, 'nativeRoot')),
      baseline: ArtifactBaseline.fromJson(map['baseline']),
      artifactPath: artifactPath,
      retention: _enumValue(_string(map, 'retention'), const [
        'retained',
        'cleaned',
      ]),
    );
  }

  final String backupId;
  final String installationId;
  final String transactionId;
  final ArtifactKind kind;
  final LifecycleScope scope;
  final String location;
  final String nativeRoot;
  final ArtifactBaseline baseline;
  final String artifactPath;
  final String retention;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'backupId': backupId,
    'installationId': installationId,
    'transactionId': transactionId,
    'artifactKind': kind.wireName,
    'scope': scope.name,
    'location': location,
    'nativeRoot': nativeRoot,
    'baseline': baseline.toJson(),
    'artifactDigest': baseline.digest,
    'artifactPath': artifactPath,
    'retention': retention,
  };

  BackupRecord copyWith({String? retention}) => BackupRecord(
    backupId: backupId,
    installationId: installationId,
    transactionId: transactionId,
    kind: kind,
    scope: scope,
    location: location,
    nativeRoot: nativeRoot,
    baseline: baseline,
    artifactPath: artifactPath,
    retention: retention ?? this.retention,
  );
}

final class InstallationRecord {
  const new({
    required this.installationId,
    required this.kind,
    required this.scope,
    required this.nativeDestination,
    required this.nativeForm,
    required this.location,
    required this.nativeRoot,
    required this.name,
    required this.nativeProfile,
    required this.validatedProfiles,
    required this.knownConsumers,
    required this.baseline,
    required this.lifecycle,
    required this.origin,
    required this.backupIds,
    required this.transactionId,
  });

  factory InstallationRecord.fromJson(Object? value) {
    final map = _object(value, 'installation');
    final scope = _enumValue(_string(map, 'scope'), const ['project', 'user']);
    final kind = _enumValue(
      _string(map, 'artifactKind'),
      ArtifactKind.values.map((value) => value.wireName).toList(),
    );
    final location = _absolutePath(_string(map, 'location'));
    final nativeRoot = _absolutePath(_string(map, 'nativeRoot'));
    if (!p.isWithin(nativeRoot, location)) {
      throw const FormatException('Installation location escapes native root.');
    }
    return InstallationRecord(
      installationId: _id(_string(map, 'installationId'), 'ins'),
      kind: ArtifactKind.values.firstWhere((value) => value.wireName == kind),
      scope: LifecycleScope.values.firstWhere((value) => value.name == scope),
      nativeDestination: _string(map, 'nativeDestination'),
      nativeForm: _string(map, 'nativeForm'),
      location: location,
      nativeRoot: nativeRoot,
      name: _string(map, 'name'),
      nativeProfile: _nullableString(map, 'nativeProfile'),
      validatedProfiles: _stringList(map['validatedProfiles']),
      knownConsumers: _stringList(map['knownConsumers']),
      baseline: ArtifactBaseline.fromJson(map['baseline']),
      lifecycle: _enumValue(_string(map, 'lifecycle'), const [
        'live',
        'removed',
      ]),
      origin: _object(map['origin'], 'origin'),
      backupIds: [
        for (final id in _stringList(map['backupIds'])) _id(id, 'bak'),
      ],
      transactionId: _nullableId(map['transactionId'], 'trx'),
    );
  }

  final String installationId;
  final ArtifactKind kind;
  final LifecycleScope scope;
  final String nativeDestination;
  final String nativeForm;
  final String location;
  final String nativeRoot;
  final String name;
  final String? nativeProfile;
  final List<String> validatedProfiles;
  final List<String> knownConsumers;
  final ArtifactBaseline baseline;
  final String lifecycle;
  final Map<String, Object?> origin;
  final List<String> backupIds;
  final String? transactionId;

  InstallationRecord copyWith({
    ArtifactKind? kind,
    String? nativeForm,
    ArtifactBaseline? baseline,
    String? lifecycle,
    List<String>? backupIds,
    String? transactionId,
    bool clearTransaction = false,
  }) => InstallationRecord(
    installationId: installationId,
    kind: kind ?? this.kind,
    scope: scope,
    nativeDestination: nativeDestination,
    nativeForm: nativeForm ?? this.nativeForm,
    location: location,
    nativeRoot: nativeRoot,
    name: name,
    nativeProfile: nativeProfile,
    validatedProfiles: validatedProfiles,
    knownConsumers: knownConsumers,
    baseline: baseline ?? this.baseline,
    lifecycle: lifecycle ?? this.lifecycle,
    origin: origin,
    backupIds: backupIds ?? this.backupIds,
    transactionId: clearTransaction
        ? null
        : transactionId ?? this.transactionId,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'installationId': installationId,
    'artifactKind': kind.wireName,
    'scope': scope.name,
    'nativeDestination': nativeDestination,
    'nativeForm': nativeForm,
    'location': location,
    'nativeRoot': nativeRoot,
    'name': name,
    'nativeProfile': nativeProfile,
    'validatedProfiles': validatedProfiles,
    'knownConsumers': knownConsumers,
    'baseline': baseline.toJson(),
    'origin': origin,
    'lifecycle': lifecycle,
    'backupIds': backupIds,
    'transactionId': transactionId,
  };
}

/// Narrow filesystem seam used by deterministic failure tests. The default
/// implementation performs only local filesystem operations.
class LifecycleIO {
  const new();

  void before(String operation, String path) {}

  FileSystemEntityType type(String path, {required bool followLinks}) =>
      skillEntityType(path, followLinks: followLinks);

  List<FileSystemEntity> list(String path) =>
      Directory(path).listSync(followLinks: false);

  List<int> read(String path, int maxBytes) {
    before('read', path);
    final file = File(path).openSync();
    try {
      return file.readSync(maxBytes + 1);
    } finally {
      file.closeSync();
    }
  }

  void createDirectory(String path) {
    before('createDirectory', path);
    Directory(path).createSync(recursive: true);
  }

  void copyFile(String source, String destination) {
    before('copy', source);
    File(source).copySync(destination);
  }

  void rename(String source, String destination) {
    before('rename', source);
    final type = this.type(source, followLinks: false);
    switch (type) {
      case FileSystemEntityType.file:
        File(source).renameSync(destination);
      case FileSystemEntityType.directory:
        Directory(source).renameSync(destination);
      case FileSystemEntityType.link:
        Link(source).renameSync(destination);
      default:
        throw FileSystemException('Cannot rename unsupported entry', source);
    }
  }

  void delete(String path) {
    before('delete', path);
    final type = this.type(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.file:
        File(path).deleteSync();
      case FileSystemEntityType.directory:
        Directory(path).deleteSync(recursive: true);
      case FileSystemEntityType.link:
        Link(path).deleteSync();
      default:
        throw FileSystemException('Cannot delete unsupported entry', path);
    }
  }

  void deleteEmptyDirectory(String path) {
    before('deleteEmptyDirectory', path);
    Directory(path).deleteSync();
  }

  void write(String path, List<int> bytes) {
    before('write', path);
    File(path).writeAsBytesSync(bytes, flush: true);
  }

  String linkKind(String path) => const NativeLinkService().inspectKind(path);

  String readLink(String path) => const NativeLinkService().readTarget(path);

  void createLink(String path, String target) {
    before('createLink', path);
    const NativeLinkService().createDirectoryLink(path, target);
  }
}

interface class LifecycleStateService {
  LifecycleStateService({this.io = const LifecycleIO()});

  final LifecycleIO io;

  /// Stages a proposed native source on the destination volume only after
  /// private preparation has been established. The source is temporary input
  /// to the ordinary lifecycle transaction, not retained recovery evidence.
  Future<T> withStagedSource<T>({
    required String nativeRoot,
    required String name,
    required List<int> bytes,
    required Future<T> Function(String path) body,
  }) async {
    if (p.basename(name) != name || name == '.' || name == '..') {
      throw MambaException('A staged source requires a plain basename.');
    }
    final root = p.join(p.dirname(nativeRoot), '.agent-resource-authoring');
    _makePrivate(root);
    final transactionId = _newId('authoring');
    final directory = p.join(root, transactionId);
    final path = p.join(directory, name);
    io.createDirectory(directory);
    try {
      io.write(path, bytes);
      return await body(path);
    } finally {
      _removeIfPresent(directory);
      try {
        if (io.list(root).isEmpty) {
          io.deleteEmptyDirectory(root);
        }
      } on FileSystemException {
        // Another candidate may be preparing concurrently; never recursively
        // remove shared authoring storage.
      }
    }
  }

  static final _inProcessLocks = <String, Future<void>>{};
  static final _random = Random.secure();

  Future<LifecycleResult> install({
    required LifecycleResource resource,
    required LifecycleContext context,
    required String source,
    required String location,
    required String nativeRoot,
    required String nativeDestination,
  }) async {
    final prepared = await _prepareInstall(
      resource,
      context,
      source,
      location,
      nativeRoot,
      nativeDestination,
    );
    if (context.dryRun) {
      return LifecycleResult(
        command: '${_resourceLabel(resource.kind)} install',
        outcome: 'planned',
        data: _planData('install', context, location, prepared.candidate),
      );
    }
    return _serialized(context, location, () async {
      final current = await _prepareInstall(
        resource,
        context,
        source,
        location,
        nativeRoot,
        nativeDestination,
      );
      _blockPendingAcrossScopes(context, location);
      final transactionId = _newId('trx');
      final installationId = _newId('ins');
      final state = context.stateRoot();
      final stage = _stagePath(
        nativeRoot,
        transactionId,
        resource.kind == ArtifactKind.agentFile
            ? p.basename(location)
            : current.candidate.name,
      );
      final transactionPath = p.join(
        state,
        'transactions',
        '$transactionId.json',
      );
      var published = false;
      var committed = false;
      try {
        _ensureLedger(state);
        _prepareStaging(nativeRoot);
        final linkTarget = _copySource(
          source,
          stage,
          resource.kind,
          linkDestination: location,
        );
        final stagedCandidate = await resource.inspect(
          resource.kind == ArtifactKind.skillLink ? linkTarget! : stage,
          context,
          expectedName: current.candidate.name,
        );
        _sameCandidate(current.candidate, stagedCandidate);
        final baseline = resource.kind == ArtifactKind.skillLink
            ? _linkBaselineFor(location, io.readLink(stage), io.linkKind(stage))
            : _manifest(stage, resource.kind);
        if (resource.kind != ArtifactKind.skillLink &&
            baseline.digest != current.sourceDigest) {
          throw MambaException(
            'The staged output did not preserve the validated source bytes and attributes.',
            exitCode: 4,
          );
        }
        if (_manifest(source, _contentKind(resource.kind)).digest !=
            current.sourceDigest) {
          throw MambaException(
            'The source changed during installation.',
            exitCode: 4,
          );
        }
        await resource.checkUnique(
          context,
          current.candidate.name,
          nativeDestination: nativeDestination,
        );
        _requireAbsent(location);
        final record = InstallationRecord(
          installationId: installationId,
          kind: resource.kind,
          scope: context.scope,
          nativeDestination: nativeDestination,
          nativeForm: current.candidate.nativeForm,
          location: location,
          nativeRoot: nativeRoot,
          name: current.candidate.name,
          nativeProfile: current.candidate.validatedProfiles.length == 1
              ? current.candidate.validatedProfiles.single
              : null,
          validatedProfiles: current.candidate.validatedProfiles,
          knownConsumers: current.candidate.knownConsumers,
          baseline: baseline,
          lifecycle: 'live',
          origin: const <String, Object?>{'status': 'unknown'},
          backupIds: const <String>[],
          transactionId: null,
        );
        _writeTransaction(transactionPath, <String, Object?>{
          'schemaVersion': 1,
          'transactionId': transactionId,
          'installationId': installationId,
          'operation': 'install',
          'artifactKind': resource.kind.wireName,
          'scope': context.scope.name,
          'location': location,
          'nativeRoot': nativeRoot,
          'sourceDigest': current.sourceDigest,
          'newBaseline': baseline.toJson(),
          'newRecord': record.toJson(),
          'phase': 'prepared',
          'stagedPath': stage,
          'quarantinePath': _quarantinePath(
            nativeRoot,
            transactionId,
            location,
          ),
        });
        io.createDirectory(p.dirname(location));
        _requireAbsent(location);
        io.rename(stage, location);
        published = true;
        _writeTransaction(transactionPath, <String, Object?>{
          ..._readTransaction(transactionPath),
          'phase': 'published',
        });
        _verifyBaseline(location, baseline, resource.kind);
        _commitRecords(state, [record], const <String, Object?>{});
        committed = true;
        _writeTransaction(transactionPath, <String, Object?>{
          ..._readTransaction(transactionPath),
          'installationId': installationId,
          'phase': 'committed',
        });
        _removeIfPresent(p.dirname(stage));
        return LifecycleResult(
          command: '${_resourceLabel(resource.kind)} install',
          outcome: 'installed',
          data: <String, Object?>{
            'installationId': installationId,
            'transactionId': transactionId,
            'location': location,
            'scope': context.scope.name,
            'nativeDestination': nativeDestination,
            'modification': 'unchanged',
            'backupRetained': false,
          },
        );
      } catch (error) {
        if (committed) {
          throw MambaException(
            'Installation committed but required cleanup or terminal journaling '
            'is pending; transaction $transactionId, evidence $transactionPath. $error',
            exitCode: 6,
          );
        }
        if (published) {
          final restored = _restoreFailedInstall(
            location,
            stage,
            transactionPath,
          );
          if (restored) {
            throw MambaException(
              'Installation failed and the original absent state was restored; '
              'transaction $transactionId. $error',
              exitCode: 5,
            );
          }
          throw MambaException(
            'Installation requires recovery; transaction $transactionId, '
            'evidence $transactionPath. $error',
            exitCode: 6,
          );
        }
        if (error is MambaException) rethrow;
        throw MambaException(
          'Installation failed before publication; protected preparation '
          'evidence $transactionPath. $error',
          exitCode: 1,
        );
      }
    });
  }

  Future<LifecycleResult> adopt({
    required LifecycleResource resource,
    required LifecycleContext context,
    required String location,
    required String nativeRoot,
    required String nativeDestination,
  }) async {
    final candidate = await resource.inspect(location, context);
    final baseline = _manifest(location, resource.kind);
    await resource.checkUnique(
      context,
      candidate.name,
      nativeDestination: nativeDestination,
      excludePath: location,
    );
    final state = context.stateRoot();
    final existing = _findRecord(state, location: location);
    if (existing == null) {
      _refuseCrossScopeOwnership(context, location);
    }
    if (existing != null) {
      if (existing.kind == resource.kind &&
          existing.lifecycle == 'live' &&
          existing.baseline.digest == baseline.digest) {
        return LifecycleResult(
          command: '${_resourceLabel(resource.kind)} adopt',
          outcome: 'alreadyManaged',
          data: <String, Object?>{
            'installationId': existing.installationId,
            'location': location,
            'baselineReused': true,
          },
        );
      }
      throw MambaException(
        'The existing managed record is drifted or ambiguous; adoption cannot reset it.',
        exitCode: 4,
      );
    }
    if (context.dryRun) {
      return LifecycleResult(
        command: '${_resourceLabel(resource.kind)} adopt',
        outcome: 'planned',
        data: _planData('adopt', context, location, candidate),
      );
    }
    return _serialized(context, location, () async {
      _ensureLedger(state);
      final rechecked = await resource.inspect(location, context);
      _sameCandidate(candidate, rechecked);
      final currentBaseline = _manifest(location, resource.kind);
      if (currentBaseline.digest != baseline.digest) {
        throw MambaException(
          'The candidate changed during adoption.',
          exitCode: 4,
        );
      }
      await resource.checkUnique(
        context,
        candidate.name,
        nativeDestination: nativeDestination,
        excludePath: location,
      );
      _blockPendingAcrossScopes(context, location);
      _refuseCrossScopeOwnership(context, location);
      if (_findRecord(state, location: location) != null) {
        throw MambaException(
          'The candidate became managed during adoption.',
          exitCode: 4,
        );
      }
      final installationId = _newId('ins');
      final transactionId = _newId('trx');
      final transactionPath = p.join(
        state,
        'transactions',
        '$transactionId.json',
      );
      final record = InstallationRecord(
        installationId: installationId,
        kind: resource.kind,
        scope: context.scope,
        nativeDestination: nativeDestination,
        nativeForm: candidate.nativeForm,
        location: location,
        nativeRoot: nativeRoot,
        name: candidate.name,
        nativeProfile: candidate.validatedProfiles.length == 1
            ? candidate.validatedProfiles.single
            : null,
        validatedProfiles: candidate.validatedProfiles,
        knownConsumers: candidate.knownConsumers,
        baseline: currentBaseline,
        lifecycle: 'live',
        origin: const <String, Object?>{'status': 'unknown'},
        backupIds: const <String>[],
        transactionId: null,
      );
      _writeTransaction(transactionPath, <String, Object?>{
        'schemaVersion': 1,
        'transactionId': transactionId,
        'installationId': installationId,
        'operation': 'adopt',
        'artifactKind': resource.kind.wireName,
        'scope': context.scope.name,
        'location': location,
        'nativeRoot': nativeRoot,
        'newBaseline': currentBaseline.toJson(),
        'newRecord': record.toJson(),
        'phase': 'prepared',
      });
      var committed = false;
      try {
        _commitRecords(state, [record], const <String, Object?>{});
        committed = true;
        _writeTransaction(transactionPath, <String, Object?>{
          ..._readTransaction(transactionPath),
          'phase': 'committed',
        });
      } catch (error) {
        throw MambaException(
          committed
              ? 'Adoption committed but terminal journaling is pending; '
                    'transaction $transactionId, evidence $transactionPath. $error'
              : 'Adoption failed before committing management state; '
                    'evidence $transactionPath. $error',
          exitCode: committed ? 6 : 1,
        );
      }
      return LifecycleResult(
        command: '${_resourceLabel(resource.kind)} adopt',
        outcome: 'adopted',
        data: <String, Object?>{
          'installationId': installationId,
          'transactionId': transactionId,
          'location': location,
          'scope': context.scope.name,
          'nativeDestination': nativeDestination,
          'modification': 'unchanged',
        },
      );
    });
  }

  Future<LifecycleResult> replace({
    required LifecycleResource resource,
    required LifecycleContext context,
    required String installationId,
    required String source,
  }) async {
    final initial = recordById(context, installationId);
    _requireReplacementResource(initial, resource, context);
    _requireUnchanged(initial);
    final candidate = await resource.inspect(
      source,
      context,
      expectedName: initial.name,
    );
    if (candidate.nativeForm != initial.nativeForm &&
        initial.kind == resource.kind) {
      throw MambaException(
        'Replacement cannot change the native form without an explicit mode change.',
        exitCode: 4,
      );
    }
    if (initial.kind != resource.kind &&
        (initial.kind == ArtifactKind.agentFile ||
            resource.kind == ArtifactKind.agentFile)) {
      throw MambaException(
        'Agent replacement cannot change artifact kind.',
        exitCode: 4,
      );
    }
    await resource.checkUnique(
      context,
      candidate.name,
      nativeDestination: initial.nativeDestination,
      excludeInstallationId: installationId,
      excludePath: initial.location,
    );
    if (context.dryRun) {
      return LifecycleResult(
        command: '${_resourceLabel(resource.kind)} replace',
        outcome: 'planned',
        data: <String, Object?>{
          ..._planData('replace', context, initial.location, candidate),
          'installationId': installationId,
          'modification': 'unchanged',
          'backupExpected': true,
        },
      );
    }
    _requireApproval(context, 'replacement');
    final state = context.stateRoot();
    return _serialized(context, initial.location, () async {
      final record = recordById(context, installationId);
      if (record.baseline.digest != initial.baseline.digest) {
        throw MambaException(
          'The managed baseline changed before replacement.',
          exitCode: 4,
        );
      }
      _requireUnchanged(record);
      final rechecked = await resource.inspect(
        source,
        context,
        expectedName: record.name,
      );
      _sameCandidate(candidate, rechecked);
      final sourceDigest = _manifest(
        source,
        _contentKind(resource.kind),
      ).digest;
      await resource.checkUnique(
        context,
        record.name,
        nativeDestination: record.nativeDestination,
        excludeInstallationId: installationId,
        excludePath: record.location,
      );
      _blockPendingAcrossScopes(context, record.location);
      final transactionId = _newId('trx');
      final stage = _stagePath(
        record.nativeRoot,
        transactionId,
        resource.kind == ArtifactKind.agentFile
            ? p.basename(record.location)
            : record.name,
      );
      final transactionPath = p.join(
        state,
        'transactions',
        '$transactionId.json',
      );
      final quarantine = _quarantinePath(
        record.nativeRoot,
        transactionId,
        record.location,
      );
      var unpublished = false;
      var published = false;
      var committed = false;
      String? backupId;
      try {
        _prepareStaging(record.nativeRoot);
        final linkTarget = _copySource(
          source,
          stage,
          resource.kind,
          linkDestination: record.location,
        );
        final stagedCandidate = await resource.inspect(
          resource.kind == ArtifactKind.skillLink ? linkTarget! : stage,
          context,
          expectedName: record.name,
        );
        _sameCandidate(rechecked, stagedCandidate);
        final newBaseline = resource.kind == ArtifactKind.skillLink
            ? _linkBaselineFor(
                record.location,
                io.readLink(stage),
                io.linkKind(stage),
              )
            : _manifest(stage, resource.kind);
        if (resource.kind != ArtifactKind.skillLink &&
            newBaseline.digest != sourceDigest) {
          throw MambaException(
            'The staged replacement did not preserve source bytes and attributes.',
            exitCode: 4,
          );
        }
        if (_manifest(source, _contentKind(resource.kind)).digest !=
            sourceDigest) {
          throw MambaException(
            'The source changed during replacement.',
            exitCode: 4,
          );
        }
        _requireUnchanged(record);
        final backup = _createBackup(state, record, transactionId);
        backupId = backup.backupId;
        _writeTransaction(transactionPath, <String, Object?>{
          'schemaVersion': 1,
          'transactionId': transactionId,
          'installationId': installationId,
          'backupId': backupId,
          'operation': 'replace',
          'artifactKind': resource.kind.wireName,
          'scope': context.scope.name,
          'location': record.location,
          'nativeRoot': record.nativeRoot,
          'oldRecord': record.toJson(),
          'oldBaseline': record.baseline.toJson(),
          'newBaseline': newBaseline.toJson(),
          'stagedPath': stage,
          'quarantinePath': quarantine,
          'phase': 'prepared',
        });
        io.createDirectory(p.dirname(quarantine));
        io.rename(record.location, quarantine);
        unpublished = true;
        _advanceTransaction(transactionPath, 'quarantined');
        io.rename(stage, record.location);
        published = true;
        _advanceTransaction(transactionPath, 'published');
        _verifyBaseline(record.location, newBaseline, resource.kind);
        _verifyBaseline(quarantine, record.baseline, record.kind);
        final updated = record.copyWith(
          kind: resource.kind,
          nativeForm: candidate.nativeForm,
          baseline: newBaseline,
          backupIds: [...record.backupIds, backup.backupId],
          clearTransaction: true,
        );
        _commitRecords(state, [updated], const <String, Object?>{});
        committed = true;
        _advanceTransaction(transactionPath, 'committedCleanupPending');
        _verifyBaseline(quarantine, record.baseline, record.kind);
        _advanceTransaction(transactionPath, 'cleanupVerified');
        io.delete(quarantine);
        unpublished = false;
        _advanceTransaction(transactionPath, 'committed');
        _removeIfPresent(p.dirname(stage));
        return LifecycleResult(
          command: '${_resourceLabel(resource.kind)} replace',
          outcome: 'replaced',
          data: <String, Object?>{
            'installationId': installationId,
            'transactionId': transactionId,
            'backupId': backupId,
            'location': record.location,
            'modification': 'unchanged',
            'backupRetained': true,
          },
        );
      } catch (error) {
        if (committed) {
          throw MambaException(
            'Replacement committed but quarantine cleanup is pending; '
            'transaction $transactionId, evidence $transactionPath. $error',
            exitCode: 6,
          );
        }
        if (unpublished || published) {
          if (_rollbackReplacement(
            record.location,
            quarantine,
            published,
            transactionPath,
          )) {
            throw MambaException(
              'Replacement failed and the original installation was restored; '
              'transaction $transactionId, backup $backupId. $error',
              exitCode: 5,
            );
          }
          throw MambaException(
            'Replacement requires recovery; transaction $transactionId, '
            'backup $backupId, evidence $transactionPath. $error',
            exitCode: 6,
          );
        }
        if (error is MambaException) rethrow;
        throw MambaException(
          'Replacement failed before live publication; evidence $transactionPath. $error',
        );
      }
    });
  }

  Future<LifecycleResult> remove({
    required LifecycleResource resource,
    required LifecycleContext context,
    required String installationId,
  }) async {
    final initial = recordById(context, installationId);
    _requireResource(initial, resource, context, live: true);
    _requireUnchanged(initial);
    if (context.dryRun) {
      return LifecycleResult(
        command: '${_resourceLabel(resource.kind)} remove',
        outcome: 'planned',
        data: <String, Object?>{
          'operation': 'remove',
          'installationId': installationId,
          'location': initial.location,
          'scope': context.scope.name,
          'modification': 'unchanged',
          'backupExpected': true,
          'consumerEffect':
              (initial.kind == ArtifactKind.skillCopy ||
                      initial.kind == ArtifactKind.skillLink) &&
                  initial.nativeDestination == 'shared'
              ? 'all-consumers'
              : 'selected-native-artifact',
        },
      );
    }
    _requireApproval(context, 'removal');
    final state = context.stateRoot();
    return _serialized(context, initial.location, () async {
      final record = recordById(context, installationId);
      _requireUnchanged(record);
      _blockPendingAcrossScopes(context, record.location);
      final transactionId = _newId('trx');
      final transactionPath = p.join(
        state,
        'transactions',
        '$transactionId.json',
      );
      final quarantine = _quarantinePath(
        record.nativeRoot,
        transactionId,
        record.location,
      );
      var unpublished = false;
      var committed = false;
      String? backupId;
      try {
        final backup = _createBackup(state, record, transactionId);
        backupId = backup.backupId;
        _writeTransaction(transactionPath, <String, Object?>{
          'schemaVersion': 1,
          'transactionId': transactionId,
          'installationId': installationId,
          'backupId': backupId,
          'operation': 'remove',
          'artifactKind': resource.kind.wireName,
          'scope': context.scope.name,
          'location': record.location,
          'nativeRoot': record.nativeRoot,
          'oldRecord': record.toJson(),
          'oldBaseline': record.baseline.toJson(),
          'quarantinePath': quarantine,
          'phase': 'prepared',
        });
        io.createDirectory(p.dirname(quarantine));
        io.rename(record.location, quarantine);
        unpublished = true;
        _advanceTransaction(transactionPath, 'quarantined');
        _verifyBaseline(quarantine, record.baseline, record.kind);
        final removed = record.copyWith(
          lifecycle: 'removed',
          backupIds: [...record.backupIds, backup.backupId],
          clearTransaction: true,
        );
        _commitRecords(state, [removed], const <String, Object?>{});
        committed = true;
        _advanceTransaction(transactionPath, 'committedCleanupPending');
        _verifyBaseline(quarantine, record.baseline, record.kind);
        _advanceTransaction(transactionPath, 'cleanupVerified');
        io.delete(quarantine);
        unpublished = false;
        _advanceTransaction(transactionPath, 'committed');
        return LifecycleResult(
          command: '${_resourceLabel(resource.kind)} remove',
          outcome: 'removed',
          data: <String, Object?>{
            'installationId': installationId,
            'transactionId': transactionId,
            'backupId': backupId,
            'location': record.location,
            'modification': 'missing',
            'backupRetained': true,
            'consumerEffect':
                (record.kind == ArtifactKind.skillCopy ||
                        record.kind == ArtifactKind.skillLink) &&
                    record.nativeDestination == 'shared'
                ? 'all-consumers'
                : 'selected-native-artifact',
          },
        );
      } catch (error) {
        if (committed) {
          throw MambaException(
            'Removal committed but quarantine cleanup is pending; '
            'transaction $transactionId, evidence $transactionPath. $error',
            exitCode: 6,
          );
        }
        if (unpublished) {
          if (_rollbackRemoval(record.location, quarantine, transactionPath)) {
            throw MambaException(
              'Removal failed and the original installation was restored; '
              'transaction $transactionId, backup $backupId. $error',
              exitCode: 5,
            );
          }
          throw MambaException(
            'Removal requires recovery; transaction $transactionId, '
            'backup $backupId, evidence $transactionPath. $error',
            exitCode: 6,
          );
        }
        if (error is MambaException) rethrow;
        throw MambaException(
          'Removal failed before live mutation; evidence $transactionPath. $error',
        );
      }
    });
  }

  Future<LifecycleResult> recover({
    required LifecycleResource resource,
    required LifecycleContext context,
    String? transactionId,
    String? action,
    Set<ArtifactKind>? kinds,
  }) async {
    if (action != null && action != 'rollback' && action != 'complete') {
      throw MambaException('Unsupported recovery action: $action');
    }
    if (action != null && transactionId == null) {
      throw MambaException('--action requires a transaction ID.');
    }
    final state = context.stateRoot();
    if (transactionId == null) {
      final transactions =
          _readTransactions(state, kinds ?? <ArtifactKind>{resource.kind})
              .where((transaction) => !_recoveryTerminal(transaction['phase']))
              .toList();
      return LifecycleResult(
        command: '${_resourceLabel(resource.kind)} recover',
        outcome: 'inventoried',
        data: <String, Object?>{
          'scope': context.scope.name,
          'transactions': [
            for (final transaction in transactions)
              _transactionSummary(transaction),
          ],
        },
      );
    }
    final transaction = _transactionById(state, transactionId, resource.kind);
    final actions = _availableRecoveryActions(transaction);
    if (action == null) {
      return LifecycleResult(
        command: '${_resourceLabel(resource.kind)} recover',
        outcome: 'inspected',
        data: <String, Object?>{
          ..._transactionSummary(transaction),
          'availableActions': actions,
        },
      );
    }
    if (_recoveryTerminal(transaction['phase'])) {
      throw MambaException(
        'Transaction $transactionId is already terminal; destructive recovery cannot be replayed.',
        exitCode: 4,
      );
    }
    if (!actions.contains(action)) {
      throw MambaException(
        'Recovery action $action is not provable from phase ${transaction['phase']}.',
        exitCode: 4,
      );
    }
    _validateRecoveryAuthority(resource, context, transaction);
    if (context.dryRun) {
      return LifecycleResult(
        command: '${_resourceLabel(resource.kind)} recover',
        outcome: 'planned',
        data: <String, Object?>{
          ..._transactionSummary(transaction),
          'action': action,
          'approvalRequiredForApply': true,
        },
      );
    }
    _requireApproval(context, 'recovery');
    final location = transaction['location']! as String;
    return _serialized(context, location, () async {
      final current = _transactionById(state, transactionId, resource.kind);
      _validateRecoveryAuthority(resource, context, current);
      try {
        final established = action == 'rollback'
            ? _rollbackTransaction(state, current)
            : _completeTransaction(state, current);
        return LifecycleResult(
          command: '${_resourceLabel(resource.kind)} recover',
          outcome: 'recovered',
          data: <String, Object?>{
            ..._transactionSummary(current),
            'action': action,
            'stateEstablished': established,
            'originalOperationSucceeded': false,
          },
        );
      } on Exception catch (error) {
        throw MambaException(
          'Recovery requires further intervention; transaction $transactionId. $error',
          exitCode: 6,
        );
      }
    });
  }

  void _validateRecoveryAuthority(
    LifecycleResource resource,
    LifecycleContext context,
    Map<String, Object?> transaction,
  ) {
    final records = <InstallationRecord>[];
    for (final key in const ['oldRecord', 'newRecord']) {
      final value = transaction[key];
      if (value != null) records.add(InstallationRecord.fromJson(value));
    }
    if (records.isEmpty && transaction['operation'] == 'cleanup') {
      final backup = _backupById(
        context.stateRoot(),
        transaction['backupId']! as String,
        resource.kind,
      );
      records.add(recordById(context, backup.installationId));
    }
    if (records.isEmpty) {
      throw MambaException(
        'Transaction has no revalidatable installation authority.',
        exitCode: 4,
      );
    }
    for (final record in records) {
      if (record.scope != context.scope ||
          !p.equals(record.location, transaction['location']! as String) ||
          !p.equals(record.nativeRoot, transaction['nativeRoot']! as String)) {
        throw MambaException(
          'Transaction and installation authority do not match.',
          exitCode: 4,
        );
      }
      resource.validateAuthority(record, context);
    }
  }

  Map<String, Object?> _transactionSummary(Map<String, Object?> transaction) =>
      <String, Object?>{
        'transactionId': transaction['transactionId'],
        'operation': transaction['operation'],
        'artifactKind': transaction['artifactKind'],
        'location': transaction['location'],
        'installationId': transaction['installationId'],
        'backupId': transaction['backupId'],
        'phase': transaction['phase'],
      };

  bool _recoveryTerminal(Object? phase) =>
      const ['committed', 'rolledBack', 'failedRestored'].contains(phase);

  List<Map<String, Object?>> _readTransactions(
    String state,
    Set<ArtifactKind> kinds,
  ) {
    return runZoned(() {
      final root = p.join(state, 'transactions');
      if (io.type(root, followLinks: false) == FileSystemEntityType.notFound) {
        return <Map<String, Object?>>[];
      }
      final result = <Map<String, Object?>>[];
      for (final file in io.list(root)) {
        if (p.extension(file.path) != '.json') continue;
        final transaction = _validateTransaction(
          _readTransaction(file.path),
          state,
          p.basenameWithoutExtension(file.path),
        );
        if (kinds.any((kind) => kind.wireName == transaction['artifactKind'])) {
          result.add(transaction);
        }
      }
      result.sort(
        (left, right) =>
            '${left['transactionId']}'.compareTo('${right['transactionId']}'),
      );
      return result;
    }, zoneValues: <Object, Object?>{_metadataBudgetZone: _MetadataBudget()});
  }

  Map<String, Object?> _transactionById(
    String state,
    String id,
    ArtifactKind kind,
  ) {
    if (!RegExp(r'^trx_[a-f0-9]{32}$').hasMatch(id)) {
      throw MambaException('Invalid transaction ID.', exitCode: 4);
    }
    final path = p.join(state, 'transactions', '$id.json');
    if (io.type(path, followLinks: false) != FileSystemEntityType.file) {
      throw MambaException(
        'No transaction $id exists in the selected scope.',
        exitCode: 4,
      );
    }
    final transaction = _validateTransaction(_readTransaction(path), state, id);
    if (transaction['artifactKind'] != kind.wireName) {
      throw MambaException(
        'The transaction is not a ${_resourceLabel(kind)} artifact.',
        exitCode: 4,
      );
    }
    return transaction;
  }

  Map<String, Object?> _validateTransaction(
    Map<String, Object?> transaction,
    String state,
    String expectedId,
  ) {
    try {
      if (_integer(transaction, 'schemaVersion') != 1 ||
          _id(_string(transaction, 'transactionId'), 'trx') != expectedId) {
        throw const FormatException(
          'Transaction identity or schema is invalid.',
        );
      }
      final operation = _enumValue(_string(transaction, 'operation'), const [
        'install',
        'adopt',
        'replace',
        'remove',
        'restore',
        'cleanup',
      ]);
      _enumValue(_string(transaction, 'artifactKind'), const [
        'skill-copy',
        'skill-link',
        'agent-file',
      ]);
      _enumValue(_string(transaction, 'scope'), const ['project', 'user']);
      final location = _absolutePath(_string(transaction, 'location'));
      final nativeRoot = _absolutePath(_string(transaction, 'nativeRoot'));
      if (operation != 'cleanup' && !p.isWithin(nativeRoot, location)) {
        throw const FormatException(
          'Transaction location escapes native authority.',
        );
      }
      _enumValue(_string(transaction, 'phase'), const [
        'prepared',
        'quarantined',
        'absentVerified',
        'published',
        'committedCleanupPending',
        'cleanupVerified',
        'committed',
        'rolledBack',
        'failedRestored',
        'recoveryRequired',
        'recoveringRollback',
        'recoveringComplete',
      ]);
      final oldRecord = transaction['oldRecord'] == null
          ? null
          : InstallationRecord.fromJson(transaction['oldRecord']);
      final newRecord = transaction['newRecord'] == null
          ? null
          : InstallationRecord.fromJson(transaction['newRecord']);
      final kindName = transaction['artifactKind']! as String;
      final staged = transaction['stagedPath'];
      if (staged is String) {
        final expectedName = kindName != 'agent-file'
            ? (newRecord ?? oldRecord)?.name
            : p.basename(location);
        final expected = p.join(
          p.dirname(nativeRoot),
          '.agent-resource',
          'staging',
          expectedId,
          expectedName,
        );
        if (!p.equals(_absolutePath(staged), expected)) {
          throw const FormatException(
            'Transaction staging path does not match its identity.',
          );
        }
      }
      final quarantine = transaction['quarantinePath'];
      if (quarantine is String) {
        final expected = operation == 'cleanup'
            ? p.join(
                state,
                'backups',
                _id(_string(transaction, 'backupId'), 'bak'),
                'cleanup-quarantine',
              )
            : p.join(
                p.dirname(nativeRoot),
                '.agent-resource',
                'quarantine',
                expectedId,
                p.basename(location),
              );
        if (!p.equals(_absolutePath(quarantine), expected)) {
          throw const FormatException(
            'Transaction quarantine path does not match its identity.',
          );
        }
      }
      for (final record in [oldRecord, newRecord]) {
        if (record == null) continue;
        if (!p.equals(record.location, location) ||
            !p.equals(record.nativeRoot, nativeRoot) ||
            (record == newRecord && record.kind.wireName != kindName) ||
            (record == oldRecord &&
                kindName == 'agent-file' &&
                record.kind != ArtifactKind.agentFile) ||
            (transaction['installationId'] is String &&
                record.installationId != transaction['installationId'])) {
          throw const FormatException(
            'Transaction record and physical authority do not match.',
          );
        }
      }
      if (oldRecord != null &&
          transaction['oldBaseline'] != null &&
          jsonEncode(oldRecord.baseline.toJson()) !=
              jsonEncode(transaction['oldBaseline'])) {
        throw const FormatException(
          'Original baseline evidence does not match.',
        );
      }
      if (newRecord != null &&
          transaction['newBaseline'] != null &&
          jsonEncode(newRecord.baseline.toJson()) !=
              jsonEncode(transaction['newBaseline'])) {
        throw const FormatException('New baseline evidence does not match.');
      }
      return transaction;
    } on FormatException catch (error) {
      throw MambaException(
        'Unsafe or unsupported transaction $expectedId: ${error.message}',
        exitCode: 4,
      );
    }
  }

  List<String> _availableRecoveryActions(Map<String, Object?> transaction) {
    final phase = transaction['phase'];
    final operation = transaction['operation'];
    if (phase == 'committedCleanupPending' || phase == 'cleanupVerified') {
      return const ['complete'];
    }
    if (phase == 'prepared') {
      return operation == 'install' || operation == 'adopt'
          ? const ['rollback', 'complete']
          : const ['rollback'];
    }
    if (phase == 'quarantined') {
      return operation == 'remove' || operation == 'cleanup'
          ? const ['rollback', 'complete']
          : const ['rollback'];
    }
    if (phase == 'published' || phase == 'absentVerified') {
      return const ['rollback', 'complete'];
    }
    if (phase == 'recoveryRequired') return const <String>[];
    return const <String>[];
  }

  String _rollbackTransaction(String state, Map<String, Object?> transaction) {
    if (transaction['operation'] != 'cleanup') {
      _prepareStaging(transaction['nativeRoot']! as String);
    }
    final path = p.join(
      state,
      'transactions',
      '${transaction['transactionId']}.json',
    );
    final operation = transaction['operation']! as String;
    final location = transaction['location']! as String;
    final kind = _artifactKindFromWire(transaction['artifactKind']! as String);
    final oldValue = transaction['oldRecord'];
    final old = oldValue == null ? null : InstallationRecord.fromJson(oldValue);
    final quarantine = transaction['quarantinePath'] as String?;
    if (operation == 'install' &&
        io.type(location, followLinks: false) ==
            FileSystemEntityType.notFound) {
      final id = transaction['installationId'] as String?;
      if (id == null || _findRecord(state, installationId: id) == null) {
        _advanceTransaction(path, 'rolledBack');
        return 'rolledBack';
      }
    }
    if (old != null && operation != 'cleanup') {
      final current = _findRecord(state, installationId: old.installationId);
      final currentAuthority =
          current != null &&
          current.installationId == old.installationId &&
          p.equals(current.location, old.location) &&
          p.equals(current.nativeRoot, old.nativeRoot);
      final rollbackRecord = old.copyWith(
        backupIds: <String>{
          ...old.backupIds,
          ...?current?.backupIds,
          if (transaction['backupId'] is String)
            transaction['backupId']! as String,
          if (transaction['outgoingBackupId'] is String)
            transaction['outgoingBackupId']! as String,
        }.toList(),
      );
      if (currentAuthority && old.lifecycle == 'removed') {
        if (io.type(location, followLinks: false) ==
            FileSystemEntityType.notFound) {
          _commitRecords(state, [rollbackRecord], const <String, Object?>{});
          _advanceTransaction(path, 'rolledBack');
          return 'rolledBack';
        }
      } else if (currentAuthority &&
          old.lifecycle == 'live' &&
          (quarantine == null ||
              io.type(quarantine, followLinks: false) ==
                  FileSystemEntityType.notFound) &&
          verify(old) == ModificationStatus.unchanged) {
        _commitRecords(state, [rollbackRecord], const <String, Object?>{});
        _advanceTransaction(path, 'rolledBack');
        return 'rolledBack';
      }
    }
    if (operation == 'cleanup') {
      final backup = _backupById(
        state,
        transaction['backupId']! as String,
        kind,
      );
      if (quarantine != null &&
          io.type(quarantine, followLinks: false) !=
              FileSystemEntityType.notFound) {
        _verifyBaseline(quarantine, backup.baseline, kind);
        _requireAbsent(backup.artifactPath);
        io.rename(quarantine, backup.artifactPath);
      } else {
        _verifyBaseline(backup.artifactPath, backup.baseline, kind);
      }
      _verifyBaseline(backup.artifactPath, backup.baseline, kind);
      _writeBackup(backup.copyWith(retention: 'retained'));
      final record = _readRecords(state).firstWhere(
        (record) => record.installationId == backup.installationId,
        orElse: () => throw MambaException(
          'The backup installation record is missing.',
          exitCode: 6,
        ),
      );
      _commitRecords(state, [
        record.copyWith(
          backupIds: <String>{...record.backupIds, backup.backupId}.toList(),
        ),
      ], const <String, Object?>{});
    } else if (operation == 'install') {
      if (io.type(location, followLinks: false) !=
          FileSystemEntityType.notFound) {
        final baseline = ArtifactBaseline.fromJson(transaction['newBaseline']);
        _verifyBaseline(location, baseline, kind);
        final failedNew = _rollbackStoragePath(transaction, 'rolled-back-new');
        _requireAbsent(failedNew);
        io.createDirectory(p.dirname(failedNew));
        io.rename(location, failedNew);
      }
      final id = transaction['installationId'] as String?;
      if (id != null) _deleteRecord(state, id);
    } else if (operation == 'adopt') {
      // Adoption changed only management evidence. Its original native bytes
      // remain owned by the user and are never quarantined by rollback.
      final id = transaction['installationId'] as String?;
      if (id != null) _deleteRecord(state, id);
    } else {
      if (old == null) {
        throw const FormatException('Missing original installation record.');
      }
      if (io.type(location, followLinks: false) !=
          FileSystemEntityType.notFound) {
        _verifyBaseline(
          location,
          ArtifactBaseline.fromJson(
            transaction['newBaseline'] ?? transaction['oldBaseline'],
          ),
          kind,
        );
        final failedNew = _rollbackStoragePath(transaction, 'rolled-back-new');
        _requireAbsent(failedNew);
        io.createDirectory(p.dirname(failedNew));
        io.rename(location, failedNew);
      }
      if (old.lifecycle == 'live') {
        if (quarantine == null ||
            io.type(quarantine, followLinks: false) ==
                FileSystemEntityType.notFound) {
          throw const FormatException('Original quarantine is unavailable.');
        }
        _verifyBaseline(quarantine, old.baseline, old.kind);
        _requireAbsent(location);
        io.rename(quarantine, location);
      } else {
        _requireAbsent(location);
      }
      _commitRecords(state, [old], const <String, Object?>{});
    }
    _advanceTransaction(path, 'rolledBack');
    return 'rolledBack';
  }

  String _rollbackStoragePath(
    Map<String, Object?> transaction,
    String basename,
  ) => p.join(
    p.dirname(transaction['nativeRoot']! as String),
    '.agent-resource',
    'quarantine',
    transaction['transactionId']! as String,
    basename,
  );

  String _completeTransaction(String state, Map<String, Object?> transaction) {
    if (transaction['operation'] != 'cleanup') {
      _prepareStaging(transaction['nativeRoot']! as String);
    }
    final path = p.join(
      state,
      'transactions',
      '${transaction['transactionId']}.json',
    );
    final phase = transaction['phase']! as String;
    final operation = transaction['operation']! as String;
    final kind = _artifactKindFromWire(transaction['artifactKind']! as String);
    final location = transaction['location']! as String;
    final oldValue = transaction['oldRecord'];
    final old = oldValue == null ? null : InstallationRecord.fromJson(oldValue);
    final quarantine = transaction['quarantinePath'] as String?;
    final recordCommitted =
        phase == 'committedCleanupPending' || phase == 'cleanupVerified';

    void requireQuarantine(
      ArtifactBaseline baseline,
      ArtifactKind evidenceKind,
    ) {
      if (quarantine == null ||
          io.type(quarantine, followLinks: false) ==
              FileSystemEntityType.notFound) {
        throw MambaException(
          'Required pre-commit quarantine is missing or ambiguous.',
          exitCode: 6,
        );
      }
      _verifyBaseline(quarantine, baseline, evidenceKind);
    }

    void verifyRecord(InstallationRecord expected) {
      final actual = _findRecord(
        state,
        installationId: expected.installationId,
      );
      if (actual == null ||
          jsonEncode(actual.toJson()) != jsonEncode(expected.toJson())) {
        throw MambaException(
          'The committed installation record does not match transaction evidence.',
          exitCode: 6,
        );
      }
    }

    BackupRecord? cleanupBackup;
    if (operation == 'cleanup') {
      cleanupBackup = _backupById(
        state,
        transaction['backupId']! as String,
        kind,
      );
    }

    // Pre-commit physical evidence is validated before any management write.
    if (phase == 'quarantined' && operation == 'remove') {
      if (old == null) {
        throw const FormatException('Missing original record.');
      }
      _requireAbsent(location);
      requireQuarantine(old.baseline, old.kind);
    } else if (phase == 'quarantined' && operation == 'cleanup') {
      requireQuarantine(cleanupBackup!.baseline, cleanupBackup.kind);
      _requireAbsent(cleanupBackup.artifactPath);
    }

    if (phase == 'prepared' && operation == 'adopt') {
      verifyRecord(InstallationRecord.fromJson(transaction['newRecord']));
    } else if (phase == 'published' ||
        (phase == 'prepared' && operation == 'install') ||
        (phase == 'absentVerified' && operation == 'restore') ||
        (recordCommitted &&
            (operation == 'replace' || operation == 'restore'))) {
      final baseline = ArtifactBaseline.fromJson(transaction['newBaseline']);
      if (phase == 'absentVerified' &&
          io.type(location, followLinks: false) ==
              FileSystemEntityType.notFound) {
        final staged = transaction['stagedPath']! as String;
        _verifyBaseline(staged, baseline, kind);
        io.createDirectory(p.dirname(location));
        io.rename(staged, location);
      }
      _verifyBaseline(location, baseline, kind);
      final expected = operation == 'install'
          ? InstallationRecord.fromJson(transaction['newRecord'])
          : old!.copyWith(
              baseline: baseline,
              lifecycle: 'live',
              backupIds: <String>{
                ...old.backupIds,
                if (transaction['backupId'] is String && operation == 'replace')
                  transaction['backupId']! as String,
                if (transaction['outgoingBackupId'] is String)
                  transaction['outgoingBackupId']! as String,
              }.toList(),
            );
      if (recordCommitted) {
        verifyRecord(expected);
      } else {
        _commitRecords(state, [expected], const <String, Object?>{});
      }
    } else if (operation == 'remove' &&
        (phase == 'quarantined' || recordCommitted)) {
      if (old == null) {
        throw const FormatException('Missing original record.');
      }
      _requireAbsent(location);
      final expected = old.copyWith(
        lifecycle: 'removed',
        backupIds: <String>{
          ...old.backupIds,
          transaction['backupId']! as String,
        }.toList(),
      );
      if (recordCommitted) {
        verifyRecord(expected);
      } else {
        _commitRecords(state, [expected], const <String, Object?>{});
      }
    } else if (operation == 'cleanup' &&
        (phase == 'quarantined' || recordCommitted)) {
      final backup = cleanupBackup!;
      final record = _readRecords(
        state,
      ).firstWhere((record) => record.installationId == backup.installationId);
      if (recordCommitted) {
        if (backup.retention != 'cleaned' ||
            record.backupIds.contains(backup.backupId)) {
          throw MambaException(
            'Cleanup metadata is not in its committed state.',
            exitCode: 6,
          );
        }
      } else {
        _writeBackup(backup.copyWith(retention: 'cleaned'));
        _commitRecords(state, [
          record.copyWith(
            backupIds: record.backupIds
                .where((id) => id != backup.backupId)
                .toList(),
          ),
        ], const <String, Object?>{});
      }
    } else if (!recordCommitted) {
      throw MambaException(
        'No interrupted publication or record transition is provable from $phase.',
        exitCode: 6,
      );
    }

    if (quarantine != null &&
        io.type(quarantine, followLinks: false) !=
            FileSystemEntityType.notFound) {
      if (old != null) {
        _verifyBaseline(quarantine, old.baseline, old.kind);
      } else if (cleanupBackup != null) {
        _verifyBaseline(quarantine, cleanupBackup.baseline, cleanupBackup.kind);
      }
      io.delete(quarantine);
    } else if (operation != 'install' &&
        operation != 'adopt' &&
        !(operation == 'restore' && old?.lifecycle == 'removed') &&
        phase != 'cleanupVerified') {
      throw MambaException(
        'Required quarantine is missing before cleanup verification.',
        exitCode: 6,
      );
    }
    _advanceTransaction(path, 'committed');
    return 'committed';
  }

  void _deleteRecord(String state, String installationId) {
    final records = _readRecords(state)
        .where((record) => record.installationId != installationId)
        .toList();
    _writeManagementJson(p.join(state, 'installations.json'), <String, Object?>{
      'schemaVersion': 1,
      'installations': [for (final record in records) record.toJson()],
    });
  }

  Future<LifecycleResult> restore({
    required LifecycleResource resource,
    required LifecycleContext context,
    required String backupId,
  }) async {
    final state = context.stateRoot();
    final backup = _backupById(state, backupId, resource.kind);
    _verifyBackup(backup);
    final initial = recordById(context, backup.installationId);
    _requireResource(initial, resource, context, live: false);
    if (!p.equals(initial.location, backup.location) ||
        !p.equals(initial.nativeRoot, backup.nativeRoot) ||
        initial.baseline.digest == '') {
      throw MambaException(
        'Backup and original installation identity do not match.',
        exitCode: 4,
      );
    }
    if (initial.lifecycle == 'live') {
      _requireUnchanged(initial);
    } else {
      _requireAbsent(initial.location);
    }
    final candidate = await resource.inspect(
      backup.artifactPath,
      context,
      expectedName: initial.name,
    );
    if (candidate.nativeForm != initial.nativeForm) {
      throw MambaException(
        'The backup no longer passes its original native form.',
        exitCode: 2,
      );
    }
    await resource.checkUnique(
      context,
      candidate.name,
      nativeDestination: initial.nativeDestination,
      excludeInstallationId: initial.installationId,
      excludePath: initial.location,
    );
    if (context.dryRun) {
      return LifecycleResult(
        command: '${_resourceLabel(resource.kind)} backup restore',
        outcome: 'planned',
        data: <String, Object?>{
          ..._planData('restore', context, initial.location, candidate),
          'installationId': initial.installationId,
          'backupId': backupId,
          'backupExpected': initial.lifecycle == 'live',
          'currentLifecycle': initial.lifecycle,
        },
      );
    }
    _requireApproval(context, 'backup restore');
    return _serialized(context, initial.location, () async {
      final currentBackup = _backupById(state, backupId, resource.kind);
      _verifyBackup(currentBackup);
      final record = recordById(context, backup.installationId);
      if (record.lifecycle == 'live') {
        _requireUnchanged(record);
      } else {
        _requireAbsent(record.location);
      }
      _blockPendingAcrossScopes(context, record.location);
      final transactionId = _newId('trx');
      final transactionPath = p.join(
        state,
        'transactions',
        '$transactionId.json',
      );
      final stage = _stagePath(
        record.nativeRoot,
        transactionId,
        resource.kind == ArtifactKind.agentFile
            ? p.basename(record.location)
            : record.name,
      );
      final quarantine = _quarantinePath(
        record.nativeRoot,
        transactionId,
        record.location,
      );
      var unpublished = false;
      var published = false;
      var committed = false;
      String? outgoingBackupId;
      try {
        _prepareStaging(record.nativeRoot);
        final linkTarget = _copySource(
          currentBackup.artifactPath,
          stage,
          resource.kind,
          linkDestination: record.location,
        );
        final stagedCandidate = await resource.inspect(
          resource.kind == ArtifactKind.skillLink ? linkTarget! : stage,
          context,
          expectedName: record.name,
        );
        _sameCandidate(candidate, stagedCandidate);
        final newBaseline = resource.kind == ArtifactKind.skillLink
            ? _linkBaselineFor(
                record.location,
                io.readLink(stage),
                io.linkKind(stage),
              )
            : _manifest(stage, resource.kind);
        if (newBaseline.digest != currentBackup.baseline.digest ||
            _manifest(currentBackup.artifactPath, resource.kind).digest !=
                currentBackup.baseline.digest) {
          throw MambaException(
            'Backup bytes changed during restore staging.',
            exitCode: 4,
          );
        }
        BackupRecord? outgoing;
        if (record.lifecycle == 'live') {
          outgoing = _createBackup(state, record, transactionId);
          outgoingBackupId = outgoing.backupId;
        }
        _writeTransaction(transactionPath, <String, Object?>{
          'schemaVersion': 1,
          'transactionId': transactionId,
          'installationId': record.installationId,
          'backupId': backupId,
          'outgoingBackupId': outgoingBackupId,
          'operation': 'restore',
          'artifactKind': resource.kind.wireName,
          'scope': context.scope.name,
          'location': record.location,
          'nativeRoot': record.nativeRoot,
          'oldRecord': record.toJson(),
          'oldBaseline': record.baseline.toJson(),
          'newBaseline': newBaseline.toJson(),
          'stagedPath': stage,
          'quarantinePath': quarantine,
          'phase': 'prepared',
        });
        if (record.lifecycle == 'live') {
          io.createDirectory(p.dirname(quarantine));
          io.rename(record.location, quarantine);
          unpublished = true;
        } else {
          _requireAbsent(record.location);
        }
        _advanceTransaction(
          transactionPath,
          unpublished ? 'quarantined' : 'absentVerified',
        );
        io.createDirectory(record.nativeRoot);
        io.rename(stage, record.location);
        published = true;
        _advanceTransaction(transactionPath, 'published');
        _verifyBaseline(record.location, newBaseline, resource.kind);
        if (unpublished) {
          _verifyBaseline(quarantine, record.baseline, record.kind);
        }
        final restored = record.copyWith(
          kind: resource.kind,
          nativeForm: candidate.nativeForm,
          baseline: newBaseline,
          lifecycle: 'live',
          backupIds: [
            ...record.backupIds,
            if (outgoing != null) outgoing.backupId,
          ],
          clearTransaction: true,
        );
        _commitRecords(state, [restored], const <String, Object?>{});
        committed = true;
        _advanceTransaction(transactionPath, 'committedCleanupPending');
        if (unpublished) {
          _verifyBaseline(quarantine, record.baseline, record.kind);
          _advanceTransaction(transactionPath, 'cleanupVerified');
          io.delete(quarantine);
          unpublished = false;
        }
        _advanceTransaction(transactionPath, 'committed');
        _removeIfPresent(p.dirname(stage));
        return LifecycleResult(
          command: '${_resourceLabel(resource.kind)} backup restore',
          outcome: 'restored',
          data: <String, Object?>{
            'installationId': record.installationId,
            'transactionId': transactionId,
            'backupId': backupId,
            'outgoingBackupId': outgoingBackupId,
            'location': record.location,
            'modification': 'unchanged',
            'backupRetained': true,
          },
        );
      } catch (error) {
        if (committed) {
          throw MambaException(
            'Restore committed but cleanup is pending; transaction $transactionId, '
            'evidence $transactionPath. $error',
            exitCode: 6,
          );
        }
        if (unpublished || published) {
          final safe = _rollbackRestore(
            record.location,
            quarantine,
            hadOriginal: record.lifecycle == 'live',
            published: published,
            transactionPath: transactionPath,
          );
          if (safe) {
            throw MambaException(
              'Restore failed and the prior lifecycle state was restored; '
              'transaction $transactionId. $error',
              exitCode: 5,
            );
          }
          throw MambaException(
            'Restore requires recovery; transaction $transactionId, '
            'evidence $transactionPath. $error',
            exitCode: 6,
          );
        }
        if (error is MambaException) rethrow;
        throw MambaException(
          'Restore failed before publication; evidence $transactionPath. $error',
        );
      }
    });
  }

  Future<LifecycleResult> backupList(
    LifecycleContext context,
    ArtifactKind kind, {
    ArtifactKind? otherKind,
  }) async {
    final backups = _readBackups(context.stateRoot(), <ArtifactKind>{
      kind,
      ?otherKind,
    }).where((backup) => backup.retention == 'retained').toList();
    return LifecycleResult(
      command: '${_resourceLabel(kind)} backup list',
      outcome: 'inventoried',
      data: <String, Object?>{
        'scope': context.scope.name,
        'backups': [
          for (final backup in backups)
            <String, Object?>{
              'backupId': backup.backupId,
              'installationId': backup.installationId,
              'transactionId': backup.transactionId,
              'location': backup.location,
              'integrity': _backupIntegrity(backup),
              'retention': backup.retention,
            },
        ],
      },
    );
  }

  Future<LifecycleResult> cleanup({
    required LifecycleResource resource,
    required LifecycleContext context,
    required String backupId,
  }) async {
    final backup = _backupById(context.stateRoot(), backupId, resource.kind);
    final installation = recordById(context, backup.installationId);
    if (backup.retention != 'retained' ||
        !installation.backupIds.contains(backupId) ||
        !p.equals(installation.location, backup.location)) {
      throw MambaException(
        'Backup retention or installation evidence does not match.',
        exitCode: 4,
      );
    }
    _verifyBackup(backup);
    if (context.dryRun) {
      return LifecycleResult(
        command: '${_resourceLabel(resource.kind)} backup cleanup',
        outcome: 'planned',
        data: <String, Object?>{
          'operation': 'cleanup',
          'backupId': backupId,
          'installationId': backup.installationId,
          'integrity': 'unchanged',
          'secureErasure': false,
        },
      );
    }
    _requireApproval(context, 'backup cleanup');
    final state = context.stateRoot();
    return _serialized(context, backup.location, () async {
      final current = _backupById(state, backupId, resource.kind);
      _verifyBackup(current);
      _blockPendingAcrossScopes(context, current.location);
      final transactionId = _newId('trx');
      final path = p.join(state, 'transactions', '$transactionId.json');
      final quarantine = p.join(
        state,
        'backups',
        backupId,
        'cleanup-quarantine',
      );
      _writeTransaction(path, <String, Object?>{
        'schemaVersion': 1,
        'transactionId': transactionId,
        'installationId': current.installationId,
        'backupId': backupId,
        'operation': 'cleanup',
        'artifactKind': resource.kind.wireName,
        'scope': context.scope.name,
        'location': current.location,
        'nativeRoot': current.nativeRoot,
        'backupPath': current.artifactPath,
        'quarantinePath': quarantine,
        'phase': 'prepared',
      });
      var quarantined = false;
      var committed = false;
      try {
        io.rename(current.artifactPath, quarantine);
        quarantined = true;
        _advanceTransaction(path, 'quarantined');
        _verifyBaseline(quarantine, current.baseline, resource.kind);
        _writeBackup(current.copyWith(retention: 'cleaned'));
        final record = recordById(context, current.installationId);
        _commitRecords(state, [
          record.copyWith(
            backupIds: record.backupIds.where((id) => id != backupId).toList(),
          ),
        ], const <String, Object?>{});
        committed = true;
        _advanceTransaction(path, 'committedCleanupPending');
        _verifyBaseline(quarantine, current.baseline, resource.kind);
        _advanceTransaction(path, 'cleanupVerified');
        io.delete(quarantine);
        quarantined = false;
        _advanceTransaction(path, 'committed');
      } catch (error) {
        if (committed) {
          throw MambaException(
            'Backup cleanup committed but physical cleanup is pending; '
            'transaction $transactionId, evidence $path. $error',
            exitCode: 6,
          );
        }
        if (quarantined) {
          try {
            _verifyBaseline(quarantine, current.baseline, resource.kind);
            _requireAbsent(current.artifactPath);
            io.rename(quarantine, current.artifactPath);
            _verifyBaseline(
              current.artifactPath,
              current.baseline,
              resource.kind,
            );
            _writeBackup(current.copyWith(retention: 'retained'));
            _advanceTransaction(path, 'failedRestored');
          } on Exception catch (rollbackError) {
            throw MambaException(
              'Backup cleanup requires recovery; transaction $transactionId, '
              'evidence $path. $rollbackError',
              exitCode: 6,
            );
          }
          throw MambaException(
            'Backup cleanup failed and the retained artifact was restored; '
            'transaction $transactionId. $error',
            exitCode: 5,
          );
        }
        if (error is MambaException) rethrow;
        throw MambaException(
          'Backup cleanup failed before mutation; evidence $path. $error',
        );
      }
      return LifecycleResult(
        command: '${_resourceLabel(resource.kind)} backup cleanup',
        outcome: 'cleaned',
        data: <String, Object?>{
          'backupId': backupId,
          'transactionId': transactionId,
          'retention': 'cleaned',
          'secureErasure': false,
        },
      );
    });
  }

  ArtifactBaseline readLinkBaseline(String path) => _linkBaseline(path);

  void validateSkillTree(String path) {
    _manifest(path, ArtifactKind.skillCopy);
  }

  List<InstallationRecord> records(LifecycleContext context) =>
      _readRecords(context.stateRoot());

  ArtifactKind artifactKindForBackup(
    LifecycleContext context,
    String id,
    Set<ArtifactKind> kinds,
  ) {
    final matches = _readBackups(
      context.stateRoot(),
      kinds,
    ).where((backup) => backup.backupId == id);
    if (matches.length != 1) {
      throw MambaException(
        'No unambiguous retained backup $id exists in the selected scope.',
        exitCode: 4,
      );
    }
    return matches.single.kind;
  }

  ArtifactKind artifactKindForTransaction(
    LifecycleContext context,
    String id,
    Set<ArtifactKind> kinds,
  ) {
    final matches = _readTransactions(
      context.stateRoot(),
      kinds,
    ).where((transaction) => transaction['transactionId'] == id);
    if (matches.length != 1) {
      throw MambaException(
        'No unambiguous transaction $id exists in the selected scope.',
        exitCode: 4,
      );
    }
    return _artifactKindFromWire(matches.single['artifactKind']! as String);
  }

  InstallationRecord installationForBackup(
    LifecycleContext context,
    String id,
    ArtifactKind kind,
  ) {
    final backup = _backupById(context.stateRoot(), id, kind);
    return recordById(context, backup.installationId);
  }

  InstallationRecord recordById(LifecycleContext context, String id) {
    final record = _findRecord(context.stateRoot(), installationId: id);
    if (record == null) {
      throw MambaException(
        'No managed installation $id exists in the selected ${context.scope.name} scope.',
        exitCode: 4,
      );
    }
    return record;
  }

  ModificationStatus verify(InstallationRecord record) {
    try {
      final type = io.type(record.location, followLinks: false);
      if (type == FileSystemEntityType.notFound) {
        return ModificationStatus.missing;
      }
      final actual = _manifest(record.location, record.kind);
      return actual.digest == record.baseline.digest
          ? ModificationStatus.unchanged
          : ModificationStatus.changed;
    } on Exception {
      return ModificationStatus.unableToVerify;
    }
  }

  void _requireReplacementResource(
    InstallationRecord record,
    LifecycleResource resource,
    LifecycleContext context,
  ) {
    final skillConversion =
        (record.kind == ArtifactKind.skillCopy ||
            record.kind == ArtifactKind.skillLink) &&
        (resource.kind == ArtifactKind.skillCopy ||
            resource.kind == ArtifactKind.skillLink);
    if ((record.kind != resource.kind && !skillConversion) ||
        record.lifecycle != 'live') {
      throw MambaException(
        'The stored installation is not eligible for replacement.',
        exitCode: 4,
      );
    }
    _requireSafePath(
      record.location,
      record.nativeRoot,
      allowFinalLink: record.kind == ArtifactKind.skillLink,
    );
    resource.validateAuthority(record, context);
  }

  void _requireResource(
    InstallationRecord record,
    LifecycleResource resource,
    LifecycleContext context, {
    required bool live,
  }) {
    if (record.kind != resource.kind || (live && record.lifecycle != 'live')) {
      throw MambaException(
        'The stored installation is not a live ${_resourceLabel(resource.kind)} artifact.',
        exitCode: 4,
      );
    }
    _requireSafePath(
      record.location,
      record.nativeRoot,
      allowFinalLink: record.kind == ArtifactKind.skillLink,
    );
    resource.validateAuthority(record, context);
  }

  void _requireUnchanged(InstallationRecord record) {
    switch (verify(record)) {
      case ModificationStatus.unchanged:
        return;
      case ModificationStatus.changed:
        throw MambaException(
          'The managed installation changed; implicit rebaseline is forbidden: ${record.location}',
          exitCode: 4,
        );
      case ModificationStatus.missing:
        throw MambaException(
          'The managed installation is missing: ${record.location}',
          exitCode: 4,
        );
      case ModificationStatus.unableToVerify:
      case ModificationStatus.notVerified:
        throw MambaException(
          'The managed installation baseline could not be verified: ${record.location}',
          exitCode: 4,
        );
    }
  }

  BackupRecord _createBackup(
    String state,
    InstallationRecord record,
    String transactionId,
  ) {
    final backupId = _newId('bak');
    final directory = p.join(state, 'backups', backupId);
    final artifact = p.join(directory, switch (record.kind) {
      ArtifactKind.skillCopy => 'artifact',
      ArtifactKind.skillLink => 'artifact-link.json',
      ArtifactKind.agentFile => 'artifact${p.extension(record.location)}',
    });
    _makePrivate(directory);
    if (record.kind == ArtifactKind.skillLink) {
      _writeManagementJson(artifact, record.baseline.toJson());
    } else {
      _copySource(record.location, artifact, record.kind);
    }
    final actual = _manifest(artifact, record.kind);
    if (actual.digest != record.baseline.digest) {
      throw MambaException(
        'The independent backup did not match the owned baseline.',
        exitCode: 4,
      );
    }
    final backup = BackupRecord(
      backupId: backupId,
      installationId: record.installationId,
      transactionId: transactionId,
      kind: record.kind,
      scope: record.scope,
      location: record.location,
      nativeRoot: record.nativeRoot,
      baseline: record.baseline,
      artifactPath: artifact,
      retention: 'retained',
    );
    _writeBackup(backup);
    return backup;
  }

  void _writeBackup(BackupRecord backup) {
    final state = p.dirname(p.dirname(p.dirname(backup.artifactPath)));
    _writeManagementJson(
      p.join(state, 'backups', backup.backupId, 'backup.json'),
      backup.toJson(),
    );
  }

  List<BackupRecord> _readBackups(String state, Set<ArtifactKind> kinds) {
    return runZoned(() {
      final root = p.join(state, 'backups');
      if (io.type(root, followLinks: false) == FileSystemEntityType.notFound) {
        return <BackupRecord>[];
      }
      if (io.type(root, followLinks: false) != FileSystemEntityType.directory) {
        throw MambaException(
          'Backup storage is not a directory: $root',
          exitCode: 4,
        );
      }
      final result = <BackupRecord>[];
      for (final directory in io.list(root)) {
        if (io.type(directory.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          throw MambaException(
            'Unexpected entry in backup storage: ${directory.path}',
            exitCode: 4,
          );
        }
        final metadata = p.join(directory.path, 'backup.json');
        if (io.type(metadata, followLinks: false) ==
            FileSystemEntityType.notFound) {
          throw MambaException(
            'Backup metadata is missing: $metadata',
            exitCode: 4,
          );
        }
        final backup = _decodeBackup(metadata, state);
        if (kinds.contains(backup.kind)) result.add(backup);
      }
      result.sort((left, right) => left.backupId.compareTo(right.backupId));
      return result;
    }, zoneValues: <Object, Object?>{_metadataBudgetZone: _MetadataBudget()});
  }

  BackupRecord _backupById(String state, String id, ArtifactKind kind) {
    final metadata = p.join(state, 'backups', id, 'backup.json');
    if (!RegExp(r'^bak_[a-f0-9]{32}$').hasMatch(id) ||
        io.type(metadata, followLinks: false) ==
            FileSystemEntityType.notFound) {
      throw MambaException(
        'No retained backup $id exists in the selected scope.',
        exitCode: 4,
      );
    }
    final backup = _decodeBackup(metadata, state);
    if (backup.backupId != id || backup.kind != kind) {
      throw MambaException(
        'Backup identity or artifact kind does not match.',
        exitCode: 4,
      );
    }
    return backup;
  }

  BackupRecord _decodeBackup(String metadata, String state) {
    try {
      return BackupRecord.fromJson(_readManagementJson(metadata), state);
    } on FormatException catch (error) {
      throw MambaException(
        'Invalid backup record $metadata: ${error.message}',
        exitCode: 4,
      );
    }
  }

  String _backupIntegrity(BackupRecord backup) {
    try {
      _verifyBackup(backup);
      return 'unchanged';
    } on Exception {
      return 'unableToVerify';
    }
  }

  void _verifyBackup(BackupRecord backup) {
    if (backup.retention != 'retained') {
      throw MambaException('The backup is not retained.', exitCode: 4);
    }
    if (_manifest(backup.artifactPath, backup.kind).digest !=
        backup.baseline.digest) {
      throw MambaException(
        'The retained backup is changed or ambiguous.',
        exitCode: 4,
      );
    }
  }

  void _advanceTransaction(String path, String phase) {
    _writeTransaction(path, <String, Object?>{
      ..._readTransaction(path),
      'phase': phase,
    });
  }

  String _quarantinePath(
    String nativeRoot,
    String transactionId,
    String location,
  ) => p.join(
    p.dirname(nativeRoot),
    '.agent-resource',
    'quarantine',
    transactionId,
    p.basename(location),
  );

  bool _rollbackReplacement(
    String location,
    String quarantine,
    bool published,
    String transactionPath,
  ) {
    try {
      final transaction = _readTransaction(transactionPath);
      final kind = _artifactKindFromWire(
        transaction['artifactKind']! as String,
      );
      final oldRecord = transaction['oldRecord'] == null
          ? null
          : InstallationRecord.fromJson(transaction['oldRecord']);
      final oldKind = oldRecord?.kind ?? kind;
      if (io.type(location, followLinks: false) !=
          FileSystemEntityType.notFound) {
        if (!published) return false;
        _verifyBaseline(
          location,
          ArtifactBaseline.fromJson(transaction['newBaseline']),
          kind,
        );
        final failedNew = '$quarantine.failed-new';
        _requireAbsent(failedNew);
        io.rename(location, failedNew);
      }
      if (io.type(location, followLinks: false) ==
              FileSystemEntityType.notFound &&
          io.type(quarantine, followLinks: false) !=
              FileSystemEntityType.notFound) {
        _verifyBaseline(
          quarantine,
          ArtifactBaseline.fromJson(transaction['oldBaseline']),
          oldKind,
        );
        io.rename(quarantine, location);
      }
      if (io.type(location, followLinks: false) ==
          FileSystemEntityType.notFound) {
        return false;
      }
      _verifyBaseline(
        location,
        ArtifactBaseline.fromJson(transaction['oldBaseline']),
        oldKind,
      );
      _advanceTransaction(transactionPath, 'failedRestored');
      return true;
    } on Exception {
      return false;
    }
  }

  bool _rollbackRestore(
    String location,
    String quarantine, {
    required bool hadOriginal,
    required bool published,
    required String transactionPath,
  }) {
    try {
      final transaction = _readTransaction(transactionPath);
      final kind = _artifactKindFromWire(
        transaction['artifactKind']! as String,
      );
      final oldRecord = transaction['oldRecord'] == null
          ? null
          : InstallationRecord.fromJson(transaction['oldRecord']);
      final oldKind = oldRecord?.kind ?? kind;
      if (io.type(location, followLinks: false) !=
          FileSystemEntityType.notFound) {
        if (!published) return false;
        _verifyBaseline(
          location,
          ArtifactBaseline.fromJson(transaction['newBaseline']),
          kind,
        );
        final failedNew = '$quarantine.failed-new';
        _requireAbsent(failedNew);
        io.rename(location, failedNew);
      }
      if (hadOriginal) {
        if (io.type(location, followLinks: false) !=
            FileSystemEntityType.notFound) {
          return false;
        }
        _verifyBaseline(
          quarantine,
          ArtifactBaseline.fromJson(transaction['oldBaseline']),
          oldKind,
        );
        io.rename(quarantine, location);
        _verifyBaseline(
          location,
          ArtifactBaseline.fromJson(transaction['oldBaseline']),
          oldKind,
        );
      } else if (io.type(location, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return false;
      }
      _advanceTransaction(transactionPath, 'failedRestored');
      return true;
    } on Exception {
      return false;
    }
  }

  bool _rollbackRemoval(
    String location,
    String quarantine,
    String transactionPath,
  ) {
    try {
      if (io.type(location, followLinks: false) !=
          FileSystemEntityType.notFound) {
        return false;
      }
      final transaction = _readTransaction(transactionPath);
      final kind = _artifactKindFromWire(
        transaction['artifactKind']! as String,
      );
      final baseline = ArtifactBaseline.fromJson(transaction['oldBaseline']);
      _verifyBaseline(quarantine, baseline, kind);
      io.rename(quarantine, location);
      _verifyBaseline(location, baseline, kind);
      _advanceTransaction(transactionPath, 'failedRestored');
      return true;
    } on Exception {
      return false;
    }
  }

  void _blockPendingAcrossScopes(LifecycleContext context, String location) {
    for (final state in _coordinationStates(context)) {
      _blockPending(state, location);
    }
  }

  List<String> _coordinationStates(LifecycleContext context) {
    final states = <String>{};
    for (final scope in const [LifecycleScope.project, LifecycleScope.user]) {
      try {
        states.add(context.stateRoot(scope));
      } on MambaException {
        if (scope == context.scope) rethrow;
        // An unrelated scope with no resolvable state context must not block
        // an independent operation. When configured, it shares both locks.
      }
    }
    return states.toList();
  }

  void _blockPending(String state, String location) {
    final root = p.join(state, 'transactions');
    if (io.type(root, followLinks: false) == FileSystemEntityType.notFound) {
      return;
    }
    for (final file in io.list(root)) {
      if (p.extension(file.path) != '.json') continue;
      final transaction = _readTransaction(file.path);
      final phase = transaction['phase'];
      const terminal = ['committed', 'rolledBack', 'failedRestored'];
      if (terminal.contains(phase)) continue;
      if (transaction['location'] is String &&
          p.equals(transaction['location']! as String, location)) {
        throw MambaException(
          'A pending transaction blocks this installation: ${transaction['transactionId']}',
          exitCode: 6,
        );
      }
    }
  }

  Future<_InstallPreparation> _prepareInstall(
    LifecycleResource resource,
    LifecycleContext context,
    String source,
    String location,
    String nativeRoot,
    String nativeDestination,
  ) async {
    _requireSafePath(
      location,
      nativeRoot,
      allowFinalLink: resource.kind == ArtifactKind.skillLink,
    );
    _requireSourceDistinct(source, location, nativeRoot, context.stateRoot());
    final candidate = await resource.inspect(source, context);
    if ((resource.kind == ArtifactKind.skillCopy ||
            resource.kind == ArtifactKind.skillLink) &&
        p.basename(location) != candidate.name) {
      throw MambaException(
        'The Skill destination name must match the declared name.',
        exitCode: 2,
      );
    }
    final sourceDigest = _manifest(source, _contentKind(resource.kind)).digest;
    _requireAbsent(location);
    await resource.checkUnique(
      context,
      candidate.name,
      nativeDestination: nativeDestination,
    );
    return _InstallPreparation(candidate, sourceDigest);
  }

  ArtifactBaseline _linkBaseline(String path) {
    final type = io.type(path, followLinks: false);
    if (type == FileSystemEntityType.file &&
        p.basename(path) == 'artifact-link.json') {
      final baseline = ArtifactBaseline.fromJson(_readManagementJson(path));
      if (baseline.entries.length != 1 ||
          baseline.entries.single.type != 'link') {
        throw MambaException(
          'Invalid entry-only link backup evidence.',
          exitCode: 4,
        );
      }
      return baseline;
    }
    if (type != FileSystemEntityType.link) {
      throw MambaException(
        'A linked Skill baseline requires a supported top-level directory link.',
        exitCode: 4,
      );
    }
    final target = io.readLink(path);
    final nativeKind = io.linkKind(path);
    return ArtifactBaseline([
      BaselineEntry(
        path: '.',
        type: 'link',
        length: 0,
        sha256: null,
        executable: false,
        readOnly: false,
        target: target,
        nativeKind: nativeKind,
        originalParent: p.normalize(p.dirname(path)),
      ),
    ]);
  }

  String? _copySource(
    String source,
    String stage,
    ArtifactKind kind, {
    String? linkDestination,
  }) {
    _requireAbsent(stage);
    if (kind == ArtifactKind.skillLink) {
      io.createDirectory(p.dirname(stage));
      final sourceType = io.type(source, followLinks: false);
      final String target;
      final String? originalParent;
      if (sourceType == FileSystemEntityType.link) {
        target = io.readLink(source);
        originalParent = p.normalize(p.dirname(source));
      } else if (sourceType == FileSystemEntityType.file &&
          p.basename(source) == 'artifact-link.json') {
        final entry = _linkBaseline(source).entries.single;
        target = entry.target!;
        originalParent = entry.originalParent;
      } else if (sourceType == FileSystemEntityType.directory) {
        target = source;
        originalParent = null;
      } else {
        throw MambaException(
          'A linked Skill source must be an ordinary directory or verified entry backup.',
          exitCode: 4,
        );
      }
      final absolute = p.isAbsolute(target) || originalParent == null
          ? p.normalize(target)
          : p.normalize(p.join(originalParent, target));
      final destination = linkDestination ?? source;
      final stagedTarget = p.isAbsolute(target)
          ? absolute
          : p.normalize(p.relative(absolute, from: p.dirname(destination)));
      io.createLink(stage, stagedTarget);
      return absolute;
    }
    if (kind == ArtifactKind.agentFile) {
      io.createDirectory(p.dirname(stage));
      io.copyFile(source, stage);
      return null;
    }
    _copyTree(source, stage);
    return null;
  }

  ArtifactBaseline _linkBaselineFor(
    String location,
    String target,
    String nativeKind,
  ) => ArtifactBaseline([
    BaselineEntry(
      path: '.',
      type: 'link',
      length: 0,
      sha256: null,
      executable: false,
      readOnly: false,
      target: target,
      nativeKind: nativeKind,
      originalParent: p.normalize(p.dirname(location)),
    ),
  ]);

  void _copyTree(String source, String destination) {
    io.createDirectory(destination);
    var entries = 0;
    var bytes = 0;
    void copy(String from, String to, int depth) {
      if (depth > maxSkillDepth) {
        throw MambaException(
          'The Skill tree exceeds the depth-32 budget.',
          exitCode: 3,
        );
      }
      for (final entity in io.list(from)) {
        entries++;
        if (entries > maxSkillEntries) {
          throw MambaException(
            'The Skill tree exceeds the 10,000-entry budget.',
            exitCode: 3,
          );
        }
        final target = p.join(to, p.basename(entity.path));
        final type = io.type(entity.path, followLinks: false);
        switch (type) {
          case FileSystemEntityType.directory:
            io.createDirectory(target);
            copy(entity.path, target, depth + 1);
          case FileSystemEntityType.file:
            final length = File(entity.path).lengthSync();
            if (length > maxSkillFileBytes) {
              throw MambaException(
                'A Skill file exceeds the 64 MiB budget.',
                exitCode: 3,
              );
            }
            bytes += length;
            if (bytes > maxSkillAggregateBytes) {
              throw MambaException(
                'The Skill tree exceeds the 256 MiB aggregate budget.',
                exitCode: 3,
              );
            }
            io.copyFile(entity.path, target);
          default:
            throw MambaException(
              'Linked and unsupported Skill entries cannot be copied: ${entity.path}',
              exitCode: 4,
            );
        }
      }
    }

    copy(source, destination, 0);
  }

  ArtifactBaseline _manifest(String path, ArtifactKind kind) {
    if (kind == ArtifactKind.skillLink) return _linkBaseline(path);
    final entries = <BaselineEntry>[];
    var aggregate = 0;
    var count = 0;
    void visit(String current, String relative, int depth) {
      if (depth > maxSkillDepth) {
        throw MambaException(
          'The resource exceeds the depth-32 budget.',
          exitCode: 3,
        );
      }
      final type = io.type(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw MambaException(
          'Linked resource entries are unsupported: $current',
          exitCode: 4,
        );
      }
      final stat = FileStat.statSync(current);
      final executable = !Platform.isWindows && stat.mode & 0x49 != 0;
      final readOnly = Platform.isWindows && stat.mode & 0x92 == 0;
      if (type == FileSystemEntityType.file) {
        final bytes = io.read(current, maxSkillFileBytes);
        if (bytes.length > maxSkillFileBytes) {
          throw MambaException(
            'A resource file exceeds the 64 MiB budget.',
            exitCode: 3,
          );
        }
        aggregate += bytes.length;
        if (aggregate > maxSkillAggregateBytes) {
          throw MambaException(
            'The resource exceeds the 256 MiB aggregate budget.',
            exitCode: 3,
          );
        }
        entries.add(
          BaselineEntry(
            path: relative,
            type: 'file',
            length: bytes.length,
            sha256: sha256.convert(bytes).toString(),
            executable: executable,
            readOnly: readOnly,
          ),
        );
        return;
      }
      if (type != FileSystemEntityType.directory) {
        throw MambaException(
          'Unsupported resource entry type: $current',
          exitCode: 4,
        );
      }
      if (kind == ArtifactKind.agentFile) {
        throw MambaException(
          'An Agent installation must be a regular file.',
          exitCode: 4,
        );
      }
      if (relative != '.') {
        entries.add(
          BaselineEntry(
            path: relative,
            type: 'directory',
            length: 0,
            sha256: null,
            executable: executable,
            readOnly: readOnly,
          ),
        );
      }
      final children = io.list(current)
        ..sort((left, right) => left.path.compareTo(right.path));
      for (final child in children) {
        count++;
        if (count > maxSkillEntries) {
          throw MambaException(
            'The Skill tree exceeds the 10,000-entry budget.',
            exitCode: 3,
          );
        }
        final childRelative = relative == '.'
            ? p.basename(child.path)
            : p.join(relative, p.basename(child.path));
        visit(child.path, childRelative, depth + 1);
      }
    }

    visit(path, '.', 0);
    if (kind == ArtifactKind.agentFile && entries.length != 1) {
      throw MambaException(
        'An Agent baseline requires exactly one file.',
        exitCode: 4,
      );
    }
    return ArtifactBaseline(List.unmodifiable(entries));
  }

  void _verifyBaseline(
    String path,
    ArtifactBaseline expected,
    ArtifactKind kind,
  ) {
    final actual = _manifest(path, kind);
    if (kind == ArtifactKind.skillLink) {
      final left = actual.entries.single;
      final right = expected.entries.single;
      if (left.type == 'link' &&
          right.type == 'link' &&
          left.target == right.target &&
          left.nativeKind == right.nativeKind) {
        return;
      }
    }
    if (actual.digest != expected.digest) {
      throw MambaException(
        'The published resource did not match its staged baseline.',
        exitCode: 6,
      );
    }
  }

  bool _restoreFailedInstall(
    String location,
    String stage,
    String transactionPath,
  ) {
    try {
      final transaction = _readTransaction(transactionPath);
      final kind = _artifactKindFromWire(
        transaction['artifactKind']! as String,
      );
      if (io.type(location, followLinks: false) !=
          FileSystemEntityType.notFound) {
        _verifyBaseline(
          location,
          ArtifactBaseline.fromJson(transaction['newBaseline']),
          kind,
        );
        final quarantine = transaction['quarantinePath'] as String?;
        if (quarantine == null) return false;
        _requireAbsent(quarantine);
        io.createDirectory(p.dirname(quarantine));
        io.rename(location, quarantine);
      }
      _writeTransaction(transactionPath, <String, Object?>{
        ...transaction,
        'phase': 'failedRestored',
      });
      return io.type(location, followLinks: false) ==
          FileSystemEntityType.notFound;
    } on Exception {
      return false;
    }
  }

  void _ensureLedger(String state) {
    final path = p.join(state, 'installations.json');
    if (io.type(path, followLinks: false) != FileSystemEntityType.notFound) {
      _readRecords(state);
      return;
    }
    if (io.type(state, followLinks: false) != FileSystemEntityType.notFound) {
      final unexpected = io
          .list(state)
          .where((entry) => p.basename(entry.path) != 'coordination');
      if (unexpected.isNotEmpty) {
        throw MambaException(
          'Installation ownership evidence is missing from non-empty state: $path',
          exitCode: 4,
        );
      }
    }
    _writeManagementJson(path, <String, Object?>{
      'schemaVersion': 1,
      'installations': const <Object?>[],
    });
  }

  List<InstallationRecord> _readRecords(String state) {
    final path = p.join(state, 'installations.json');
    if (io.type(path, followLinks: false) == FileSystemEntityType.notFound) {
      if (io.type(state, followLinks: false) == FileSystemEntityType.notFound) {
        return <InstallationRecord>[];
      }
      throw MambaException(
        'Installation ownership evidence is missing: $path',
        exitCode: 4,
      );
    }
    final Object? document;
    final Map<String, Object?> map;
    try {
      document = _readManagementJson(path);
      map = _object(document, 'installation ledger');
    } on FormatException catch (error) {
      throw MambaException(
        'Invalid installation ledger $path: ${error.message}',
        exitCode: 4,
      );
    }
    if (map['schemaVersion'] != managementSchemaVersion) {
      throw MambaException(
        'Unsupported installation ledger schema: $path',
        exitCode: 4,
      );
    }
    final List<InstallationRecord> records;
    try {
      records = [
        for (final value in _list(map['installations'], 'installations'))
          InstallationRecord.fromJson(value),
      ];
    } on FormatException catch (error) {
      throw MambaException(
        'Invalid installation record in $path: ${error.message}',
        exitCode: 4,
      );
    }
    final ids = <String>{};
    final locations = <String>{};
    for (final record in records) {
      if (!ids.add(record.installationId)) {
        throw MambaException(
          'Duplicate installation identity in $path.',
          exitCode: 4,
        );
      }
      if (record.lifecycle == 'live' &&
          !locations.add(_pathKey(record.location))) {
        throw MambaException(
          'Overlapping installation authority in $path.',
          exitCode: 4,
        );
      }
    }
    return records;
  }

  void _refuseCrossScopeOwnership(LifecycleContext context, String location) {
    for (final scope in const [LifecycleScope.project, LifecycleScope.user]) {
      if (scope == context.scope) continue;
      final String otherState;
      try {
        otherState = context.stateRoot(scope);
      } on MambaException {
        continue;
      }
      final other = _findRecord(otherState, location: location);
      if (other != null && other.lifecycle == 'live') {
        throw MambaException(
          'Another scope already owns this physical installation; authority is ambiguous.',
          exitCode: 4,
        );
      }
    }
  }

  InstallationRecord? _findRecord(
    String state, {
    String? installationId,
    String? location,
  }) {
    final matches = _readRecords(state).where(
      (record) =>
          (installationId == null || record.installationId == installationId) &&
          (location == null || p.equals(record.location, location)),
    );
    if (matches.length > 1) {
      throw MambaException(
        'Ambiguous managed installation records.',
        exitCode: 4,
      );
    }
    return matches.isEmpty ? null : matches.single;
  }

  void _commitRecords(
    String state,
    List<InstallationRecord> upsert,
    Map<String, Object?> transaction,
  ) {
    final records = _readRecords(state).toList();
    for (final record in upsert) {
      final index = records.indexWhere(
        (current) => current.installationId == record.installationId,
      );
      final conflictingAuthority = records.any(
        (current) =>
            current.installationId != record.installationId &&
            current.lifecycle == 'live' &&
            record.lifecycle == 'live' &&
            p.equals(current.location, record.location),
      );
      if (conflictingAuthority) {
        throw MambaException(
          'A different managed installation already owns ${record.location}.',
          exitCode: 4,
        );
      }
      if (index < 0) {
        records.add(record);
      } else {
        records[index] = record;
      }
    }
    records.sort(
      (left, right) => left.installationId.compareTo(right.installationId),
    );
    final path = p.join(state, 'installations.json');
    _writeManagementJson(path, <String, Object?>{
      'schemaVersion': 1,
      'installations': [for (final record in records) record.toJson()],
    });
  }

  Map<String, Object?> _readTransaction(String path) =>
      _object(_readManagementJson(path), 'transaction');

  void _writeTransaction(String path, Map<String, Object?> value) {
    _writeManagementJson(path, value);
  }

  Object? _readManagementJson(String path) {
    final bytes = io.read(path, maxManagementDocumentBytes);
    _chargeManagementBytes(bytes.length, Zone.current);
    if (bytes.length > maxManagementDocumentBytes) {
      throw MambaException(
        'Management document exceeds 8 MiB: $path',
        exitCode: 3,
      );
    }
    try {
      return _BoundedJsonParser(utf8.decode(bytes, allowMalformed: false))
          .parse();
    } on FormatException catch (error) {
      throw MambaException(
        'Invalid management document $path: ${error.message}',
        exitCode: 4,
      );
    }
  }

  void _writeManagementJson(String path, Object? value) {
    final bytes = utf8.encode(jsonEncode(value));
    _chargeManagementBytes(bytes.length, Zone.current);
    if (bytes.length > maxManagementDocumentBytes) {
      throw MambaException('Management update exceeds 8 MiB.', exitCode: 3);
    }
    io.createDirectory(p.dirname(path));
    _makePrivate(p.dirname(path));
    final temporary = '$path.${_newId('tmp')}.tmp';
    _requireAbsent(temporary);
    io.write(temporary, bytes);
    io.rename(temporary, path);
  }

  Future<T> _serialized<T>(
    LifecycleContext context,
    String location,
    Future<T> Function() body,
  ) async {
    // Uniqueness spans project and user scopes. All cooperating mutations
    // acquire the same stable pair in lexical order; removal/recovery uses
    // this domain as well so aliases cannot bypass a pending operation.
    final states = _coordinationStates(context)..sort();
    final key = states.map(_pathKey).join('\n');
    final previous = _inProcessLocks[key] ?? Future<void>.value();
    final completion = Completer<void>.sync();
    _inProcessLocks[key] = completion.future;
    await previous;
    final locks = <RandomAccessFile>[];
    try {
      for (final state in states) {
        final coordination = p.join(state, 'coordination');
        io.createDirectory(coordination);
        _makePrivate(coordination);
        final lock = File(p.join(coordination, 'lifecycle.lock'))
            .openSync(mode: FileMode.write);
        locks.add(lock);
        lock.lockSync(FileLock.exclusive);
      }
      return await runZoned(
        body,
        zoneValues: <Object, Object?>{_metadataBudgetZone: _MetadataBudget()},
      );
    } on FileSystemException catch (error) {
      throw MambaException(
        'Could not acquire lifecycle coordination for $location: ${error.message}',
        exitCode: 4,
      );
    } finally {
      for (final lock in locks.reversed) {
        try {
          lock.unlockSync();
        } on FileSystemException {
          // Closing also releases the lock; preserve an operation result.
        }
        lock.closeSync();
      }
      completion.complete();
      if (identical(_inProcessLocks[key], completion.future)) {
        _inProcessLocks.remove(key);
      }
    }
  }

  void _requireSafePath(
    String location,
    String nativeRoot, {
    bool allowFinalLink = false,
  }) {
    if (!p.isAbsolute(location) || !p.isWithin(nativeRoot, location)) {
      throw MambaException(
        'The installation location is outside its native root.',
        exitCode: 4,
      );
    }
    for (final component in skillPathComponents(
      location,
      base: p.dirname(nativeRoot),
    )) {
      if (allowFinalLink && p.equals(component, location)) continue;
      if (io.type(component, followLinks: false) == FileSystemEntityType.link) {
        throw MambaException(
          'Refusing linked installation authority: $component',
          exitCode: 4,
        );
      }
    }
  }

  void _requireSourceDistinct(
    String source,
    String location,
    String nativeRoot,
    String state,
  ) {
    bool contains(String parent, String child) =>
        p.equals(parent, child) || p.isWithin(parent, child);
    if (contains(source, location) || contains(location, source)) {
      throw MambaException(
        'Source and destination must be distinct and non-containing.',
        exitCode: 4,
      );
    }
    if (contains(source, state) || contains(state, source)) {
      throw MambaException(
        'Source and management storage must not overlap.',
        exitCode: 4,
      );
    }
    final staging = p.join(p.dirname(nativeRoot), '.agent-resource');
    if (contains(source, staging) || contains(staging, source)) {
      throw MambaException(
        'Source and staging storage must not overlap.',
        exitCode: 4,
      );
    }
  }

  void _requireAbsent(String path) {
    if (io.type(path, followLinks: false) != FileSystemEntityType.notFound) {
      throw MambaException('The destination is occupied: $path', exitCode: 4);
    }
  }

  void _requireApproval(LifecycleContext context, String operation) {
    if (!context.approved) {
      throw MambaException(
        'The $operation requires destructive approval with --yes or explicit interactive confirmation.',
        exitCode: 4,
      );
    }
  }

  Map<String, Object?> _planData(
    String operation,
    LifecycleContext context,
    String location,
    LifecycleCandidate candidate,
  ) => <String, Object?>{
    'operation': operation,
    'location': location,
    'scope': context.scope.name,
    'name': candidate.name,
    'nativeForm': candidate.nativeForm,
    'validatedProfiles': candidate.validatedProfiles,
    'validationCoverage': 'complete',
    'uniquenessCoverage': 'complete',
    'ownership': operation == 'install'
        ? 'verifiedAbsent'
        : 'eligibleUnmanaged',
    'backupExpected': false,
    'mutationApproved': false,
  };

  void _prepareStaging(String nativeRoot) {
    _makePrivate(p.join(p.dirname(nativeRoot), '.agent-resource'));
  }

  String _stagePath(String nativeRoot, String transactionId, String name) {
    final path = p.join(
      p.dirname(nativeRoot),
      '.agent-resource',
      'staging',
      transactionId,
      name,
    );
    return path;
  }

  void _makePrivate(String path) {
    if (io.type(path, followLinks: false) == FileSystemEntityType.notFound) {
      io.createDirectory(path);
    }
    if (io.type(path, followLinks: false) != FileSystemEntityType.directory) {
      throw MambaException(
        'Private storage is not a directory: $path',
        exitCode: 4,
      );
    }
    if (Platform.isWindows) {
      final username = Platform.environment['USERNAME'];
      if (username == null || username.trim().isEmpty) {
        throw MambaException(
          'Cannot verify the Windows owner for private management storage.',
          exitCode: 4,
        );
      }
      final restricted = Process.runSync('icacls', [
        path,
        '/inheritance:r',
        '/grant:r',
        '$username:(OI)(CI)F',
        'SYSTEM:(OI)(CI)F',
        'Administrators:(OI)(CI)F',
      ]);
      if (restricted.exitCode != 0) {
        throw MambaException(
          'Could not restrict Windows management storage ACLs: $path',
          exitCode: 4,
        );
      }
      final verification = Process.runSync('icacls', [path]);
      final acl = '${verification.stdout}'.toLowerCase();
      final broadGrants = ['everyone', 'authenticated users', 'builtin\\users'];
      if (verification.exitCode != 0 ||
          !acl.contains(username.toLowerCase()) ||
          broadGrants.any(acl.contains)) {
        throw MambaException(
          'Windows management storage privacy could not be verified: $path',
          exitCode: 4,
        );
      }
      return;
    }
    final result = Process.runSync('chmod', ['700', path]);
    if (result.exitCode != 0) {
      throw MambaException(
        'Could not make management storage private: $path',
        exitCode: 4,
      );
    }
    final mode = FileStat.statSync(path).mode;
    if (mode & 0x3F != 0) {
      throw MambaException(
        'Management storage is not private: $path',
        exitCode: 4,
      );
    }
  }

  void _removeIfPresent(String path) {
    if (io.type(path, followLinks: false) != FileSystemEntityType.notFound) {
      io.delete(path);
    }
  }

  static String _newId(String prefix) {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return '${prefix}_${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
  }
}

final class _InstallPreparation {
  const _InstallPreparation(this.candidate, this.sourceDigest);
  final LifecycleCandidate candidate;
  final String sourceDigest;
}

ArtifactKind _contentKind(ArtifactKind kind) =>
    kind == ArtifactKind.skillLink ? ArtifactKind.skillCopy : kind;

ArtifactKind _artifactKindFromWire(String value) => switch (value) {
  'skill-copy' => ArtifactKind.skillCopy,
  'skill-link' => ArtifactKind.skillLink,
  'agent-file' => ArtifactKind.agentFile,
  _ => throw FormatException('Unsupported artifact kind: $value'),
};

String _resourceLabel(ArtifactKind kind) =>
    kind == ArtifactKind.agentFile ? 'agent' : 'skill';

String _pathKey(String path) =>
    Platform.isWindows ? p.normalize(path).toLowerCase() : p.normalize(path);

void _sameCandidate(LifecycleCandidate left, LifecycleCandidate right) {
  if (left.name != right.name || left.nativeForm != right.nativeForm) {
    throw MambaException(
      'The validated candidate changed during the operation.',
      exitCode: 4,
    );
  }
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map<String, Object?>) {
    throw FormatException('$label must be an object.');
  }
  return value;
}

List<Object?> _list(Object? value, String label) {
  if (value is! List<Object?>) {
    throw FormatException('$label must be an array.');
  }
  return value;
}

String _string(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('$key must be a nonempty string.');
  }
  return value;
}

String? _nullableString(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value != null && value is! String) {
    throw FormatException('$key must be a string or null.');
  }
  return value as String?;
}

int _integer(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! int) throw FormatException('$key must be an integer.');
  return value;
}

int _nonNegativeInteger(Map<String, Object?> map, String key) {
  final value = _integer(map, key);
  if (value < 0) throw FormatException('$key must not be negative.');
  return value;
}

bool _bool(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! bool) throw FormatException('$key must be a boolean.');
  return value;
}

String _enumValue(String value, List<String> choices) {
  if (!choices.contains(value)) {
    throw FormatException('Unsupported value: $value.');
  }
  return value;
}

String? _digest(Object? value) {
  if (value == null) return null;
  if (value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException('Invalid SHA-256 digest.');
  }
  return value;
}

String _id(String value, String prefix) {
  if (!RegExp('^${prefix}_[a-f0-9]{32}\$').hasMatch(value)) {
    throw FormatException('Invalid $prefix identifier.');
  }
  return value;
}

String? _nullableId(Object? value, String prefix) =>
    value == null ? null : _id(value is String ? value : '', prefix);

List<String> _stringList(Object? value) {
  final list = _list(value, 'string list');
  if (list.any((item) => item is! String)) {
    throw const FormatException('Expected a string array.');
  }
  return List<String>.unmodifiable(list.cast<String>());
}

String _absolutePath(String value) {
  _rejectTerminalControls(value);
  if (!p.isAbsolute(value) || p.normalize(value) != value) {
    throw const FormatException('Expected a normalized absolute path.');
  }
  return value;
}

String _relativePath(String value) {
  _rejectTerminalControls(value);
  if (value.isEmpty ||
      p.isAbsolute(value) ||
      p.normalize(value) != value ||
      p.split(value).any((part) => part == '..')) {
    throw FormatException('Invalid baseline relative path: $value');
  }
  return value;
}

void _rejectTerminalControls(String value) {
  if (value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7F)) {
    throw const FormatException(
      'Filesystem paths must not contain control characters.',
    );
  }
}

Object? _terminalSafe(Object? value) {
  if (value is! String) return value;
  final buffer = StringBuffer();
  for (final unit in value.codeUnits) {
    buffer.writeCharCode(unit < 0x20 || unit == 0x7F ? 0x3F : unit);
  }
  return buffer.toString();
}

/// Duplicate-key, depth and node enforcing JSON parser for management data.
final class _BoundedJsonParser {
  _BoundedJsonParser(this.source);
  final String source;
  var index = 0;
  var nodes = 0;

  Object? parse([int depth = 0]) {
    if (depth > maxManagementDepth) {
      throw const FormatException('JSON depth exceeds 32.');
    }
    if (++nodes > maxManagementNodes) {
      throw const FormatException('JSON node count exceeds 100000.');
    }
    _space();
    if (index >= source.length) {
      throw const FormatException('Unexpected end of JSON.');
    }
    final char = source.codeUnitAt(index);
    final Object? value;
    if (char == 0x7B) {
      value = _map(depth);
    } else if (char == 0x5B) {
      value = _array(depth);
    } else if (char == 0x22) {
      value = _stringValue();
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
      if (index != source.length) {
        throw const FormatException('Trailing JSON content.');
      }
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
        throw const FormatException('Expected an object key.');
      }
      final key = _stringValue();
      if (result.containsKey(key)) {
        throw FormatException('Duplicate JSON key: $key.');
      }
      _space();
      if (!_take(0x3A)) throw const FormatException('Expected a colon.');
      result[key] = parse(depth + 1);
      _space();
      if (_take(0x7D)) return result;
      if (!_take(0x2C)) {
        throw const FormatException('Expected an object comma.');
      }
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
      if (!_take(0x2C)) throw const FormatException('Expected an array comma.');
    }
  }

  String _stringValue() {
    final start = index;
    index++;
    while (index < source.length) {
      final char = source.codeUnitAt(index++);
      if (char == 0x22) {
        final raw = source.substring(start, index);
        return jsonDecode(raw) as String;
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
    if (match == null) throw const FormatException('Invalid JSON value.');
    index = match.end;
    final raw = match.group(0)!;
    final value = num.parse(raw);
    if (value is double && !value.isFinite) {
      throw const FormatException('Non-finite JSON number.');
    }
    return value;
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
