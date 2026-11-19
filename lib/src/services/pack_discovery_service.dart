import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../installation/prompt_source_discovery.dart';
import '../installation/skill_source_discovery.dart';
import '../pack/pack_configuration.dart';
import '../pack/pack_discovery.dart';
import '../prompt/prompt_native_view.dart';
import '../services/acquisition_service.dart';
import '../services/pack_prompt_service.dart';
import '../services/prompt_inspection_service.dart';
import '../skill_files.dart';
import '../skill_validation.dart' show readDeclaredSkillName;
import '../validation/validation_diagnostics.dart';

/// Discovers the candidates of a pack source.
///
/// The discovery is a bounded read-only view. It never writes a management
/// state, never enrolls a membership and never advances an inventory.
interface class PackDiscoveryService {
  factory PackDiscoveryService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    PackPromptService? prompts,
  }) {
    final resolved = prompts ?? PackPromptService(fileSystem: fileSystem);
    return PackDiscoveryService._(fileSystem, resolved);
  }

  PackDiscoveryService._(this._fileSystem, this._prompts);

  final fslib.FileSystem _fileSystem;
  final PackPromptService _prompts;

  /// The Prompt scope of one pack source.
  ///
  /// The scope holds the declared Skill entries, the declared Prompt entries
  /// and the discovered Prompt sources. A declared catalog is authoritative:
  /// an undeclared path is never scanned.
  Future<List<PackScopeCandidate>> scopeCandidates(
    AcquisitionWorkspace workspace,
    PackDefinition pack,
    SourceCatalog? catalog, {
    String? target,
  }) async {
    final result = <PackScopeCandidate>[];
    if (catalog?.declared == true) {
      for (final entry in catalog!.skills) {
        result.add(
          await _scopeCandidate(
            kind: PackDiscoveryKind.skill,
            id: entry.path,
            path: _catalogPath(workspace, entry.path),
            target: target,
          ),
        );
      }
      for (final entry in catalog.prompts) {
        result.add(
          await _scopeCandidate(
            kind: PackDiscoveryKind.prompt,
            id: entry.path,
            path: _catalogPath(workspace, entry.path),
            profile: entry.profile,
            declared: true,
            target: target,
          ),
        );
      }
      return result;
    }
    final skillsRoot = _catalogPath(workspace, pack.discovery.skillsDirectory);
    final skillsRootType = skillEntityType(
      skillsRoot,
      followLinks: false,
      fs: _fileSystem,
    );
    if (skillsRootType != FileSystemEntityType.notFound) {
      if (skillsRootType != FileSystemEntityType.directory) {
        throw MambaException(
          'Pack discovery root must be a real directory: '
          '${ValidationDiagnostics.escape(pack.discovery.skillsDirectory)}.',
          exitCode: 2,
        );
      }
      final skillOfferings = await discoverSkillSource(
        root: skillsRoot,
        relativeRoot: pack.discovery.skillsDirectory,
        refuseLinkedEntries: true,
        subject: 'Pack',
        budgetExitCode: 2,
        linkExitCode: 2,
        fileSystem: _fileSystem,
      );
      for (final offering in skillOfferings) {
        result.add(
          await _scopeCandidate(
            kind: PackDiscoveryKind.skill,
            id: offering.path,
            path: _catalogPath(workspace, offering.path),
            target: target,
            discoveryRoot: offering.discoveryRoot,
            discoveryGroup: offering.discoveryGroup,
          ),
        );
      }
    }
    final promptsRoot = _catalogPath(
      workspace,
      pack.discovery.promptsDirectory,
    );
    final promptsRootType = skillEntityType(
      promptsRoot,
      followLinks: false,
      fs: _fileSystem,
    );
    if (promptsRootType == FileSystemEntityType.notFound) return result;
    if (promptsRootType != FileSystemEntityType.directory) {
      throw MambaException(
        'Pack discovery root must be a real directory: '
        '${ValidationDiagnostics.escape(pack.discovery.promptsDirectory)}.',
        exitCode: 2,
      );
    }
    final promptOfferings = await discoverPromptSource(
      root: promptsRoot,
      relativeRoot: pack.discovery.promptsDirectory,
      refuseLinkedEntries: true,
      subject: 'Pack Prompt',
      budgetExitCode: 2,
      linkExitCode: 2,
      fileSystem: _fileSystem,
    );
    for (final offering in promptOfferings) {
      result.add(
        await _scopeCandidate(
          kind: PackDiscoveryKind.prompt,
          id: offering.path,
          path: _catalogPath(workspace, offering.path),
          template: offering.template,
          target: target,
          discoveryRoot: offering.discoveryRoot,
          discoveryGroup: offering.discoveryGroup,
        ),
      );
    }
    return result;
  }

  /// The discovered candidates of one pack source.
  ///
  /// Every source is reported once with its per-consumer Prompt views. The
  /// Agent candidates of the pack are reported with their declared profile.
  Future<List<PackDiscoveryCandidate>> candidates(
    AcquisitionWorkspace workspace,
    PackDefinition pack,
    SourceCatalog? catalog, {
    String? target,
    List<PackScopeCandidate> scope = const <PackScopeCandidate>[],
  }) async {
    final discovered = <PackDiscoveryCandidate>[];
    final seen = <String>{};
    for (final candidate in scope) {
      if (seen.contains(candidate.path)) continue;
      seen.add(candidate.path);
      final views = candidate.view.source.views;
      discovered.add(
        PackDiscoveryCandidate(
          id: candidate.id,
          path: candidate.path,
          kind: candidate.kind,
          form: candidate.form,
          profile: candidate.profile,
          views: [
            for (final consumer in PromptConsumer.inspectable)
              PromptNativeView(
                consumer: consumer,
                classification:
                    views[consumer]?.classification ??
                    PromptClassification.unclassified,
                valid: views[consumer]?.valid ?? false,
                installationSupported:
                    views[consumer] != null &&
                    candidate.form == PackDiscoveryForm.skill &&
                    PromptNativeView.supportsInstallation(
                      views[consumer]!,
                      PromptForm.skill,
                      consumer,
                    ),
                diagnostics:
                    views[consumer]?.diagnostics ?? const <PromptDiagnostic>[],
              ),
          ],
          globalCompatibility: candidate.view.source.globalCompatibility,
          diagnostics: _scopeDiagnostics(candidate),
        ),
      );
    }
    discovered.sort(_compareCandidates);
    return discovered;
  }

  /// The candidate-level diagnostics of one scope candidate.
  ///
  /// A standalone template without a declared native profile and without an
  /// explicit discovery target stays unclassified, and the diagnostic names
  /// the missing context.
  List<PromptDiagnostic> _scopeDiagnostics(PackScopeCandidate candidate) {
    if (candidate.form != PackDiscoveryForm.template) {
      return const <PromptDiagnostic>[];
    }
    if (candidate.profile != null) return const <PromptDiagnostic>[];
    return const <PromptDiagnostic>[
      (
        code: 'PROMPT_PROFILE_REQUIRED',
        message:
            'A standalone template requires a declared native profile or an '
            'explicit discovery target.',
        path: '',
        line: null,
        column: null,
      ),
    ];
  }

  /// One candidate of the Prompt scope.
  ///
  /// The native name of a skill-backed Prompt is its declared name. A
  /// standalone template has no declared name: its label is its file name
  /// without the extension.
  Future<PackScopeCandidate> _scopeCandidate({
    required PackDiscoveryKind kind,
    required String id,
    required String path,
    String? profile,
    bool template = false,
    bool declared = false,
    String? target,
    String? discoveryRoot,
    String? discoveryGroup,
  }) async {
    final type = skillEntityType(path, followLinks: false, fs: _fileSystem);
    final standalone = template || type == FileSystemEntityType.file;
    final name = standalone
        ? _fileSystem.path.basenameWithoutExtension(path)
        : readDeclaredSkillName(path, fs: _fileSystem);
    final view = await _prompts.inspect(
      path,
      path,
      name: name,
      consumer:
          PackPromptService.consumerOf(profile) ??
          PackPromptService.consumerOf(target),
    );
    return PackScopeCandidate(
      kind: kind,
      id: id,
      path: path,
      name: name,
      form: standalone ? PackDiscoveryForm.template : PackDiscoveryForm.skill,
      view: view,
      profile: profile,
      declared: declared,
      discoveryRoot: discoveryRoot,
      discoveryGroup: discoveryGroup,
    );
  }

  /// The source path of one relative declaration.
  String _catalogPath(AcquisitionWorkspace workspace, String relative) {
    if (relative == '.') return workspace.selectedRoot;
    var current = workspace.selectedRoot;
    for (final segment in relative.split('/')) {
      current = _fileSystem.path.join(current, segment);
      if (skillEntityType(current, followLinks: false, fs: _fileSystem) ==
          FileSystemEntityType.link) {
        throw MambaException(
          'Pack source paths must not contain linked aliases: '
          '${ValidationDiagnostics.escape(relative)}.',
          exitCode: 2,
        );
      }
    }
    return current;
  }

  /// The deterministic order of the discovered candidates.
  int _compareCandidates(
    PackDiscoveryCandidate left,
    PackDiscoveryCandidate right,
  ) {
    final comparison = left.kind.index.compareTo(right.kind.index);
    if (comparison != 0) return comparison;
    return left.id.compareTo(right.id);
  }
}
