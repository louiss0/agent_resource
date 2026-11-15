import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;

import '../authoring/bound_role_authoring_inputs.dart';
import 'bound_role_service.dart';
import 'lifecycle_state_service.dart';

/// Plans and publishes explicit Codex bound-role authoring operations.
///
/// The service owns the typed native selections and reuses the existing
/// bound-role and parent-unit validators, the current-plan identity, the
/// stopped-client acknowledgement and the transaction safeguards. It never
/// registers a role, adopts an existing unit or changes the declaring config
/// on its own: every parent effect needs the explicit ownership, the
/// acknowledgement and the reviewed plan identity.
interface class BoundRoleAuthoringService {
  BoundRoleAuthoringService({
    BoundRoleService? boundRole,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : boundRole = boundRole ?? BoundRoleService(fileSystem: fileSystem);

  final BoundRoleService boundRole;

  /// Plans the reviewed bound-role change without writing anything.
  ///
  /// The returned plan identity is the identity the publication requires.
  Future<LifecycleResult> plan(
    BoundRoleAuthoringInputs inputs,
    LifecycleOptions options,
  ) async {
    final request = _request(inputs);
    return boundRole.run(request, options.copyWith(dryRun: true));
  }

  /// Publishes the reviewed bound-role change.
  ///
  /// The plan identity must match the current evidence, the publication
  /// needs its own approval, and a registration that writes the declaring
  /// config needs the stopped-client acknowledgement.
  Future<LifecycleResult> apply(
    BoundRoleAuthoringInputs inputs,
    LifecycleOptions options, {
    required String planId,
  }) async {
    final request = _request(inputs, planId: planId);
    return boundRole.run(request, options);
  }

  BoundRoleRequest _request(
    BoundRoleAuthoringInputs inputs, {
    String? planId,
  }) => BoundRoleRequest(
    operation: BoundOperation.create,
    configFile: inputs.configFile,
    roleKey: inputs.roleKey,
    ownership: inputs.ownership,
    source: inputs.definitionSource,
    output: inputs.definitionOutput,
    planId: planId,
    clientsStopped: inputs.clientsStopped,
  );
}
