import 'package:mamba/mamba.dart';

import '../services/bound_role_service.dart' show BoundOwnership;

/// The native flag vocabulary of the bound-role authoring handler.
///
/// The spellings are the only accepted selections. No operation-document
/// option is part of this vocabulary.
final class BoundRoleAuthoringFlags {
  const BoundRoleAuthoringFlags._();

  static const roleKey = 'role-key';
  static const configFile = 'config-file';
  static const ownership = 'ownership';
  static const definitionSource = 'definition-source';
  static const definitionOutput = 'definition-output';
  static const ackClientsStopped = 'ack-clients-stopped';
}

/// The guidance shown for a retired JSON operation-request route.
///
/// The retired route is not reinterpreted. The message names the native
/// selections that replace it.
const boundRoleRequestMigrationGuidance =
    'JSON operation-request routes are retired for bound-role authoring. '
    'Select the role with --${BoundRoleAuthoringFlags.roleKey}, the declaring '
    'Codex config with --${BoundRoleAuthoringFlags.configFile}, the claimed '
    'ownership with --${BoundRoleAuthoringFlags.ownership} (definition or '
    'both), the native Codex definition with '
    '--${BoundRoleAuthoringFlags.definitionSource}, the optional placement '
    'with --${BoundRoleAuthoringFlags.definitionOutput}, and acknowledge '
    'stopped native clients with '
    '--${BoundRoleAuthoringFlags.ackClientsStopped}.';

/// The explicit native inputs of one Codex bound-role authoring operation.
///
/// The values are named selections, never a serialized operation document.
/// A bound-role operation always states the role key, the declaring Codex
/// config and the ownership it claims, so a request file can never be
/// mistaken for a native selection.
final class BoundRoleAuthoringInputs {
  const BoundRoleAuthoringInputs({
    required this.roleKey,
    required this.configFile,
    required this.ownership,
    required this.clientsStopped,
    this.definitionSource,
    this.definitionOutput,
  });

  /// The Codex role key registered as `agents.<roleKey>`.
  final String roleKey;

  /// The declaring Codex config that owns the role registration.
  final String configFile;

  /// The ownership the operation claims.
  final BoundOwnership ownership;

  /// The native Codex definition published for the role.
  ///
  /// A definition-owning operation requires it. The path may name a
  /// reviewed candidate produced by the shared guided authoring flow.
  final String? definitionSource;

  /// An explicit placement for the published definition.
  final String? definitionOutput;

  /// The acknowledgement that native clients are stopped for parent writes.
  ///
  /// It is independent of the publication approval: a registration that
  /// writes the declaring config requires both.
  final bool clientsStopped;

  /// Whether the operation publishes a native Codex definition.
  bool get publishesDefinition => ownership != BoundOwnership.registration;

  /// Whether the operation registers the role in the declaring config.
  bool get registersRole => ownership != BoundOwnership.definition;
}

/// Parses and validates the explicit bound-role authoring inputs.
///
/// Every refusal names the supported alternative and happens before any
/// effect, so an unsupported combination never reaches the declaring config
/// or the native definition.
BoundRoleAuthoringInputs parseBoundRoleAuthoringInputs({
  required String? roleKey,
  required String? configFile,
  required String? ownership,
  String? definitionSource,
  String? definitionOutput,
  bool clientsStopped = false,
}) {
  final key = _required(roleKey, 'role key');
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key)) {
    throw MambaException(
      'The Codex role key must be one name segment of letters, digits, '
      'underscores or dashes.',
      exitCode: 4,
    );
  }
  final config = _required(configFile, 'declaring Codex config');
  final selectedOwnership = _ownership(ownership);
  final source = _optional(definitionSource);
  final output = _optional(definitionOutput);
  if (selectedOwnership == BoundOwnership.registration) {
    throw MambaException(
      'A bound-role create publishes a definition; select the definition or '
      'both ownership.',
      exitCode: 4,
    );
  }
  if (source == null) {
    throw MambaException(
      'A ${selectedOwnership.name} bound-role operation requires a native '
      'Codex definition source.',
      exitCode: 4,
    );
  }
  return BoundRoleAuthoringInputs(
    roleKey: key,
    configFile: config,
    ownership: selectedOwnership,
    definitionSource: source,
    definitionOutput: output,
    clientsStopped: clientsStopped,
  );
}

BoundOwnership _ownership(String? value) {
  final name = _required(value, 'ownership');
  final selected = BoundOwnership.values.where((item) => item.name == name);
  if (selected.length != 1) {
    throw MambaException(
      'Unsupported bound-role ownership: $name. Supported ownership values: '
      '${BoundOwnership.values.map((item) => item.name).join(', ')}.',
      exitCode: 4,
    );
  }
  return selected.single;
}

String _required(String? value, String label) {
  final trimmed = _optional(value);
  if (trimmed == null) {
    throw MambaException(
      'An explicit $label is required for a bound-role operation.',
      exitCode: 4,
    );
  }
  return trimmed;
}

String? _optional(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
