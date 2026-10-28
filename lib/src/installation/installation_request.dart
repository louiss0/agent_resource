import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import '../services/acquisition_service.dart';
import '../services/lifecycle_state_service.dart';
import 'installation_interaction.dart';
import 'installation_plan.dart';
import 'resource_catalog.dart';

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
  const InstallationCandidateSet(this.candidates, this.provenance);

  final List<InstallationCandidate> candidates;
  final AcquisitionProvenance provenance;
}

/// Resolves only the selected root/entry. Collections come exclusively from
/// curated configuration; exact resources never acquire catalog aliases.
Future<InstallationCandidateSet?> resolveInstallationCandidates({
  required AcquisitionWorkspace workspace,
  required InstallationWorkflowRequest request,
  required InstallationInteraction interaction,
  required CatalogResourceType resourceType,
  required bool interactive,
}) async {
  final kind = _sourceKind(workspace, request, resourceType, interactive);
  if (kind == AcquisitionSourceKind.collection) {
    if (request.profile != null) {
      throw MambaException(
        '--profile applies only to a direct native agent file; catalog entries '
        'already declare their profile.',
      );
    }
    final config = p.join(workspace.selectedRoot, sourceConfigFileName);
    final catalog = ResourceCatalog.load(config, resourceType);
    var offerings = catalog.offerings;
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
      while (true) {
        final answer = await interaction.selectResources(offerings);
        if (answer.status == InteractionAnswerStatus.cancelled) return null;
        if (answer.status == InteractionAnswerStatus.value) {
          selected = answer.value!;
          break;
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
    return InstallationCandidateSet([
      for (final offering in selected)
        InstallationCandidate(
          id: offering.id,
          path: workspace.resolveOffering(offering),
          label: offering.label,
          profile: offering is AgentOffering ? offering.profile : null,
          catalogEntry: true,
        ),
    ], workspace.provenance.withConfigDigest(catalog.configDigest));
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
      p.basename(workspace.selectedFile!) != 'SKILL.md') {
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
  return InstallationCandidateSet([
    InstallationCandidate(
      id: null,
      path: workspace.selectedFile ?? workspace.selectedRoot,
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
) {
  final explicit = request.sourceKind;
  if (workspace.selectedFile != null) {
    if (p.basename(workspace.selectedFile!) == sourceConfigFileName) {
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
  final config = p.join(workspace.selectedRoot, sourceConfigFileName);
  final hasConfig =
      FileSystemEntity.typeSync(config, followLinks: false) ==
      FileSystemEntityType.file;
  final hasRootSkill =
      resourceType == CatalogResourceType.skill &&
      FileSystemEntity.typeSync(
            p.join(workspace.selectedRoot, 'SKILL.md'),
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
    if (!hasConfig) {
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
  throw MambaException(
    'The selected root has neither an exact resource marker nor '
    '$sourceConfigFileName; no heuristic scan was performed.',
    exitCode: 2,
  );
}

InstallationTarget _profileTarget(NativeAgentProfile profile) =>
    switch (profile) {
      NativeAgentProfile.claude => InstallationTarget.claude,
      NativeAgentProfile.codex => InstallationTarget.codex,
      NativeAgentProfile.piCommon => InstallationTarget.pi,
    };
