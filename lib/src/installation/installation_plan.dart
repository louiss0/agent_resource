import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';

import '../services/acquisition_service.dart';

enum InstallationResourceType { skill, agent }

enum InstallationTarget { claude, codex, pi }

enum InstallationMethod implements MambaEnumValue {
  canonical('canonical'),
  copy('copy'),
  sourceLink('source-link');

  const InstallationMethod(this.wireName);
  final String wireName;

  @override
  String get value => wireName;
}

enum InstallationUnitStatus {
  planned('planned'),
  installed('installed'),
  unchanged('unchanged'),
  failedRestored('failed-restored'),
  recoveryRequired('recovery-required'),
  notStarted('not-started'),
  interrupted('interrupted');

  const InstallationUnitStatus(this.wireName);
  final String wireName;
}

enum InstallationEntryKind { content, copy, link, consumer }

enum OwnedArtifactKind { skillCopy, skillLink, skillCanonical, agentFile }

enum InstallationEntryAction {
  createContent('create-content'),
  createCopy('create-copy'),
  createLink('create-link'),
  recordConsumer('record-consumer'),
  unchanged('unchanged');

  const InstallationEntryAction(this.wireName);
  final String wireName;
}

final class ResourceUnitPublicationResult {
  const ResourceUnitPublicationResult({
    required this.status,
    required this.installationIds,
    required this.transactionId,
  });

  final InstallationUnitStatus status;
  final List<String> installationIds;
  final String transactionId;
}

enum InstallationOutcome {
  planned('planned'),
  installed('installed'),
  unchanged('unchanged');

  const InstallationOutcome(this.wireName);
  final String wireName;
}

final class InstallationEntryPlan {
  const InstallationEntryPlan({
    required this.path,
    required this.kind,
    required this.action,
    this.target,
    this.linkTarget,
    this.nativeRoot,
    this.nativeDestination,
    this.artifactKind,
    this.observedDigest,
  });

  final String path;
  final InstallationEntryKind kind;
  final InstallationEntryAction action;
  final String? target;
  final String? linkTarget;
  final String? nativeRoot;
  final String? nativeDestination;
  final OwnedArtifactKind? artifactKind;
  final String? observedDigest;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'kind': kind.name,
    'action': action.wireName,
    if (target != null) 'target': target,
    if (linkTarget != null) 'linkTarget': linkTarget,
  };

  Map<String, Object?> identityJson() => <String, Object?>{
    ...toJson(),
    if (observedDigest != null) 'observedDigest': observedDigest,
  };

  InstallationEntryPlan copyWith({
    InstallationEntryAction? action,
    String? observedDigest,
  }) => InstallationEntryPlan(
    path: path,
    kind: kind,
    action: action ?? this.action,
    target: target,
    linkTarget: linkTarget,
    nativeRoot: nativeRoot,
    nativeDestination: nativeDestination,
    artifactKind: artifactKind,
    observedDigest: observedDigest ?? this.observedDigest,
  );
}

final class InstallationUnitPlan {
  InstallationUnitPlan({
    required this.resourceType,
    required this.resourceId,
    required this.nativeName,
    required this.profile,
    required this.method,
    required this.status,
    required this.installationIds,
    required List<InstallationEntryPlan> entries,
    required this.sourcePath,
    required this.sourceDigest,
    required this.origin,
  }) : entries = List<InstallationEntryPlan>.unmodifiable(entries);

  final InstallationResourceType resourceType;
  final String resourceId;
  final String nativeName;
  final String? profile;
  final InstallationMethod method;
  final InstallationUnitStatus status;
  final List<String> installationIds;
  final List<InstallationEntryPlan> entries;
  final String sourcePath;
  final String sourceDigest;
  final Map<String, Object?> origin;

  Map<String, Object?> toJson() => <String, Object?>{
    'resourceType': resourceType.name,
    'resourceId': resourceId,
    'nativeName': nativeName,
    if (profile != null) 'profile': profile,
    'method': method.wireName,
    'status': status.wireName,
    'installationIds': installationIds,
    'entries': [for (final entry in entries) entry.toJson()],
  };

  Map<String, Object?> identityJson() => <String, Object?>{
    'resourceType': resourceType.name,
    'resourceId': resourceId,
    'nativeName': nativeName,
    if (profile != null) 'profile': profile,
    'method': method.wireName,
    'entries': [for (final entry in entries) entry.identityJson()],
    'sourceDigest': sourceDigest,
    'origin': origin,
  };

  InstallationUnitPlan copyWith({
    InstallationUnitStatus? status,
    List<String>? installationIds,
    List<InstallationEntryPlan>? entries,
  }) => InstallationUnitPlan(
    resourceType: resourceType,
    resourceId: resourceId,
    nativeName: nativeName,
    profile: profile,
    method: method,
    status: status ?? this.status,
    installationIds: List<String>.unmodifiable(
      installationIds ?? this.installationIds,
    ),
    entries: entries ?? this.entries,
    sourcePath: sourcePath,
    sourceDigest: sourceDigest,
    origin: origin,
  );
}

/// An immutable reviewed plan. Its ID binds request and observations but is
/// neither a reservation nor a persisted approval token.
final class InstallationPlan {
  InstallationPlan._({
    required this.command,
    required this.source,
    required this.scope,
    required List<InstallationUnitPlan> units,
    required this.planId,
    this.diagnostics = const <Map<String, Object?>>[],
  }) : units = List<InstallationUnitPlan>.unmodifiable(units);

  factory InstallationPlan.create({
    required String command,
    required AcquisitionProvenance source,
    required String scope,
    required List<InstallationUnitPlan> units,
    List<Map<String, Object?>> diagnostics = const <Map<String, Object?>>[],
  }) {
    final planId = sha256
        .convert(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'planVersion': 2,
              'command': command,
              'source': source.toJson(),
              'scope': scope,
              'units': [for (final unit in units) unit.identityJson()],
            }),
          ),
        )
        .toString();
    return InstallationPlan._(
      command: command,
      source: source,
      scope: scope,
      units: units,
      planId: 'plan_v2_$planId',
      diagnostics: List<Map<String, Object?>>.unmodifiable(diagnostics),
    );
  }

  final String command;
  final AcquisitionProvenance source;
  final String scope;
  final List<InstallationUnitPlan> units;
  final String planId;
  final List<Map<String, Object?>> diagnostics;

  Map<String, Object?> envelope(InstallationOutcome outcome) =>
      <String, Object?>{
        'schemaVersion': 2,
        'command': command,
        'outcome': outcome.wireName,
        'data': <String, Object?>{
          'planId': planId,
          'source': source.toJson(),
          'scope': scope,
          'units': [for (final unit in units) unit.toJson()],
          'summary': summary,
        },
        'diagnostics': diagnostics,
      };

  Map<String, Object?> get summary => <String, Object?>{
    'requestedUnits': units.length,
    'installed': units
        .where((unit) => unit.status == InstallationUnitStatus.installed)
        .length,
    'unchanged': units
        .where((unit) => unit.status == InstallationUnitStatus.unchanged)
        .length,
    'planned': units
        .where((unit) => unit.status == InstallationUnitStatus.planned)
        .length,
    'ownedEntryEffects': units
        .expand((unit) => unit.entries)
        .where((entry) => entry.action != InstallationEntryAction.unchanged)
        .length,
  };

  String renderText(InstallationOutcome outcome) {
    final buffer = StringBuffer()
      ..writeln('$command: ${outcome.wireName}')
      ..writeln('Plan: $planId')
      ..writeln('Source: ${source.resolvedLocator}')
      ..writeln('Scope: $scope');
    if (source.requestedRef != null) {
      buffer.writeln('Requested ref: ${source.requestedRef}');
    }
    if (source.resolvedCommit != null) {
      buffer.writeln('Resolved commit: ${source.resolvedCommit}');
    }
    if (source.directFile) {
      buffer.writeln('Package boundary: this single file only.');
    }
    for (final unit in units) {
      buffer
        ..writeln(
          '${unit.resourceType.name} ${unit.resourceId}: ${unit.status.wireName}',
        )
        ..writeln('  Native name: ${unit.nativeName}')
        ..writeln('  Method: ${unit.method.wireName}');
      if (unit.profile != null) buffer.writeln('  Profile: ${unit.profile}');
      for (final id in unit.installationIds) {
        buffer.writeln('  Installation: $id');
      }
      for (final entry in unit.entries) {
        buffer.write('  ${entry.action.wireName}: ${entry.path}');
        if (entry.target != null) buffer.write(' [${entry.target}]');
        if (entry.linkTarget != null) buffer.write(' -> ${entry.linkTarget}');
        buffer.writeln();
      }
    }
    buffer.write('Summary: ${jsonEncode(summary)}');
    return buffer.toString();
  }
}
