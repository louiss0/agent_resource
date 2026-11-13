import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import '../prompt/prompt_native_view.dart';
import '../prompt/prompt_validation_failure.dart';
import '../skill_files.dart';
import 'lifecycle_state_service.dart';
import 'prompt_inspection_service.dart';

/// A native read surface, not an installation destination or adapter.
enum PromptDestination { claude, codex, shared, pi, piTemplate }

enum PromptManagement { managed, unmanaged, ownershipUnverified }

/// One physical native occurrence, with no implied adoption or activation.
final class const PromptInventoryEntry({
  required final String path,
  required final String root,
  required final PromptDestination destination,
  required final LifecycleScope installationScope,
  required final PromptManagement management,
  required final PromptNativeViews native,
}) {
  Map<String, Object?> toJson() => <String, Object?>{
    ...native.toJson(),
    'path': path,
    'root': root,
    'destination': destination.name,
    'installationScope': installationScope.name,
    'management': management.name,
  };
}

/// A complete read-only inventory. Operational failures never return this value.
final class const PromptInventory({
  required final List<PromptInventoryEntry> entries,
  required final int rootsScanned,
  required final int rootsAbsent,
  required final PromptConsumer? consumer,
}) {
  Map<String, Object?> toJson() => <String, Object?>{
    'entries': [for (final entry in entries) entry.toJson()],
    'rootsScanned': rootsScanned,
    'rootsAbsent': rootsAbsent,
    if (consumer != null) 'selectedConsumer': consumer!.name,
  };

  String renderText() => [
    'prompt inventory: ${entries.length} occurrence(s)',
    for (final entry in entries) ...[
      '${entry.destination.name} ${entry.path}: '
          'placement=${entry.native.placement.name} '
          'global=${entry.native.globalCompatibility.name} '
          'management=${entry.management.name}',
      for (final view in entry.native.views.values) ...[
        '  ${view.consumer.name}: ${view.classification.name} '
            'valid=${view.valid} install=${view.installationSupported ? 'supported' : 'unsupported'}',
        for (final diagnostic in view.diagnostics)
          '    [${diagnostic.code}]: ${diagnostic.message}',
      ],
    ],
    'summary: ${entries.length} occurrence(s)',
  ].join('\n');
}

typedef _PromptSurface = ({
  String root,
  PromptDestination destination,
  PromptForm form,
});

/// Body-free native Prompt reads. Uses the existing parser and never installs,
/// adopts, writes state, executes a template or claims runtime activation.
interface class PromptReadService {
  factory PromptReadService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    PromptInspectionService? inspector,
    LifecycleStateService? state,
  }) => PromptReadService._(
    fileSystem,
    inspector ?? PromptInspectionService(fs: fileSystem),
    state ?? LifecycleStateService(io: LifecycleIO(fs: fileSystem)),
  );

  PromptReadService._(this._fileSystem, this._inspector, this._state);

  final fslib.FileSystem _fileSystem;
  final PromptInspectionService _inspector;
  final LifecycleStateService _state;

  /// A file is a template, not proof of any template profile. In particular,
  /// an arbitrary Markdown file without an explicit target stays unclassified.
  /// Explicit source reads cannot establish placement; inventory supplies it.
  Future<PromptNativeViews> inspect(
    String path, {
    PromptConsumer? consumer,
  }) async {
    final resolved = _fileSystem.path.normalize(
      _fileSystem.path.absolute(path),
    );
    var entries = 0;
    final type = await skillEntityTypeAsync(
      resolved,
      followLinks: false,
      fs: _fileSystem,
      chargeEntry: () => _requireEntryBudget(++entries),
    );
    return _inspect(
      resolved,
      type == FileSystemEntityType.file
          ? PromptForm.template
          : PromptForm.skill,
      consumer,
      PromptPlacement.unknown,
    );
  }

  Future<PromptNativeViews> _inspect(
    String path,
    PromptForm form,
    PromptConsumer? consumer,
    PromptPlacement placement,
  ) async => PromptNativeViews.fromInspection(
    await _inspector.inspect(
      path,
      form: form,
      consumer: consumer,
      placement: placement,
    ),
  );

  /// Unknown, invalid and ordinary Skill views cannot pass Prompt validation.
  /// With no selected target, returns the separate views only if all qualify.
  Future<PromptNativeViews> validate(
    String path, {
    PromptConsumer? consumer,
  }) async {
    final native = await inspect(path, consumer: consumer);
    final selected = consumer == null
        ? native.views.values
        : [native.views[consumer]!];
    final failing = selected.where((view) => !view.isPrompt || !view.valid);
    if (failing.isNotEmpty) throw PromptValidationFailure(native);
    return native;
  }

  /// Inventories direct native entries, observing the same bounded project
  /// ancestor chain as Skill inventory. Unknown/invalid Prompt candidates stay
  /// visible; known ordinary Skills are excluded from the selected Prompt view.
  Future<PromptInventory> list(
    LifecycleOptions options, {
    PromptConsumer? consumer,
  }) async {
    final entries = <PromptInventoryEntry>[];
    final seen = <String>{};
    var rootsScanned = 0;
    var rootsAbsent = 0;
    var visited = 0;
    void charge() => _requireEntryBudget(++visited);

    for (final scope in switch (options.scope) {
      LifecycleScope.project => const [LifecycleScope.project],
      LifecycleScope.user => const [LifecycleScope.user],
      LifecycleScope.all => const [LifecycleScope.project, LifecycleScope.user],
    }) {
      final context = LifecycleContext.resolve(
        options.copyWith(scope: scope),
        fileSystem: _fileSystem,
      );
      final managedPaths = _managedPaths(context);
      for (final surface in _surfaces(context)) {
        await _requireUnlinked(surface.root, charge);
        final type = await skillEntityTypeAsync(
          surface.root,
          followLinks: false,
          fs: _fileSystem,
          chargeEntry: charge,
        );
        if (type == FileSystemEntityType.notFound) {
          rootsAbsent++;
          continue;
        }
        if (type != FileSystemEntityType.directory) {
          throw MambaException(
            'Required Prompt inventory root is not a directory: ${surface.root}',
            exitCode: 3,
          );
        }
        rootsScanned++;
        for (final path in await _candidates(surface, charge)) {
          if (!seen.add(_fileSystem.path.normalize(path))) continue;
          // A native Pi template root supplies a profile, unlike an arbitrary
          // .md path. An explicitly selected other harness is never overridden.
          final native = await _inspect(
            path,
            surface.form,
            consumer ??
                (surface.form == PromptForm.template
                    ? PromptConsumer.pi
                    : null),
            scope == LifecycleScope.project
                ? PromptPlacement.project
                : PromptPlacement.user,
          );
          final relevant = consumer == null
              ? native.promptCandidate
              : native.views[consumer]!.classification !=
                    PromptClassification.nonPrompt;
          if (!relevant) continue;
          entries.add(
            PromptInventoryEntry(
              path: path,
              root: surface.root,
              destination: surface.destination,
              installationScope: scope,
              management: managedPaths == null
                  ? PromptManagement.ownershipUnverified
                  : managedPaths.contains(_pathKey(path))
                  ? PromptManagement.managed
                  : PromptManagement.unmanaged,
              native: native,
            ),
          );
        }
      }
    }
    entries.sort((left, right) => left.path.compareTo(right.path));
    return PromptInventory(
      entries: entries,
      rootsScanned: rootsScanned,
      rootsAbsent: rootsAbsent,
      consumer: consumer,
    );
  }

  List<_PromptSurface> _surfaces(LifecycleContext context) {
    if (context.scope == LifecycleScope.user) {
      return [
        (
          root: context.claudeSkillsRoot(),
          destination: PromptDestination.claude,
          form: PromptForm.skill,
        ),
        (
          root: context.codexSkillsRoot(),
          destination: PromptDestination.codex,
          form: PromptForm.skill,
        ),
        (
          root: context.sharedSkillsRoot(),
          destination: PromptDestination.shared,
          form: PromptForm.skill,
        ),
        (
          root: _fileSystem.path.join(context.piAgentRoot(), 'skills'),
          destination: PromptDestination.pi,
          form: PromptForm.skill,
        ),
        (
          root: _fileSystem.path.join(context.piAgentRoot(), 'prompts'),
          destination: PromptDestination.piTemplate,
          form: PromptForm.template,
        ),
      ];
    }
    final surfaces = <_PromptSurface>[];
    var current = context.cwd;
    for (var depth = 0; ; depth++) {
      if (depth >= 64) {
        throw MambaException(
          'Prompt inventory exceeds 64 ancestors.',
          exitCode: 3,
        );
      }
      for (final surface in const [
        (
          directory: '.claude',
          leaf: 'skills',
          destination: PromptDestination.claude,
          form: PromptForm.skill,
        ),
        (
          directory: '.codex',
          leaf: 'skills',
          destination: PromptDestination.codex,
          form: PromptForm.skill,
        ),
        (
          directory: '.agents',
          leaf: 'skills',
          destination: PromptDestination.shared,
          form: PromptForm.skill,
        ),
        (
          directory: '.pi',
          leaf: 'skills',
          destination: PromptDestination.pi,
          form: PromptForm.skill,
        ),
        (
          directory: '.pi',
          leaf: 'prompts',
          destination: PromptDestination.piTemplate,
          form: PromptForm.template,
        ),
      ]) {
        surfaces.add((
          root: _fileSystem.path.join(current, surface.directory, surface.leaf),
          destination: surface.destination,
          form: surface.form,
        ));
      }
      if (_fileSystem.path.equals(current, context.projectRoot)) break;
      current = _fileSystem.path.dirname(current);
    }
    return surfaces;
  }

  void _requireEntryBudget(int entries) {
    if (entries > maxSkillEntries) {
      throw MambaException(
        'Prompt inventory exceeds the 10,000-entry budget.',
        exitCode: 3,
      );
    }
  }

  Future<void> _requireUnlinked(String path, void Function() charge) async {
    for (final component in skillPathComponents(
      path,
      base: _fileSystem.path.rootPrefix(path),
      fs: _fileSystem,
    )) {
      if (await skillEntityTypeAsync(
            component,
            followLinks: false,
            fs: _fileSystem,
            chargeEntry: charge,
          ) ==
          FileSystemEntityType.link) {
        throw MambaException(
          'Prompt inventory refuses linked source entries: $component.',
          exitCode: 4,
        );
      }
    }
  }

  /// Streams the native root with a budget before retaining/sorting entries.
  Future<List<String>> _candidates(
    _PromptSurface surface,
    void Function() charge,
  ) async {
    final children = <fslib.FileSystemEntity>[];
    try {
      await for (final child
          in _fileSystem.directory(surface.root).list(followLinks: false)) {
        charge();
        children.add(child);
      }
    } on FileSystemException catch (error) {
      throw MambaException(
        'Could not read the Prompt inventory root ${surface.root}: ${error.message}',
        exitCode: 3,
      );
    }
    children.sort((left, right) => left.path.compareTo(right.path));
    final result = <String>[];
    for (final child in children) {
      final name = _fileSystem.path.basename(child.path);
      if (name.startsWith('.')) continue;
      final type = await skillEntityTypeAsync(
        child.path,
        followLinks: false,
        fs: _fileSystem,
        chargeEntry: charge,
      );
      if (type == FileSystemEntityType.notFound) {
        throw MambaException(
          'Prompt inventory source disappeared after listing: $name.',
        );
      }
      if (type == FileSystemEntityType.link) {
        throw MambaException(
          'Prompt inventory refuses linked source entries: $name.',
          exitCode: 4,
        );
      }
      if (surface.form == PromptForm.skill) {
        if (type != FileSystemEntityType.directory) continue;
        final marker = _fileSystem.path.join(child.path, 'SKILL.md');
        final markerType = await skillEntityTypeAsync(
          marker,
          followLinks: false,
          fs: _fileSystem,
          chargeEntry: charge,
        );
        if (markerType == FileSystemEntityType.link) {
          throw MambaException(
            'Prompt inventory refuses linked source entries: $marker.',
            exitCode: 4,
          );
        }
        if (markerType != FileSystemEntityType.notFound) result.add(child.path);
      } else if (type == FileSystemEntityType.file &&
          _fileSystem.path.extension(child.path).toLowerCase() == '.md') {
        result.add(child.path);
      }
    }
    return result;
  }

  String _pathKey(String path) {
    final normalized = _fileSystem.path.normalize(path);
    return _fileSystem.path.style == p.Style.windows
        ? normalized.toLowerCase()
        : normalized;
  }

  /// Read and index authority once per scope. Null means unverified ownership,
  /// not an empty ledger or a failed native inspection.
  Set<String>? _managedPaths(LifecycleContext context) {
    try {
      return {
        for (final record in _state.records(context))
          if (record.lifecycle == 'live') ...[
            _pathKey(record.location),
            for (final exposure in record.exposures) _pathKey(exposure.path),
          ],
      };
    } on Exception {
      return null;
    }
  }
}
