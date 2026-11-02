import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import '../services/acquisition_service.dart';
import '../services/lifecycle_state_service.dart';
import 'installation_interaction.dart';
import 'installation_plan.dart';
import 'resource_catalog.dart';
import 'skill_source_discovery.dart';

final class InstallationWorkflowRequest {
  const InstallationWorkflowRequest({
    required this.source,
    required this.options,
    required this.sourceKind,
    required this.resourceIds,
    required this.allResources,
    required this.targets,
    required this.method,
    required this.profile,
    required this.ref,
    required this.subpath,
    required this.scopeExplicit,
  });

  final String? source;
  final LifecycleOptions options;
  final AcquisitionSourceKind? sourceKind;
  final List<String> resourceIds;
  final bool allResources;
  final List<InstallationTarget> targets;
  final InstallationMethod? method;
  final NativeAgentProfile? profile;
  final String? ref;
  final String? subpath;
  final bool scopeExplicit;
}

sealed class InstallationWorkflowResult {
  const InstallationWorkflowResult();
}

final class InstallationCompletedResult extends InstallationWorkflowResult {
  const InstallationCompletedResult(this.plan, this.outcome);

  final InstallationPlan plan;
  final InstallationOutcome outcome;
}

final class InstallationCancelledResult extends InstallationWorkflowResult {
  const InstallationCancelledResult(this.command);

  final String command;
}

final class InstallationCandidate {
  const InstallationCandidate({
    required this.id,
    required this.path,
    required this.label,
    required this.profile,
    required this.catalogEntry,
  });

  final String? id;
  final String path;
  final String? label;
  final NativeAgentProfile? profile;
  final bool catalogEntry;
}

final class InstallationCandidateSet {
  const InstallationCandidateSet(
    this.candidates,
    this.provenance, {
    this.selectionWarning,
  });

  final List<InstallationCandidate> candidates;
  final AcquisitionProvenance provenance;
  final String? selectionWarning;
}

/// Resolves exact resources, curated catalogs, or bounded Skill discovery.
/// Explicit catalogs remain authoritative; discovery never executes content.
Future<InstallationCandidateSet?> resolveInstallationCandidates({
  required AcquisitionWorkspace workspace,
  required InstallationWorkflowRequest request,
  required InstallationInteraction interaction,
  required CatalogResourceType resourceType,
  required bool interactive,
  fslib.FileSystem fileSystem = const local.LocalFileSystem(),
}) async {
  String checkedPath(String path) {
    final relative = fileSystem.path
        .relative(path, from: workspace.selectedRoot)
        .split(fileSystem.path.separator)
        .join('/');
    final repositoryPath = p.posix.normalize(
      p.posix.join(workspace.provenance.subpath ?? '.', relative),
    );
    for (final link in workspace.omittedLinkPaths) {
      if (repositoryPath == '.' ||
          link == repositoryPath ||
          link.startsWith('$repositoryPath/')) {
        throw MambaException(
          'The selected resource contains an unsupported Git symlink: $link. No incomplete package was installed.',
          exitCode: 4,
        );
      }
    }
    return path;
  }

  final kind = _sourceKind(
    workspace,
    request,
    resourceType,
    interactive,
    fileSystem,
  );
  if (kind == AcquisitionSourceKind.collection) {
    if (request.profile != null) {
      throw MambaException(
        '--profile applies only to a direct native agent file; catalog entries '
        'already declare their profile.',
      );
    }
    final config = fileSystem.path.join(
      workspace.selectedRoot,
      sourceConfigFileName,
    );
    final hasConfig =
        fileSystem.typeSync(config, followLinks: false) ==
        FileSystemEntityType.file;
    final catalog = hasConfig
        ? ResourceCatalog.load(config, resourceType, fileSystem: fileSystem)
        : null;
    var offerings =
        catalog?.offerings ??
        await _discoverSkills(workspace.selectedRoot, fileSystem);
    if (resourceType == CatalogResourceType.agent &&
        request.targets.isNotEmpty) {
      offerings = offerings.where((offering) {
        final profile = (offering as AgentOffering).profile;
        return request.targets.contains(_profileTarget(profile));
      }).toList();
    }
    if (offerings.isEmpty) {
      throw MambaException(
        'The selected ${resourceType.name} catalog has no offerings matching '
        'the request; no other resource type or location was scanned.',
      );
    }
    List<CatalogOffering> selected;
    if (request.resourceIds.isNotEmpty) {
      selected = [
        for (final offering in offerings)
          if (request.resourceIds.contains(offering.id)) offering,
      ];
      final matched = selected.map((offering) => offering.id).toSet();
      final missing = request.resourceIds.where((id) => !matched.contains(id));
      if (missing.isNotEmpty) {
        throw MambaException(
          'Catalog resource selector(s) did not match exactly: '
          '${missing.join(', ')}. No broader selection was used.',
        );
      }
    } else if (request.allResources) {
      selected = offerings;
    } else if (!interactive) {
      throw MambaException(
        'Unattended collection installation requires --resource or '
        '--all-resources.',
      );
    } else {
      final grouped =
          resourceType == CatalogResourceType.skill &&
          offerings.any(
            (offering) =>
                offering is SkillOffering && offering.discoveryGroup != null,
          );
      if (grouped) {
        selected = [];
        final groups = <String>[];
        for (final offering in offerings.cast<SkillOffering>()) {
          final key =
              '${offering.discoveryRoot}\u0000${offering.discoveryGroup}';
          if (!groups.contains(key)) groups.add(key);
        }
        for (final key in groups) {
          final separator = key.indexOf('\u0000');
          final root = key.substring(0, separator);
          final group = key.substring(separator + 1);
          final groupOfferings = offerings
              .cast<SkillOffering>()
              .where(
                (offering) =>
                    offering.discoveryRoot == root &&
                    offering.discoveryGroup == group,
              )
              .toList();
          final answer = await interaction.selectResources(
            groupOfferings,
            group: group,
          );
          if (answer.status == InteractionAnswerStatus.cancelled) return null;
          if (answer.status == InteractionAnswerStatus.value) {
            selected.addAll(answer.value!);
          }
        }
        if (selected.isEmpty) {
          return InstallationCandidateSet(
            const [],
            workspace.provenance,
            selectionWarning: 'No Skill groups were selected; nothing was installed and no management state was written.',
          );
        }
      } else {
        while (true) {
          final answer = await interaction.selectResources(offerings);
          if (answer.status == InteractionAnswerStatus.cancelled) return null;
          if (answer.status == InteractionAnswerStatus.value) {
            selected = answer.value!;
            break;
          }
        }
      }
    }
    if (selected.isEmpty) {
      throw MambaException('No resources were selected.');
    }
    if (resourceType == CatalogResourceType.agent && !interactive) {
      final expected = selected
          .map(
            (offering) => _profileTarget((offering as AgentOffering).profile),
          )
          .toSet();
      if (expected.length != request.targets.length ||
          !expected.every(request.targets.contains)) {
        throw MambaException(
          'Unattended --target values must exactly match the native profiles '
          'of all selected agent entries.',
        );
      }
    }
    return InstallationCandidateSet(
      [
        for (final offering in selected)
          InstallationCandidate(
            id: offering.id,
            path: checkedPath(workspace.resolveOffering(offering)),
            label: offering.label,
            profile: offering is AgentOffering ? offering.profile : null,
            catalogEntry: true,
          ),
      ],
      catalog == null
          ? workspace.provenance
          : workspace.provenance.withConfigDigest(catalog.configDigest),
    );
  }

  if (request.resourceIds.isNotEmpty || request.allResources) {
    throw MambaException(
      '--resource and --all-resources apply to curated collections, not an '
      'exact resource source.',
    );
  }
  if (resourceType == CatalogResourceType.agent &&
      workspace.selectedFile == null) {
    throw MambaException(
      'An exact agent resource must be one explicitly selected native file.',
      exitCode: 2,
    );
  }
  if (resourceType == CatalogResourceType.skill &&
      workspace.selectedFile != null &&
      fileSystem.path.basename(workspace.selectedFile!) != 'SKILL.md') {
    throw MambaException(
      'An exact single-file Skill source must be named SKILL.md.',
      exitCode: 2,
    );
  }
  var profile = request.profile;
  if (resourceType == CatalogResourceType.agent && profile == null) {
    if (!interactive) {
      throw MambaException(
        'A direct agent file requires --profile in unattended mode; native '
        'Markdown profiles are never inferred.',
      );
    }
    final answer = await interaction.requestAgentProfile();
    if (answer.status != InteractionAnswerStatus.value) return null;
    profile = answer.value;
  }
  if (resourceType == CatalogResourceType.agent &&
      !interactive &&
      (request.targets.length != 1 ||
          request.targets.single != _profileTarget(profile!))) {
    throw MambaException(
      'A direct agent file requires one --target consistent with --profile.',
    );
  }
  final selectedFile = workspace.selectedFile;
  final selectedPath =
      resourceType == CatalogResourceType.skill && selectedFile != null
      ? fileSystem.path.dirname(selectedFile)
      : selectedFile ?? workspace.selectedRoot;
  return InstallationCandidateSet([
    InstallationCandidate(
      id: null,
      path: checkedPath(selectedPath),
      label: null,
      profile: profile,
      catalogEntry: false,
    ),
  ], workspace.provenance);
}

AcquisitionSourceKind _sourceKind(
  AcquisitionWorkspace workspace,
  InstallationWorkflowRequest request,
  CatalogResourceType resourceType,
  bool interactive,
  fslib.FileSystem fileSystem,
) {
  final explicit = request.sourceKind;
  if (workspace.selectedFile != null) {
    if (fileSystem.path.basename(workspace.selectedFile!) ==
        sourceConfigFileName) {
      throw MambaException(
        'A direct configuration file cannot authorize crawling its host; '
        'select the containing local repository, Git repository, or archive.',
      );
    }
    if (explicit == AcquisitionSourceKind.collection) {
      throw MambaException(
        'A collection source must select its containing directory, repository, '
        'or archive, not a direct configuration file.',
      );
    }
    if (explicit == null && !interactive) {
      throw MambaException(
        'Unattended exact-resource installation requires '
        '--source-kind resource.',
      );
    }
    return AcquisitionSourceKind.resource;
  }
  final config = fileSystem.path.join(
    workspace.selectedRoot,
    sourceConfigFileName,
  );
  final hasConfig =
      fileSystem.typeSync(config, followLinks: false) ==
      FileSystemEntityType.file;
  final hasRootSkill =
      resourceType == CatalogResourceType.skill &&
      fileSystem.typeSync(
            fileSystem.path.join(workspace.selectedRoot, 'SKILL.md'),
            followLinks: false,
          ) ==
          FileSystemEntityType.file;
  if (explicit == AcquisitionSourceKind.resource) {
    if (resourceType == CatalogResourceType.agent) {
      throw MambaException('An exact agent source must be a native file.');
    }
    return AcquisitionSourceKind.resource;
  }
  if (explicit == AcquisitionSourceKind.collection || hasConfig) {
    if (explicit == null && hasRootSkill) {
      throw MambaException(
        'The selected directory contains both root Skill content and a '
        'collection config; supply --source-kind explicitly.',
      );
    }
    if (!hasConfig && resourceType != CatalogResourceType.skill) {
      throw MambaException(
        'The selected collection has no $sourceConfigFileName at its explicit '
        'root; no recursive search was performed.',
        exitCode: 3,
      );
    }
    return AcquisitionSourceKind.collection;
  }
  if (hasRootSkill) {
    if (!interactive) {
      throw MambaException(
        'Unattended exact-resource installation requires '
        '--source-kind resource.',
      );
    }
    return AcquisitionSourceKind.resource;
  }
  if (resourceType == CatalogResourceType.skill) {
    return AcquisitionSourceKind.collection;
  }
  throw MambaException(
    'The selected root has neither an exact resource marker nor '
    '$sourceConfigFileName; no heuristic scan was performed.',
    exitCode: 2,
  );
}

// Prefer conventional distribution roots. If absent, inspect only direct
// Skills and one group level in the selected tree, never its ancestors.
Future<List<CatalogOffering>> _discoverSkills(
  String root,
  fslib.FileSystem fileSystem,
) async {
  final roots = ['skills', '.agents/skills', '.claude/skills', '.codex/skills']
      .map((path) => fileSystem.path.joinAll([root, ...path.split('/')]))
      .where(
        (path) =>
            fileSystem.typeSync(path, followLinks: false) ==
            FileSystemEntityType.directory,
      )
      .toList();
  // Do not follow linked conventional roots or intermediate directories.
  for (final candidate in roots) {
    var current = root;
    for (final segment in fileSystem.path.split(
      fileSystem.path.relative(candidate, from: root),
    )) {
      current = fileSystem.path.join(current, segment);
      if (fileSystem.typeSync(current, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw MambaException(
          'Skill discovery refuses a linked source directory: $current',
          exitCode: 4,
        );
      }
    }
  }
  final offerings = <SkillOffering>[];
  final budget = SkillDiscoveryBudget();
  for (final directory in roots.isEmpty ? [root] : roots) {
    final relative = p
        .relative(directory, from: root)
        .split(fileSystem.path.separator)
        .join('/');
    offerings.addAll(
      await discoverSkillSource(
        root: directory,
        relativeRoot: relative,
        budget: budget,
        fileSystem: fileSystem,
      ),
    );
  }
  if (offerings.length > maxCatalogEntries) {
    throw MambaException(
      'Skill discovery exceeded its 1,000-resource budget.',
      exitCode: 3,
    );
  }
  offerings.sort((left, right) {
    final leftRoot = left.discoveryGroup == 'root';
    final rightRoot = right.discoveryGroup == 'root';
    if (leftRoot != rightRoot) return leftRoot ? -1 : 1;
    var comparison = (left.discoveryGroup ?? '').compareTo(
      right.discoveryGroup ?? '',
    );
    if (comparison != 0) return comparison;
    comparison = (left.discoveryRoot ?? '').compareTo(
      right.discoveryRoot ?? '',
    );
    if (comparison != 0) return comparison;
    comparison = (left.label ?? '').compareTo(right.label ?? '');
    if (comparison != 0) return comparison;
    return left.path.compareTo(right.path);
  });
  if (offerings.isEmpty) {
    throw MambaException(
      'No Skills found in the selected source. Searched direct Skills and one group level in skills/ and conventional harness skills folders, or the selected tree when none exist; expected an exact SKILL.md.',
      exitCode: 2,
    );
  }
  return offerings;
}

InstallationTarget _profileTarget(NativeAgentProfile profile) =>
    switch (profile) {
      NativeAgentProfile.claude => InstallationTarget.claude,
      NativeAgentProfile.codex => InstallationTarget.codex,
      NativeAgentProfile.piCommon => InstallationTarget.pi,
    };
