/// Bounded, read-only native Agent inventory.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import 'agent_inspection.dart';
import 'skill_files.dart';

const _maxAncestors = 64;
const _maxDepth = 16;
const _maxEntries = 20000;
const _maxDirectories = 2000;
const _maxMetadataBytes = 64 * 1024 * 1024;
const _maxDefinitionBytes = 1048576;

/// The installation scopes included in an inventory.
enum AgentScope { project, user, all }

/// Explicit context and presentation choices for one native inventory.
final class AgentInventoryInput {
  const new({
    required this.processWorkingDirectory,
    this.environment = const <String, String>{},
    this.scope = AgentScope.project,
    this.harness,
    this.verify = false,
    this.cwd,
    this.projectRoot,
    this.home,
    this.claudeConfigDir,
    this.codexHome,
    this.piAgentDir,
    this.readRoots = const <String>[],
    this.stateDir,
  });

  final String processWorkingDirectory;
  final Map<String, String> environment;
  final AgentScope scope;
  final AgentHarness? harness;
  final bool verify;
  final String? cwd;
  final String? projectRoot;
  final String? home;
  final String? claudeConfigDir;
  final String? codexHome;
  final String? piAgentDir;
  final List<String> readRoots;
  final String? stateDir;
}

/// A complete static inventory. Incomplete coverage throws instead of being
/// returned as a successful truncated result.
final class AgentInventoryReport {
  AgentInventoryReport._({
    required this.scope,
    required this.verification,
    required List<Map<String, Object?>> occurrences,
    required List<Map<String, Object?>> collisions,
    required this.coverage,
    required this.diagnostics,
  }) : occurrences = List<Map<String, Object?>>.unmodifiable(
         occurrences.map(Map<String, Object?>.unmodifiable),
       ),
       collisions = List<Map<String, Object?>>.unmodifiable(
         collisions.map(Map<String, Object?>.unmodifiable),
       );

  final AgentScope scope;
  final String verification;
  final List<Map<String, Object?>> occurrences;
  final List<Map<String, Object?>> collisions;
  final Map<String, Object?> coverage;
  final List<AgentDiagnostic> diagnostics;

  AgentInventoryReport withManagement({
    required List<Map<String, Object?>> managedOccurrences,
    required String managementVerification,
    required Map<String, Object?> managementCoverage,
  }) => AgentInventoryReport._(
    scope: scope,
    verification: managementVerification,
    occurrences: managedOccurrences,
    collisions: collisions,
    coverage: managementCoverage,
    diagnostics: diagnostics,
  );

  Map<String, Object?> envelope() => <String, Object?>{
    'schemaVersion': 1,
    'command': 'agent list',
    'outcome': 'inventoried',
    'data': <String, Object?>{
      'scope': scope.name,
      'verification': verification,
      'occurrences': occurrences,
      'collisions': collisions,
      'coverage': coverage,
    },
    'diagnostics': [for (final diagnostic in diagnostics) diagnostic.toJson()],
  };

  String renderText() {
    final buffer = StringBuffer()..writeln('agent list: inventoried');
    void render(Object? value, String indent) {
      if (value is Map<String, Object?>) {
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

    render(envelope()['data'], '');
    render(<String, Object?>{
      'diagnostics': [
        for (final diagnostic in diagnostics) diagnostic.toJson(),
      ],
    }, '');
    return buffer.toString();
  }
}

/// Inventories only explicitly selected native roots and declarations.
Future<AgentInventoryReport> listNativeAgents(AgentInventoryInput input) =>
    _Inventory(input).run();

final class _Root {
  const _Root({
    required this.path,
    required this.anchor,
    required this.harness,
    required this.scope,
    required this.destination,
    required this.piDistinction,
  });

  final String path;
  final String anchor;
  final AgentHarness harness;
  final AgentScope scope;
  final String destination;
  final bool piDistinction;
}

final class _Inventory {
  _Inventory(this.input);

  final AgentInventoryInput input;
  final occurrences = <Map<String, Object?>>[];
  final diagnostics = <AgentDiagnostic>[];
  late final Directory cwd;
  late final Directory projectRoot;
  var entries = 0;
  var directories = 0;
  var metadataBytes = 0;
  var rootsConsidered = 0;
  var rootsScanned = 0;
  var rootsAbsent = 0;
  var ancestors = 0;
  var boundarySearchSteps = 0;
  var depth = 0;
  final scannedLocations = <String>{};
  final occurrenceIds = <String>{};
  final visitedDirectories = <String>{};
  final readRoots = <Directory>[];

  Future<AgentInventoryReport> run() async {
    cwd = await _directory(
      input.cwd ?? input.processWorkingDirectory,
      input.processWorkingDirectory,
      'working directory',
    );
    projectRoot = await _selectProjectRoot();
    // Presentation filters and scope never bypass explicitly supplied context.
    for (final raw in input.readRoots) {
      readRoots.add(await _directory(raw, cwd.path, 'read root'));
    }
    if (input.home case final home?) {
      await _directory(home, cwd.path, 'home directory');
    }
    for (final (raw, label) in [
      (input.claudeConfigDir, 'Claude config directory'),
      (input.codexHome, 'Codex home'),
      (input.piAgentDir, 'Pi Agent directory'),
    ]) {
      if (raw != null) {
        await _refuseLinkedPath(_path(raw, cwd.path), cwd.path);
        await _directory(raw, cwd.path, label);
      }
    }

    if (input.scope != AgentScope.user) {
      await _addProjectRoots();
    }
    if (input.scope != AgentScope.project) {
      await _addUserRoots();
    }

    occurrences.sort((left, right) {
      final byPath = (left['path']! as String).compareTo(
        right['path']! as String,
      );
      if (byPath != 0) return byPath;
      return (left['occurrenceId']! as String).compareTo(
        right['occurrenceId']! as String,
      );
    });
    final collisions = _collisions();
    return AgentInventoryReport._(
      scope: input.scope,
      verification: input.verify ? 'no-managed-baselines' : 'not-requested',
      occurrences: occurrences,
      collisions: collisions,
      coverage: <String, Object?>{
        'status': 'complete',
        'rootsConsidered': rootsConsidered,
        'rootsScanned': rootsScanned,
        'rootsAbsent': rootsAbsent,
        'ancestors': ancestors,
        'boundarySearchSteps': boundarySearchSteps,
        'depth': depth,
        'entries': entries,
        'directories': directories,
        'metadataBytes': metadataBytes,
        'limits': const <String, int>{
          'ancestors': _maxAncestors,
          'depth': _maxDepth,
          'entries': _maxEntries,
          'directories': _maxDirectories,
          'metadataBytes': _maxMetadataBytes,
        },
        'exclusions': const <String>[
          'native trust, enablement, managed/plugin/session sources',
          'selected Codex profile files and cross-layer runtime fallback',
          'runtime precedence, activation, and effective dispatch',
          'ownership, lifecycle identity, and modification verification',
        ],
      },
      diagnostics: diagnostics,
    );
  }

  Future<void> _addProjectRoots() async {
    final scanAncestors =
        _selected(AgentHarness.claude) || _selected(AgentHarness.codex);
    final chain = scanAncestors ? _ancestors() : [projectRoot];
    ancestors = chain.length;
    for (final ancestor in chain) {
      if (_selected(AgentHarness.claude)) {
        await _scanRoot(
          _Root(
            path: p.join(ancestor.path, '.claude', 'agents'),
            anchor: ancestor.path,
            harness: AgentHarness.claude,
            scope: AgentScope.project,
            destination: 'native',
            piDistinction: false,
          ),
        );
      }
      if (_selected(AgentHarness.codex)) {
        await _scanRoot(
          _Root(
            path: p.join(ancestor.path, '.codex', 'agents'),
            anchor: ancestor.path,
            harness: AgentHarness.codex,
            scope: AgentScope.project,
            destination: 'native',
            piDistinction: false,
          ),
        );
        await _scanCodexConfig(
          p.join(ancestor.path, '.codex', 'config.toml'),
          AgentScope.project,
          ancestor.path,
        );
      }
    }
    if (_selected(AgentHarness.pi)) {
      for (final (path, destination) in [
        (p.join(projectRoot.path, '.pi', 'agents'), 'native'),
        (p.join(projectRoot.path, '.agents', 'agents'), 'shared'),
      ]) {
        await _scanRoot(
          _Root(
            path: path,
            anchor: projectRoot.path,
            harness: AgentHarness.pi,
            scope: AgentScope.project,
            destination: destination,
            piDistinction: true,
          ),
        );
      }
    }
    if (_selected(AgentHarness.claude)) {
      for (final directory in readRoots) {
        await _scanRoot(
          _Root(
            path: p.join(directory.path, '.claude', 'agents'),
            anchor: directory.path,
            harness: AgentHarness.claude,
            scope: AgentScope.project,
            destination: 'native',
            piDistinction: false,
          ),
        );
      }
    }
  }

  Future<void> _addUserRoots() async {
    final home = await _directory(_home(), cwd.path, 'home directory');
    if (_selected(AgentHarness.claude)) {
      final config = _path(
        input.claudeConfigDir ??
            _environmentPath('CLAUDE_CONFIG_DIR') ??
            p.join(home.path, '.claude'),
        cwd.path,
      );
      await _scanRoot(
        _Root(
          path: p.join(config, 'agents'),
          anchor: home.path,
          harness: AgentHarness.claude,
          scope: AgentScope.user,
          destination: 'native',
          piDistinction: false,
        ),
      );
    }
    if (_selected(AgentHarness.codex)) {
      final codexHome = _path(
        input.codexHome ??
            _environmentPath('CODEX_HOME') ??
            p.join(home.path, '.codex'),
        cwd.path,
      );
      await _scanRoot(
        _Root(
          path: p.join(codexHome, 'agents'),
          anchor: home.path,
          harness: AgentHarness.codex,
          scope: AgentScope.user,
          destination: 'native',
          piDistinction: false,
        ),
      );
      await _scanCodexConfig(
        p.join(codexHome, 'config.toml'),
        AgentScope.user,
        home.path,
      );
    }
    if (_selected(AgentHarness.pi)) {
      final piHome = _path(
        input.piAgentDir ??
            _environmentPath('PI_CODING_AGENT_DIR') ??
            p.join(home.path, '.pi', 'agent'),
        cwd.path,
      );
      await _scanRoot(
        _Root(
          path: p.join(piHome, 'agents'),
          anchor: home.path,
          harness: AgentHarness.pi,
          scope: AgentScope.user,
          destination: 'native',
          piDistinction: true,
        ),
      );
    }
  }

  String _path(String raw, String base) {
    if (raw.trim().isEmpty) {
      throw MambaException('A native context path must not be blank.');
    }
    return p.normalize(p.isAbsolute(raw) ? raw : p.join(base, raw));
  }

  String _home() {
    final explicit = input.home;
    if (explicit != null) return explicit;
    final home = _environmentPath('HOME') ?? _environmentPath('USERPROFILE');
    if (home == null) {
      throw MambaException(
        'A home directory is required for user inventory; supply --home.',
      );
    }
    return home;
  }

  String? _environmentPath(String name) {
    final value = input.environment[name];
    return value == null || value.trim().isEmpty ? null : value;
  }

  bool _selected(AgentHarness harness) =>
      input.harness == null || input.harness == harness;

  Future<Directory> _selectProjectRoot() async {
    final explicit = input.projectRoot;
    if (explicit != null) {
      final root = await _directory(explicit, cwd.path, 'project root');
      if (!p.equals(root.path, cwd.path) && !p.isWithin(root.path, cwd.path)) {
        throw MambaException(
          'The project root must contain the working directory.',
        );
      }
      return root;
    }
    var current = cwd;
    for (var step = 0; step < _maxAncestors; step++) {
      boundarySearchSteps++;
      final marker = p.join(current.path, '.git');
      final type = await _type(marker, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.directory) {
        return current;
      }
      final parentPath = p.dirname(current.path);
      if (p.equals(parentPath, current.path)) return cwd;
      current = Directory(parentPath);
    }
    throw MambaException(
      'The project boundary search exceeds the $_maxAncestors-step budget.',
      exitCode: 3,
    );
  }

  List<Directory> _ancestors() {
    final result = <Directory>[];
    var current = cwd;
    while (true) {
      result.add(current);
      if (p.equals(current.path, projectRoot.path)) return result;
      if (result.length >= _maxAncestors) {
        throw MambaException(
          'The project ancestor inventory exceeds the '
          '$_maxAncestors-step budget.',
          exitCode: 3,
        );
      }
      final parent = p.dirname(current.path);
      if (p.equals(parent, current.path)) {
        throw MambaException(
          'The project root is not within the working-directory ancestry.',
          exitCode: 1,
        );
      }
      current = Directory(parent);
    }
  }

  Future<Directory> _directory(String raw, String base, String label) async {
    if (raw.trim().isEmpty) {
      throw MambaException('The $label path must not be blank.');
    }
    final path = p.normalize(p.isAbsolute(raw) ? raw : p.join(base, raw));
    final type = await _type(path, followLinks: true);
    if (type == FileSystemEntityType.notFound) {
      throw MambaException('The $label does not exist: $path');
    }
    if (type != FileSystemEntityType.directory) {
      throw MambaException('The $label is not a directory: $path');
    }
    return Directory(path);
  }

  Future<FileSystemEntityType> _type(
    String path, {
    required bool followLinks,
  }) async {
    try {
      return await skillEntityTypeAsync(path, followLinks: followLinks);
    } on MambaException catch (error) {
      throw MambaException(error.message, exitCode: 3);
    }
  }

  Future<void> _scanRoot(_Root root) async {
    final location = '${root.scope.name}\n${root.harness.name}\n${root.path}';
    if (!scannedLocations.add(location)) return;
    rootsConsidered++;
    await _refuseLinkedPath(root.path, root.anchor);
    final type = await _type(root.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      rootsAbsent++;
      return;
    }
    if (type == FileSystemEntityType.link) {
      throw MambaException(
        'Refusing to traverse the linked native root ${root.path}.',
        exitCode: 4,
      );
    }
    if (type != FileSystemEntityType.directory) {
      throw MambaException(
        'The native root is not a directory: ${root.path}',
        exitCode: 3,
      );
    }

    if (!_visitDirectory(root, root.path)) {
      rootsScanned++;
      return;
    }
    final pending = <({Directory directory, int depth})>[
      (directory: Directory(root.path), depth: 0),
    ];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      depth = math.max(depth, current.depth);
      final children = await _list(current.directory);
      children.sort((left, right) => left.path.compareTo(right.path));
      for (final child in children.reversed) {
        final childType = await _type(child.path, followLinks: false);
        if (childType == FileSystemEntityType.directory) {
          if (current.depth >= _maxDepth) {
            throw MambaException(
              'The native inventory exceeds the depth-$_maxDepth budget.',
              exitCode: 3,
            );
          }
          if (!_visitDirectory(root, child.path)) continue;
          pending.add((
            directory: Directory(child.path),
            depth: current.depth + 1,
          ));
          continue;
        }
        final extension = switch (root.harness) {
          AgentHarness.codex => '.toml',
          AgentHarness.claude || AgentHarness.pi => '.md',
        };
        if (p.extension(child.path) != extension) continue;
        if (childType == FileSystemEntityType.link) {
          _addLinkedOccurrence(
            root,
            child.path,
            providerSpecific: root.piDistinction && current.depth > 0,
          );
          continue;
        }
        if (childType != FileSystemEntityType.file) continue;
        _chargeRead(child.path, _maxDefinitionBytes);
        final report = inspectNativeAgent(
          AgentInspectionInput(
            nativeFile: child.path,
            cwd: cwd.path,
            harness: root.harness,
          ),
          operation: AgentOperation.inspect,
        );
        _addReport(
          report,
          root: root,
          eligibility: root.piDistinction && current.depth > 0
              ? 'provider-specific'
              : 'native',
        );
      }
    }
    rootsScanned++;
  }

  bool _visitDirectory(_Root root, String path) {
    final location = '${root.scope.name}\n${root.harness.name}\n$path';
    if (!visitedDirectories.add(location)) return false;
    if (directories >= _maxDirectories) {
      throw MambaException(
        'The native inventory exceeds the $_maxDirectories-directory budget.',
        exitCode: 3,
      );
    }
    directories++;
    return true;
  }

  Future<List<FileSystemEntity>> _list(Directory directory) async {
    final children = <FileSystemEntity>[];
    try {
      // Charge before retaining; an exception cancels the directory stream.
      await for (final child in directory.list(followLinks: false)) {
        entries++;
        if (entries > _maxEntries) {
          throw MambaException(
            'The native inventory exceeds the $_maxEntries-entry budget.',
            exitCode: 3,
          );
        }
        children.add(child);
      }
      return children;
    } on FileSystemException catch (error) {
      throw MambaException(
        'Could not list native inventory directory ${directory.path}: '
        '${error.message}',
        exitCode: 3,
      );
    }
  }

  Future<void> _refuseLinkedPath(String path, String anchor) async {
    for (final component in skillPathComponents(path, base: anchor)) {
      if (await _type(component, followLinks: false) ==
          FileSystemEntityType.link) {
        throw MambaException(
          'Refusing to traverse the linked native path $component.',
          exitCode: 4,
        );
      }
    }
  }

  Future<void> _scanCodexConfig(
    String configPath,
    AgentScope scope,
    String anchor,
  ) async {
    rootsConsidered++;
    await _refuseLinkedPath(configPath, anchor);
    final type = await _type(configPath, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      rootsAbsent++;
      return;
    }
    if (type != FileSystemEntityType.link &&
        type != FileSystemEntityType.file) {
      throw MambaException(
        'The declaring config path is not a regular file: $configPath',
        exitCode: 3,
      );
    }
    final inspection = CodexBindingInspection.read(
      configFile: configPath,
      workingDirectory: p.dirname(configPath),
      beforeRead: _chargeRead,
    );
    final root = _Root(
      path: p.dirname(configPath),
      anchor: anchor,
      harness: AgentHarness.codex,
      scope: scope,
      destination: 'native',
      piDistinction: false,
    );
    for (final roleKey in inspection.roleKeys) {
      final report = inspection.inspectRole(
        roleKey,
        observeLinkedDefinition: true,
      );
      _addReport(
        report,
        root: root,
        eligibility: report.validationStatus is AgentValidationIncomplete
            ? 'unsupported-link'
            : 'native',
      );
    }
    rootsScanned++;
  }

  void _chargeRead(String path, int maxBytes) {
    final int length;
    try {
      length = File(path).lengthSync();
    } on FileSystemException catch (error) {
      throw MambaException(
        'Could not measure required metadata $path: ${error.message}',
        exitCode: 3,
      );
    }
    metadataBytes += math.min(length, maxBytes + 1);
    if (metadataBytes > _maxMetadataBytes) {
      throw MambaException(
        'The native inventory exceeds the 64 MiB metadata-read budget.',
        exitCode: 3,
      );
    }
  }

  void _addLinkedOccurrence(
    _Root root,
    String path, {
    bool providerSpecific = false,
  }) {
    final diagnostic = AgentDiagnostic(
      code: 'LINKED_CANDIDATE',
      category: AgentDiagnosticCategory.product,
      severity: AgentDiagnosticSeverity.warning,
      field: null,
      message: 'The linked candidate was reported without reading its target.',
    );
    _addOccurrence(
      root: root,
      path: path,
      binding: null,
      form: root.harness != AgentHarness.pi
          ? '${root.harness.name}-agent-file'
          : providerSpecific
          ? 'pi-provider-specific-file'
          : 'pi-agent-file',
      identity: _unresolvedIdentity(),
      validation: <String, Object?>{
        'status': 'incomplete',
        'coverage': const <String>['link-observation'],
        'diagnostics': [diagnostic.toJson()],
      },
      eligibility: 'unsupported-link',
    );
  }

  void _addReport(
    AgentInspectionReport report, {
    required _Root root,
    String eligibility = 'native',
  }) {
    final sourceBinding = report.binding;
    final binding = sourceBinding == null
        ? null
        : <String, Object?>{
            ...sourceBinding,
            'definitionFile': report.definitionFile,
          };
    final path =
        report.definitionFile ?? binding?['configFile'] as String? ?? '';
    if (path.isEmpty) {
      throw StateError('An inspected occurrence has no source location.');
    }
    _addOccurrence(
      root: root,
      path: path,
      binding: binding,
      form: eligibility == 'provider-specific'
          ? 'pi-provider-specific-file'
          : report.form,
      identity: report.identity,
      validation: <String, Object?>{
        'status': report.validationStatus.wireName,
        'coverage': report.coverage,
        'diagnostics': [
          for (final diagnostic in report.diagnostics) diagnostic.toJson(),
        ],
      },
      eligibility: eligibility,
    );
  }

  Map<String, Object?> _unresolvedIdentity() => <String, Object?>{
    'name': <String, Object?>{
      'declared': null,
      'resolved': null,
      'provenance': 'unresolved',
    },
    'description': <String, Object?>{
      'declared': null,
      'resolved': null,
      'provenance': 'unresolved',
    },
  };

  void _addOccurrence({
    required _Root root,
    required String path,
    required Map<String, Object?>? binding,
    required String form,
    required Map<String, Object?> identity,
    required Map<String, Object?> validation,
    required String eligibility,
  }) {
    final scope = root.scope.name;
    final roleKey = binding?['roleKey'] as String? ?? '';
    final id = sha256
        .convert(
          utf8.encode(
            'agent-occurrence-v1\n$scope\n${root.harness.name}\n$form\n'
            '$path\n${binding?['configFile'] ?? ''}\n$roleKey',
          ),
        )
        .toString();
    if (!occurrenceIds.add(id)) return;
    occurrences.add(<String, Object?>{
      'occurrenceId': id,
      'path': path,
      'root': root.path,
      'scope': scope,
      'harness': root.harness.name,
      'destination': root.destination,
      'form': form,
      'binding': binding,
      'eligibility': eligibility,
      'identity': identity,
      'validation': validation,
      'management': 'unmanaged',
      'modification': 'notVerified',
    });
  }

  List<Map<String, Object?>> _collisions() {
    final groups = <String, List<Map<String, Object?>>>{};
    for (final occurrence in occurrences) {
      final identity = occurrence['identity']! as Map<String, Object?>;
      final name = identity['name']! as Map<String, Object?>;
      final resolved = name['resolved'];
      if (resolved is! String || resolved.isEmpty) continue;
      final harness = occurrence['harness']! as String;
      final comparison = harness == 'pi' ? resolved.toLowerCase() : resolved;
      groups
          .putIfAbsent('$harness\n$comparison', () => <Map<String, Object?>>[])
          .add(occurrence);
    }
    final result = <Map<String, Object?>>[];
    for (final entry in groups.entries) {
      if (entry.value.length < 2) continue;
      final parts = entry.key.split('\n');
      result.add(<String, Object?>{
        'harness': parts[0],
        'comparisonName': parts[1],
        'occurrenceIds': [
          for (final occurrence in entry.value) occurrence['occurrenceId'],
        ],
      });
    }
    result.sort(
      (left, right) => '${left['harness']}\n${left['comparisonName']}'
          .compareTo('${right['harness']}\n${right['comparisonName']}'),
    );
    return result;
  }
}
