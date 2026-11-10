import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../agent_inspection.dart';
import '../authoring/authoring_inputs.dart';
import '../authoring/authoring_profiles.dart';
import '../authoring/authoring_receipt.dart';
import '../authoring/authoring_transaction.dart';
import '../authoring/package_manifest.dart';
import '../conversion/conversion_evidence.dart';
import '../skill_files.dart';
import 'agent_lifecycle_service.dart';
import 'authoring_plan_service.dart';
import 'authoring_recovery_service.dart';
import 'conversion_coordinator_service.dart';
import 'conversion_evidence_service.dart';
import 'lifecycle_state_service.dart';
import 'skill_lifecycle_service.dart';

/// The ownership that one publication established.
///
/// A managed publication owns an installation record. An author-only
/// publication owns no record: it carries an authoring receipt instead.
enum PublicationOwnership { authorOnly, managed }

/// The publication request of one reviewed authoring plan.
///
/// The request never carries a proposal. The reviewed plan is the only
/// source of the published content, and the reviewed plan identity is the
/// only approval that can authorize a publication.
final class AuthoringPublicationRequest {
  const AuthoringPublicationRequest({
    required this.plan,
    required this.options,
    required this.planId,
    this.approved = false,
    this.transactionId,
  });

  /// The reviewed plan. The publication never rebuilds the proposal.
  final AuthoringPlan plan;

  /// The selected context of the publication.
  final LifecycleOptions options;

  /// The plan identity that was reviewed and approved.
  final String planId;

  /// Whether the publication was explicitly approved.
  final bool approved;

  /// The transaction identifier of a coordinated conversion.
  final String? transactionId;
}

/// The outcome of one publication.
final class AuthoringPublicationOutcome {
  const AuthoringPublicationOutcome({
    required this.planId,
    required this.operation,
    required this.ownership,
    required this.targetPath,
    required this.data,
    this.installationId,
    this.receiptId,
    this.recoveryPath,
    this.sourceRetired = false,
    this.diagnostics = const <Map<String, Object?>>[],
  });

  /// The identity of the published plan.
  final String planId;

  /// The published operation.
  final String operation;

  /// The ownership that the publication established.
  final PublicationOwnership ownership;

  /// The published native location.
  final String targetPath;

  /// The managed installation of a managed publication.
  final String? installationId;

  /// The authoring receipt of an unmanaged output.
  ///
  /// A receipt is evidence of an authoring act. It is not an installation
  /// record and it never adopts a source.
  final String? receiptId;

  /// The retained recovery copy of a replaced or retired source.
  final String? recoveryPath;

  /// Whether the source was retired by the publication.
  final bool sourceRetired;

  /// The typed outcome data.
  final Map<String, Object?> data;

  /// The structured diagnostics of the publication.
  final List<Map<String, Object?>> diagnostics;
}

/// Publishes one reviewed authoring plan.
///
/// The service publishes the reviewed native content of a create, clone,
/// compose, edit or conversion plan. It never rebuilds a proposal: a
/// changed plan, a changed source, an occupied target or an unverified
/// authority refuses the publication before any live write.
///
/// A new output is author-only by default. An explicitly requested managed
/// publication reuses the ordinary lifecycle publication, so it keeps the
/// installation record, the baseline and the uniqueness authority of that
/// lifecycle. A Prompt has no managed lifecycle: a managed Prompt request is
/// refused instead of silently falling back to an author-only output.
interface class AuthoringPublicationService {
  factory AuthoringPublicationService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    LifecycleStateService? state,
    AgentLifecycleService? agents,
    SkillLifecycleService? skills,
    ConversionCoordinator? coordinator,
    AuthoringRecoveryService? recovery,
  }) {
    final io = LifecycleIO(fs: fileSystem);
    final resolved = state ?? LifecycleStateService(io: io);
    return AuthoringPublicationService._(
      fileSystem,
      resolved,
      agents ?? AgentLifecycleService(state: resolved, fileSystem: fileSystem),
      skills ?? SkillLifecycleService(state: resolved, fileSystem: fileSystem),
      coordinator ?? ConversionCoordinator(io: io, state: resolved),
      recovery ??
          AuthoringRecoveryService(fileSystem: fileSystem, state: resolved),
    );
  }

  AuthoringPublicationService._(
    this._fileSystem,
    this._state,
    this._agents,
    this._skills,
    this._coordinator,
    this._recovery,
  );
  final fslib.FileSystem _fileSystem;
  final LifecycleStateService _state;
  final AgentLifecycleService _agents;
  final SkillLifecycleService _skills;
  final ConversionCoordinator _coordinator;
  final AuthoringRecoveryService _recovery;
  final ConversionEvidenceService _evidence = ConversionEvidenceService();

  LifecycleIO get _io => _state.io;

  /// Publishes the reviewed plan.
  ///
  /// The publication is refused when the plan is not ready, when the
  /// approval does not bind the current plan identity, when the approval is
  /// missing or when the selected mode is a dry run.
  Future<AuthoringPublicationOutcome> publish(
    AuthoringPublicationRequest request,
  ) async {
    final plan = request.plan;
    if (!plan.ready) {
      throw MambaException(
        'The reviewed proposal is not ready; publish nothing.',
        exitCode: 4,
      );
    }
    if (request.planId != plan.planId) {
      throw MambaException(
        'Publication requires the current plan identity; stale approval is '
        'refused.',
        exitCode: 4,
      );
    }
    if (!request.approved) {
      throw MambaException(
        'Publication requires explicit approval.',
        exitCode: 4,
      );
    }
    if (request.options.dryRun) {
      throw MambaException('A dry run publishes nothing.', exitCode: 4);
    }
    final context = LifecycleContext.resolve(
      request.options,
      fileSystem: _fileSystem,
    );
    final conversion = plan.conversion;
    if (conversion != null) {
      return _publishConversion(request, context, conversion);
    }
    if (plan.operation == AuthoringOperation.edit) {
      return _publishEdit(request, context);
    }
    return _publishNewOutput(request, context);
  }

  /// Publishes a new create, clone or compose output.
  Future<AuthoringPublicationOutcome> _publishNewOutput(
    AuthoringPublicationRequest request,
    LifecycleContext context,
  ) async {
    final plan = request.plan;
    final target = _targetOf(plan);
    final source = _sourceOf(plan);
    if (source != null) _requireSourceUnchanged(source);
    _requireUnoccupied(target);
    _requireUnownedTarget(context, target);
    if (target.root != null) {
      await _requireNativeNameFree(context, plan, target);
    }
    if (plan.ownership == AuthoringOwnership.managedRequested) {
      return _publishManagedOutput(request, context, plan, target, source);
    }
    return _publishAuthorOnlyOutput(request, context, plan, target, source);
  }

  /// Publishes the native content of an unmanaged output.
  ///
  /// The output is untracked: no installation record, no baseline and no
  /// adoption. The native placement still refuses an occupied target and an
  /// occupied native name.
  Future<AuthoringPublicationOutcome> _publishAuthorOnlyOutput(
    AuthoringPublicationRequest request,
    LifecycleContext context,
    AuthoringPlan plan,
    _Target target,
    _Source? source,
  ) async {
    final candidate = _candidateOf(plan);
    final transaction = _prepareTransaction(context, plan, target, source);
    final created = <String>[];
    try {
      if (target.directory != null) {
        _io.createDirectory(target.directory!);
        created.add(target.directory!);
        _io.write(
          _fileSystem.path.join(target.directory!, 'SKILL.md'),
          candidate,
        );
        if (plan.sidecar != null && target.sidecar != null) {
          _io.createDirectory(_fileSystem.path.dirname(target.sidecar!));
          _io.write(target.sidecar!, utf8.encode(plan.sidecar!));
        }
        if (plan.operation == AuthoringOperation.clone && source != null) {
          _copyPackageMembers(
            source,
            target.directory!,
            replacesSidecar: plan.sidecar != null,
          );
        }
      } else {
        _io.createDirectory(_fileSystem.path.dirname(target.output));
        _io.write(target.output, candidate);
        created.add(target.output);
      }
      _verifyPublishedMarker(target, candidate);
    } on Exception {
      _removeCreated(created);
      rethrow;
    }
    _markPublished(context, transaction);
    final receipt = _commitTransaction(
      context,
      plan,
      target,
      source,
      transaction,
    );
    _completeTransaction(context, transaction);
    return AuthoringPublicationOutcome(
      planId: plan.planId,
      operation: plan.operation.name,
      ownership: PublicationOwnership.authorOnly,
      targetPath: target.output,
      receiptId: receipt,
      data: <String, Object?>{
        'planId': plan.planId,
        'writes': true,
        'operation': plan.operation.name,
        'ownership': 'authorOnly',
        'managed': false,
        'target': target.output,
        'root': target.root,
        'form': target.form,
        'receiptId': receipt,
        'candidateSha256': _digestBytes(candidate),
        ..._provenance(plan, source),
      },
    );
  }

  /// Publishes a managed new output through the ordinary lifecycle.
  ///
  /// The managed publication reuses the existing installation contract: the
  /// uniqueness authority, the staged publication, the installation record
  /// and the baseline of that lifecycle. A Prompt has no managed lifecycle
  /// and is refused.
  Future<AuthoringPublicationOutcome> _publishManagedOutput(
    AuthoringPublicationRequest request,
    LifecycleContext context,
    AuthoringPlan plan,
    _Target target,
    _Source? source,
  ) async {
    switch (plan.kind) {
      case AuthoringKind.prompt:
        throw MambaException(
          'Managed publication is not supported for Prompt resources; the '
          'request is refused instead of falling back to an author-only '
          'output.',
          exitCode: 4,
        );
      case AuthoringKind.skill:
        final destination = _skillDestination(plan.profile);
        if (destination == null) {
          throw MambaException(
            'Managed publication is not supported for the '
            '${plan.profile.name} profile.',
            exitCode: 4,
          );
        }
        final staged = _stagePackage(context, plan, target, source: source);
        try {
          final result = await _skills.install(
            SkillInstallInput(
              options: request.options,
              source: staged,
              destination: destination,
            ),
          );
          return _managedOutcome(plan, target, result, 'skill');
        } finally {
          _removeStaged(staged);
        }
      case AuthoringKind.agent:
        final harness = _harness(plan.profile);
        final result = await _agents.withStagedCandidate(
          options: request.options,
          harness: harness,
          destination: AgentDestination.native,
          output: target.output,
          content: plan.candidate!,
          body: (candidatePath) async {
            final installed = await _agents.install(
              AgentInstallInput(
                options: request.options,
                source: candidatePath,
                harness: harness,
                destination: AgentDestination.native,
                output: target.output,
              ),
            );
            return installed;
          },
        );
        return _managedOutcome(plan, target, result, 'agent');
    }
  }

  /// Publishes an edit of the selected source.
  ///
  /// An ordinary edit stays unmanaged: it replaces the source in place and
  /// retains a protected recovery copy of the previous bytes. A managed edit
  /// replaces the recorded installation and keeps its ownership.
  Future<AuthoringPublicationOutcome> _publishEdit(
    AuthoringPublicationRequest request,
    LifecycleContext context,
  ) async {
    final plan = request.plan;
    final source = _sourceOf(plan);
    if (source == null) {
      throw MambaException('An edit requires a reviewed source.', exitCode: 4);
    }
    final target = _targetOf(plan);
    _requireSourceUnchanged(source);
    if (plan.ownership == AuthoringOwnership.managedReplacement) {
      return _publishManagedEdit(request, context, plan, source, target);
    }
    await _requireNativeNameFree(
      context,
      plan,
      target,
      excludePath: source.path,
    );
    return _publishUnmanagedEdit(request, context, plan, source, target);
  }

  /// Replaces an ordinary source with the reviewed content.
  ///
  /// The replacement is staged in protected storage before the live source
  /// changes, and the previous bytes are retained as a recovery copy. The
  /// source stays unmanaged: no installation record is created and nothing
  /// is adopted.
  Future<AuthoringPublicationOutcome> _publishUnmanagedEdit(
    AuthoringPublicationRequest request,
    LifecycleContext context,
    AuthoringPlan plan,
    _Source source,
    _Target target,
  ) async {
    final candidate = _candidateOf(plan);
    final recovery = _retainRecovery(context, plan, source);
    final transaction = _prepareTransaction(
      context,
      plan,
      target,
      source,
      recoveryPath: recovery,
    );
    final staged = _stageBytes(context, plan, candidate);
    try {
      _verifyStaged(staged, candidate);
      if (target.directory != null) {
        _io.copyFile(
          staged,
          _fileSystem.path.join(target.directory!, 'SKILL.md'),
        );
        if (plan.sidecar != null && target.sidecar != null) {
          _io.createDirectory(_fileSystem.path.dirname(target.sidecar!));
          _io.write(target.sidecar!, utf8.encode(plan.sidecar!));
        }
      } else {
        _io.copyFile(staged, target.output);
      }
      _verifyPublishedMarker(target, candidate);
    } finally {
      _removeIfPresent(staged);
    }
    _markPublished(context, transaction);
    final receipt = _commitTransaction(
      context,
      plan,
      target,
      source,
      transaction,
    );
    _completeTransaction(context, transaction);
    return AuthoringPublicationOutcome(
      planId: plan.planId,
      operation: plan.operation.name,
      ownership: PublicationOwnership.authorOnly,
      targetPath: target.output,
      receiptId: receipt,
      recoveryPath: recovery,
      data: <String, Object?>{
        'planId': plan.planId,
        'writes': true,
        'operation': plan.operation.name,
        'ownership': 'authorOnly',
        'managed': false,
        'target': target.output,
        'root': target.root,
        'form': target.form,
        'receiptId': receipt,
        'recoveryPath': recovery,
        'sourceRetired': false,
        'candidateSha256': _digestBytes(candidate),
        ..._provenance(plan, source),
      },
    );
  }

  /// Replaces a managed installation with the reviewed content.
  ///
  /// The ordinary lifecycle replacement publishes the staged content, keeps
  /// the installation identity and retains the replaced bytes as a backup.
  Future<AuthoringPublicationOutcome> _publishManagedEdit(
    AuthoringPublicationRequest request,
    LifecycleContext context,
    AuthoringPlan plan,
    _Source source,
    _Target target,
  ) async {
    final installationId = source.installationId;
    if (installationId == null) {
      throw MambaException(
        'A managed edit requires the recorded installation.',
        exitCode: 4,
      );
    }
    final record = _state.recordById(context, installationId);
    if (_state.verify(record) != ModificationStatus.unchanged) {
      throw MambaException(
        'The managed source changed since its baseline; a reviewed plan '
        'cannot replace it.',
        exitCode: 4,
      );
    }
    switch (plan.kind) {
      case AuthoringKind.prompt:
        throw MambaException(
          'Managed publication is not supported for Prompt resources.',
          exitCode: 4,
        );
      case AuthoringKind.agent:
        final harness = _harness(plan.profile);
        final result = await _agents.withStagedCandidate(
          options: request.options,
          harness: harness,
          destination: AgentDestination.native,
          output: record.location,
          content: plan.candidate!,
          body: (candidatePath) async {
            final replaced = await _agents.replace(
              LifecycleReplaceInput(
                options: request.options,
                installationId: installationId,
                source: candidatePath,
              ),
              harness: harness,
            );
            return replaced;
          },
        );
        return _managedOutcome(plan, target, result, 'agent');
      case AuthoringKind.skill:
        final staged = _stagePackage(context, plan, target, source: source);
        try {
          final result = await _skills.replace(
            LifecycleReplaceInput(
              options: request.options,
              installationId: installationId,
              source: staged,
            ),
          );
          return _managedOutcome(plan, target, result, 'skill');
        } finally {
          _removeStaged(staged);
        }
    }
  }

  /// Publishes a conversion of the selected source.
  ///
  /// A tracked source is published through the coordinated transition, so
  /// the ownership, the identity and the recovery evidence follow the
  /// conversion contract. An ordinary source is published through the
  /// authoring path: the target is published, the previous bytes are
  /// retained and the source is retired only after the published target is
  /// verified.
  Future<AuthoringPublicationOutcome> _publishConversion(
    AuthoringPublicationRequest request,
    LifecycleContext context,
    ConversionDirection direction,
  ) async {
    final plan = request.plan;
    final source = _sourceOf(plan);
    if (source == null) {
      throw MambaException(
        'A conversion requires a reviewed source.',
        exitCode: 4,
      );
    }
    final target = _targetOf(plan);
    _requireSourceUnchanged(source);
    final installationId = source.installationId;
    if (installationId != null) {
      return _publishTrackedConversion(request, context, plan, source, target);
    }
    return _publishUntrackedConversion(
      request,
      context,
      plan,
      source,
      target,
      direction,
    );
  }

  /// Publishes a conversion of a tracked installation.
  Future<AuthoringPublicationOutcome> _publishTrackedConversion(
    AuthoringPublicationRequest request,
    LifecycleContext context,
    AuthoringPlan plan,
    _Source source,
    _Target target,
  ) async {
    final installationId = source.installationId!;
    final record = _state.recordById(context, installationId);
    if (record.lifecycle != 'live') {
      throw MambaException(
        'The conversion source is not a live installation.',
        exitCode: 4,
      );
    }
    if (_state.verify(record) != ModificationStatus.unchanged) {
      throw MambaException(
        'The managed conversion source changed since its baseline.',
        exitCode: 4,
      );
    }
    final conversionTarget = _conversionTarget(plan, target);
    final transactionId = request.transactionId ?? _newTransactionId();
    final sourceParticipant = ConversionParticipant(
      role: ConversionParticipantRole.source,
      intent: ConversionParticipantIntent.retired,
      artifactKind: record.kind.wireName,
      nativeForm: record.nativeForm,
      nativeProfile: record.nativeProfile,
      location: record.location,
      nativeRoot: record.nativeRoot,
      scope: record.scope.name,
      ownershipBefore: ConversionOwnership(
        managed: true,
        installationId: record.installationId,
        nativeForm: record.nativeForm,
        nativeProfile: record.nativeProfile,
        nativeDestination: record.nativeDestination,
        location: record.location,
        nativeRoot: record.nativeRoot,
        scope: record.scope.name,
      ),
      baseline: ConversionBaseline(
        entries: conversionManifestEntries(_io, record.location),
      ),
    );
    final targetParticipant = ConversionParticipant(
      role: ConversionParticipantRole.target,
      intent: ConversionParticipantIntent.created,
      artifactKind: conversionTarget.artifactKind,
      nativeForm: conversionTarget.nativeForm,
      nativeProfile: conversionTarget.nativeProfile,
      location: target.artifactLocation,
      nativeRoot: target.root,
      scope: context.scope.name,
      ownershipAfter: ConversionOwnership(
        managed: true,
        installationId: record.installationId,
        nativeForm: conversionTarget.nativeForm,
        nativeProfile: conversionTarget.nativeProfile,
        nativeDestination: conversionTarget.nativeDestination,
        location: target.artifactLocation,
        nativeRoot: target.root,
        scope: context.scope.name,
      ),
    );
    final outcome = await _coordinator.execute(
      ConversionTransitionRequest(
        transactionId: transactionId,
        options: request.options,
        source: sourceParticipant,
        target: targetParticipant,
        targetFiles: _targetFiles(plan, target),
        observations: <String, Object?>{
          'authoringPlanId': plan.planId,
          'authoringOperation': plan.operation.name,
          'authoringDirection': plan.conversion?.name,
        },
      ),
    );
    return AuthoringPublicationOutcome(
      planId: plan.planId,
      operation: plan.operation.name,
      ownership: PublicationOwnership.managed,
      targetPath: target.output,
      installationId: _installationAt(context, target),
      recoveryPath: outcome.recoveryPayloadPath,
      sourceRetired: true,
      data: <String, Object?>{
        'planId': plan.planId,
        'writes': true,
        'operation': plan.operation.name,
        'ownership': 'managed',
        'managed': true,
        'target': target.output,
        'root': target.root,
        'form': target.form,
        'transactionId': transactionId,
        'phase': outcome.phase.name,
        'committed': outcome.committed,
        'reconciled': outcome.reconciled,
        'sourceRetired': true,
        'recoveryPath': outcome.recoveryPayloadPath,
      },
      diagnostics: outcome.diagnostics,
    );
  }

  /// Publishes a conversion of an ordinary source.
  Future<AuthoringPublicationOutcome> _publishUntrackedConversion(
    AuthoringPublicationRequest request,
    LifecycleContext context,
    AuthoringPlan plan,
    _Source source,
    _Target target,
    ConversionDirection direction,
  ) async {
    final candidate = _candidateOf(plan);
    final files = _targetFiles(plan, target);
    await _requireNativeNameFree(
      context,
      plan,
      target,
      excludePath: source.path,
    );
    final recovery = _retainRecovery(context, plan, source);
    final transaction = _prepareTransaction(
      context,
      plan,
      target,
      source,
      recoveryPath: recovery,
    );
    final staged = _stageBytes(context, plan, candidate);
    try {
      _verifyStaged(staged, candidate);
      final created = <String>[];
      try {
        if (target.directory != null) {
          _io.createDirectory(target.directory!);
          created.add(target.directory!);
        } else {
          _io.createDirectory(_fileSystem.path.dirname(target.output));
        }
        for (final entry in files.entries) {
          final path = target.directory != null
              ? _fileSystem.path.join(target.directory!, entry.key)
              : target.output;
          _io.createDirectory(_fileSystem.path.dirname(path));
          _io.write(path, entry.value);
          if (target.directory == null) created.add(path);
        }
      } on Exception {
        _removeCreated(created);
        rethrow;
      }
      _verifyPublishedTarget(target, files);
      _markPublished(context, transaction);
      final retired = _retireSource(source, target);
      final receipt = _commitTransaction(
        context,
        plan,
        target,
        source,
        transaction,
      );
      _completeTransaction(context, transaction);
      return AuthoringPublicationOutcome(
        planId: plan.planId,
        operation: plan.operation.name,
        ownership: PublicationOwnership.authorOnly,
        targetPath: target.output,
        receiptId: receipt,
        recoveryPath: recovery,
        sourceRetired: retired,
        data: <String, Object?>{
          'planId': plan.planId,
          'writes': true,
          'operation': plan.operation.name,
          'ownership': 'authorOnly',
          'managed': false,
          'direction': direction,
          'target': target.output,
          'root': target.root,
          'form': target.form,
          'receiptId': receipt,
          'recoveryPath': recovery,
          'sourceRetired': retired,
          'candidateSha256': _digestBytes(candidate),
          ..._provenance(plan, source),
        },
      );
    } finally {
      _removeIfPresent(staged);
    }
  }

  /// Retires the source of a conversion.
  ///
  /// An in-place reclassification replaces the source content; a relocation
  /// removes the verified source entries. The retained recovery copy holds
  /// the original bytes in both cases. An entry outside the reviewed manifest
  /// is never removed: the source stays and the retirement is refused.
  bool _retireSource(_Source source, _Target target) {
    final sourcePath = source.path;
    final inPlace = _fileSystem.path.equals(
      sourcePath,
      target.artifactLocation,
    );
    if (inPlace) {
      // The published content replaced the source in place. A sidecar that
      // the target form does not carry is removed, so the published package
      // holds exactly the reviewed entries.
      final sidecar = target.sidecar;
      if (sidecar == null) {
        final package = target.directory;
        if (package != null) {
          final stale = _fileSystem.path.join(package, 'agents', 'openai.yaml');
          if (_io.type(stale, followLinks: false) ==
              FileSystemEntityType.file) {
            _io.delete(stale);
          }
        }
      }
      return true;
    }
    if (_io.type(sourcePath, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return false;
    }
    if (source.isPackage) {
      final manifest = readPackageManifest(_fileSystem, sourcePath);
      if (manifest.digest != source.membersDigest) {
        // The source carries an entry outside the reviewed manifest. It is
        // not removed: an unreviewed entry is never deleted.
        return false;
      }
      for (final entry in manifest.entries) {
        final relative = entry['path']! as String;
        final path = _fileSystem.path.join(sourcePath, relative);
        if (entry['type'] == 'directory') continue;
        _io.delete(path);
      }
      for (final entry in manifest.entries.reversed) {
        if (entry['type'] != 'directory') continue;
        final path = _fileSystem.path.join(
          sourcePath,
          entry['path']! as String,
        );
        if (_io.type(path, followLinks: false) ==
            FileSystemEntityType.directory) {
          _io.deleteEmptyDirectory(path);
        }
      }
      _io.deleteEmptyDirectory(sourcePath);
      return true;
    }
    _io.delete(sourcePath);
    return true;
  }

  /// The proposed native files of the target.
  Map<String, List<int>> _targetFiles(AuthoringPlan plan, _Target target) {
    final candidate = _candidateOf(plan);
    if (target.directory != null) {
      return <String, List<int>>{
        'SKILL.md': candidate,
        if (plan.sidecar != null)
          'agents/openai.yaml': utf8.encode(plan.sidecar!),
      };
    }
    return <String, List<int>>{
      _fileSystem.path.basename(target.output): candidate,
    };
  }

  /// Verifies the published target against the reviewed proposal.
  void _verifyPublishedTarget(_Target target, Map<String, List<int>> files) {
    for (final entry in files.entries) {
      final path = target.directory != null
          ? _fileSystem.path.join(target.directory!, entry.key)
          : target.output;
      final type = _io.type(path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        throw MambaException(
          'The published native target is missing: $path',
          exitCode: 6,
        );
      }
      final bytes = _io.read(path, maxPackageManifestFileBytes);
      if (_digestBytes(bytes) != _digestBytes(entry.value)) {
        throw MambaException(
          'The published native target does not match the reviewed proposal.',
          exitCode: 6,
        );
      }
    }
  }

  /// The reviewed source of the plan.
  _Source? _sourceOf(AuthoringPlan plan) {
    final source = plan.data['source'];
    if (source is! Map<String, Object?>) return null;
    final path = source['path'];
    if (path is! String || path.isEmpty) return null;
    return _Source(
      path: path,
      markerSha256: source['markerSha256'] as String?,
      membersDigest: source['membersDigest'] as String?,
      installationId: source['installationId'] as String?,
    );
  }

  /// The reviewed target of the plan.
  _Target _targetOf(AuthoringPlan plan) {
    final target = plan.data['target'];
    if (target is! Map<String, Object?>) {
      throw MambaException('The reviewed proposal has no target.', exitCode: 4);
    }
    final output = target['output'];
    if (output is! String || output.isEmpty) {
      throw MambaException(
        'The reviewed proposal has no target location.',
        exitCode: 4,
      );
    }
    final form = target['form'] as String? ?? '';
    final directory = target['directory'] as String?;
    return _Target(
      output: output,
      root: target['root'] as String?,
      form: form,
      sidecar: target['sidecar'] as String?,
      directory: directory,
    );
  }

  /// The proposed native content of the plan.
  List<int> _candidateOf(AuthoringPlan plan) {
    final candidate = plan.candidate;
    if (candidate == null) {
      throw MambaException(
        'The reviewed proposal has no native content.',
        exitCode: 4,
      );
    }
    return utf8.encode(candidate);
  }

  /// Refuses a publication whose source changed after the reviewed plan.
  void _requireSourceUnchanged(_Source source) {
    final path = source.path;
    final markerSha256 = source.markerSha256;
    if (markerSha256 != null) {
      final marker = _markerOf(source);
      final type = _io.type(marker, followLinks: false);
      if (type != FileSystemEntityType.file) {
        throw MambaException(
          'The reviewed source is no longer a readable native definition: '
          '$marker',
          exitCode: 4,
        );
      }
      final bytes = _io.read(marker, maxPackageManifestFileBytes);
      if (_digestBytes(bytes) != markerSha256) {
        throw MambaException(
          'The reviewed source changed since the plan was built.',
          exitCode: 4,
        );
      }
    }
    final membersDigest = source.membersDigest;
    if (membersDigest != null && source.isPackage) {
      final manifest = readPackageManifest(_fileSystem, path);
      if (manifest.digest != membersDigest) {
        throw MambaException(
          'The reviewed source package changed since the plan was built.',
          exitCode: 4,
        );
      }
    }
  }

  /// The reviewed marker file of the source.
  String _markerOf(_Source source) {
    final path = source.path;
    if (!source.isPackage) return path;
    return _fileSystem.path.join(path, 'SKILL.md');
  }

  /// Refuses a publication whose target is occupied.
  void _requireUnoccupied(_Target target) {
    final path = target.artifactLocation;
    final type = skillEntityType(path, followLinks: false, fs: _fileSystem);
    if (type != FileSystemEntityType.notFound) {
      throw MambaException(
        'The target location is occupied; a new output never takes over an '
        'existing entry.',
        exitCode: 4,
      );
    }
  }

  /// Refuses a publication whose target is already owned.
  void _requireUnownedTarget(LifecycleContext context, _Target target) {
    for (final record in _state.records(context)) {
      if (record.lifecycle != 'live') continue;
      if (_fileSystem.path.equals(record.location, target.artifactLocation)) {
        throw MambaException(
          'The target location is already owned by an installation.',
          exitCode: 4,
        );
      }
    }
  }

  /// Refuses a native placement that collides with a visible native name.
  ///
  /// The native uniqueness and shadowing rules apply to an author-only
  /// output as well: a native root is a discovery location. An output
  /// outside a native root carries no installed-name constraint.
  Future<void> _requireNativeNameFree(
    LifecycleContext context,
    AuthoringPlan plan,
    _Target target, {
    String? excludePath,
  }) async {
    final name = _nativeName(plan);
    if (name == null) return;
    switch (plan.kind) {
      case AuthoringKind.agent:
        final harness = agentHarnessForProfile(plan.profile);
        await _agents
            .installationResource(harness)
            .checkUnique(
              context,
              name,
              nativeDestination: AgentDestination.native.name,
              excludePath: excludePath,
            );
      case AuthoringKind.skill:
      case AuthoringKind.prompt:
        final destination = _skillDestination(plan.profile);
        if (destination == null) return;
        await _skills.checkUnique(
          context,
          name,
          nativeDestination: destination.name,
          excludePath: excludePath,
        );
    }
  }

  /// The native name of the proposal.
  String? _nativeName(AuthoringPlan plan) {
    final fields = plan.data['fields'];
    if (fields is! Map<String, Object?>) return null;
    final name = fields['name'];
    if (name is! String) return null;
    final trimmed = name.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Retains a protected recovery copy of the reviewed source.
  ///
  /// The copy is evidence of the previous bytes. It is not an installation
  /// record and it never adopts the source.
  String _retainRecovery(
    LifecycleContext context,
    AuthoringPlan plan,
    _Source source,
  ) {
    final path = source.path;
    final root = _fileSystem.path.join(
      context.stateRoot(),
      'authoring-recovery',
      plan.planId,
    );
    _io.createDirectory(root);
    _state.protectDirectory(root);
    if (source.isPackage) {
      final manifest = readPackageManifest(_fileSystem, path);
      for (final entry in manifest.entries) {
        final relative = entry['path']! as String;
        final from = _fileSystem.path.join(path, relative);
        final to = _fileSystem.path.join(root, relative);
        if (entry['type'] == 'directory') {
          _io.createDirectory(to);
          continue;
        }
        _io.createDirectory(_fileSystem.path.dirname(to));
        _io.copyFile(from, to);
      }
    } else {
      final marker = _markerOf(source);
      _io.copyFile(marker, _fileSystem.path.join(root, 'source'));
    }
    return root;
  }

  /// Stages the proposed content in protected storage.
  String _stageBytes(
    LifecycleContext context,
    AuthoringPlan plan,
    List<int> bytes,
  ) {
    final root = _fileSystem.path.join(
      context.stateRoot(),
      'authoring-staging',
      plan.planId,
    );
    _io.createDirectory(root);
    _state.protectDirectory(root);
    final path = _fileSystem.path.join(root, 'candidate');
    _io.write(path, bytes);
    return path;
  }

  /// Stages the proposed native package in protected storage.
  ///
  /// The staged package holds the reviewed marker, the reviewed sidecar and
  /// the reviewed package members. A member that the proposal replaces is
  /// not copied twice.
  String _stagePackage(
    LifecycleContext context,
    AuthoringPlan plan,
    _Target target, {
    _Source? source,
  }) {
    // The staged package is prepared next to the native root, outside the
    // management storage: the ordinary installation refuses a source that
    // overlaps the management state.
    final root = target.root != null
        ? _fileSystem.path.join(
            _fileSystem.path.dirname(target.root!),
            '.agent-resource-authoring',
            plan.planId,
          )
        : _fileSystem.path.join(
            context.stateRoot(),
            'authoring-staging',
            plan.planId,
          );
    _io.createDirectory(root);
    _state.protectDirectory(root);
    _io.write(_fileSystem.path.join(root, 'SKILL.md'), _candidateOf(plan));
    if (plan.sidecar != null) {
      _io.createDirectory(_fileSystem.path.join(root, 'agents'));
      _io.write(
        _fileSystem.path.join(root, 'agents', 'openai.yaml'),
        utf8.encode(plan.sidecar!),
      );
    }
    if (source != null) {
      _copyPackageMembers(source, root, replacesSidecar: plan.sidecar != null);
    }
    return root;
  }

  /// Copies the reviewed package members into the published package.
  ///
  /// The marker and the sidecar of the proposal are not copied: the
  /// proposal owns them. A member outside the reviewed package is never
  /// copied, so an external dependency is not duplicated.
  void _copyPackageMembers(
    _Source source,
    String destination, {
    required bool replacesSidecar,
  }) {
    final path = source.path;
    final manifest = readPackageManifest(_fileSystem, path);
    final skipped = <String>{
      'SKILL.md',
      if (replacesSidecar) 'agents/openai.yaml',
    };
    for (final entry in manifest.entries) {
      final relative = entry['path']! as String;
      if (skipped.contains(relative)) continue;
      final from = _fileSystem.path.join(path, relative);
      final to = _fileSystem.path.join(destination, relative);
      if (entry['type'] == 'directory') {
        _io.createDirectory(to);
        continue;
      }
      _io.createDirectory(_fileSystem.path.dirname(to));
      _io.copyFile(from, to);
    }
  }

  /// Verifies the staged candidate against the reviewed proposal.
  void _verifyStaged(String staged, List<int> expected) {
    final type = _io.type(staged, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw MambaException('The staged candidate is missing.', exitCode: 6);
    }
    final bytes = _io.read(staged, maxPackageManifestFileBytes);
    if (_digestBytes(bytes) != _digestBytes(expected)) {
      throw MambaException(
        'The staged candidate changed before publication.',
        exitCode: 6,
      );
    }
  }

  /// Verifies the published marker against the reviewed proposal.
  ///
  /// The published bytes are read back from the native location. A target
  /// that does not carry the reviewed content is a failed publication, not a
  /// successful one.
  void _verifyPublishedMarker(_Target target, List<int> expected) {
    final path = target.directory != null
        ? _fileSystem.path.join(target.directory!, 'SKILL.md')
        : target.output;
    final type = _io.type(path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'The published native target is missing: $path',
        exitCode: 6,
      );
    }
    final bytes = _io.read(path, maxPackageManifestFileBytes);
    if (_digestBytes(bytes) != _digestBytes(expected)) {
      throw MambaException(
        'The published native target does not match the reviewed proposal.',
        exitCode: 6,
      );
    }
  }

  /// Removes the entries of a failed publication.
  ///
  /// A cleanup failure never hides the original failure: the partial output
  /// stays visible instead of being reported as a clean state.
  void _removeCreated(List<String> created) {
    for (final path in created.reversed) {
      try {
        _io.delete(path);
      } on Exception {
        // The original failure is reported.
      }
    }
  }

  /// Removes a staged package and its empty staging root.
  ///
  /// The staging root is shared with the ordinary lifecycle staging, so it is
  /// only removed when it is empty.
  void _removeStaged(String staged) {
    _removeIfPresent(staged);
    final parent = _fileSystem.path.dirname(staged);
    if (_fileSystem.path.basename(parent) != '.agent-resource-authoring') {
      return;
    }
    try {
      if (_io.list(parent).isEmpty) _io.deleteEmptyDirectory(parent);
    } on Exception {
      // Another candidate may be preparing concurrently; the shared staging
      // root is never removed recursively.
    }
  }

  /// Removes a staged or retained entry without failing the publication.
  void _removeIfPresent(String path) {
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    try {
      _io.delete(path);
    } on Exception {
      // A retained preparation artifact is not a publication failure. It
      // stays visible for an explicit cleanup.
    }
  }

  /// The live installation that owns the published target.
  String? _installationAt(LifecycleContext context, _Target target) {
    for (final candidate in _state.records(context)) {
      if (candidate.lifecycle != 'live') continue;
      if (_fileSystem.path.equals(
        candidate.location,
        target.artifactLocation,
      )) {
        return candidate.installationId;
      }
    }
    return null;
  }

  /// The managed outcome of a lifecycle publication.
  AuthoringPublicationOutcome _managedOutcome(
    AuthoringPlan plan,
    _Target target,
    LifecycleResult result,
    String kind,
  ) {
    final installationId = result.data['installationId'] as String?;
    final location = result.data['location'] as String?;
    if (location != null &&
        !_fileSystem.path.equals(location, target.artifactLocation)) {
      throw MambaException(
        'The managed publication published an unexpected location: $location',
        exitCode: 6,
      );
    }
    return AuthoringPublicationOutcome(
      planId: plan.planId,
      operation: plan.operation.name,
      ownership: PublicationOwnership.managed,
      targetPath: target.output,
      installationId: installationId,
      data: <String, Object?>{
        'planId': plan.planId,
        'writes': true,
        'operation': plan.operation.name,
        'ownership': 'managed',
        'managed': true,
        'kind': kind,
        'target': target.output,
        'root': target.root,
        'form': target.form,
        'installationId': installationId,
        'lifecycleOutcome': result.outcome,
      },
      diagnostics: result.diagnostics,
    );
  }

  /// The native form of the conversion target.
  _ConversionTarget _conversionTarget(AuthoringPlan plan, _Target target) {
    if (plan.kind == AuthoringKind.agent) {
      final harness = agentHarnessForProfile(plan.profile);
      return _ConversionTarget(
        artifactKind: 'agent-file',
        nativeForm: '${harness.name}-agent-file',
        nativeProfile: harness.name,
        nativeDestination: AgentDestination.native.name,
      );
    }
    if (target.form == 'prompt-template') {
      return const _ConversionTarget(
        artifactKind: 'prompt-template',
        nativeForm: 'prompt-template',
        nativeProfile: 'pi',
        nativeDestination: 'pi',
      );
    }
    final destination = _skillDestination(plan.profile);
    return _ConversionTarget(
      artifactKind: 'skill-copy',
      nativeForm: 'skill-copy',
      nativeProfile: plan.profile == AuthoringProfile.global
          ? null
          : plan.profile.name,
      nativeDestination: destination?.name ?? 'shared',
    );
  }

  /// The managed Skill destination of a profile.
  SkillDestination? _skillDestination(AuthoringProfile profile) =>
      switch (profile) {
        AuthoringProfile.claude => SkillDestination.claude,
        AuthoringProfile.codex => SkillDestination.codex,
        AuthoringProfile.global => SkillDestination.shared,
        AuthoringProfile.pi => null,
      };

  /// The Agent harness of a profile.
  AgentHarness _harness(AuthoringProfile profile) =>
      agentHarnessForProfile(profile);

  /// The honest provenance of a derived output.
  ///
  /// A derived output keeps the evidence of the source it was derived from.
  /// It never inherits the pack membership or the upstream update tracking
  /// of its source, and it never claims a verified origin.
  Map<String, Object?> _provenance(AuthoringPlan plan, _Source? source) {
    if (source == null) {
      return const <String, Object?>{
        'derivedFrom': null,
        'inheritedTracking': false,
        'packMembership': null,
      };
    }
    return <String, Object?>{
      'derivedFrom': source.path,
      'sourceInstallationId': source.installationId,
      'inheritedTracking': false,
      'packMembership': null,
      'originStatus': 'unknown',
    };
  }

  /// The authoring receipt of an unmanaged output.
  ///
  /// The receipt is persisted as a protected document next to the other
  /// management evidence. It records the authoring act, the published
  /// location and the honest provenance of the output. It is not an
  /// installation record: it never adopts a source and it never binds an
  /// update source.
  /// Records the prepared transaction of one ordinary publication.
  ///
  /// The transaction is the authority of an interrupted publication. It is
  /// written before the live change, so a publication that stops between the
  /// preparation and the commit stays reviewable and recoverable.
  AuthoringTransaction _prepareTransaction(
    LifecycleContext context,
    AuthoringPlan plan,
    _Target target,
    _Source? source, {
    String? recoveryPath,
  }) {
    final transaction = AuthoringTransaction(
      transactionId: _recovery.newTransactionId(),
      planId: plan.planId,
      operation: plan.operation.name,
      kind: plan.kind.name,
      profile: plan.profile.name,
      ownership: PublicationOwnership.authorOnly.name,
      phase: AuthoringTransactionPhase.prepared,
      target: target.artifactLocation,
      source: source?.path,
      sourceSha256: source?.markerSha256,
      recoveryPath: recoveryPath,
      receiptId: authoringReceiptId(plan.planId, target.output),
      candidateSha256: _digestBytes(_candidateOf(plan)),
      observations: <String, Object?>{
        if (recoveryPath != null)
          'payloadMembers': <String>[
            for (final entry in _io.list(recoveryPath))
              _fileSystem.path.basename(entry.path),
          ],
      },
    );
    _recovery.persist(context.stateRoot(), transaction);
    return transaction;
  }

  /// Records the published phase of one ordinary publication.
  void _markPublished(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) {
    _recovery.persist(
      context.stateRoot(),
      transaction.copyWith(phase: AuthoringTransactionPhase.published),
    );
  }

  /// Writes the authoring receipt and records the committed phase.
  ///
  /// The receipt is the commit point of an ordinary publication: it is the
  /// evidence of the authoring act. The transaction is committed with it.
  String _commitTransaction(
    LifecycleContext context,
    AuthoringPlan plan,
    _Target target,
    _Source? source,
    AuthoringTransaction transaction,
  ) {
    final receiptId = authoringReceiptId(plan.planId, target.output);
    writeAuthoringReceipt(
      state: _state,
      stateRoot: context.stateRoot(),
      document: authoringReceiptDocument(
        receiptId: receiptId,
        planId: plan.planId,
        operation: plan.operation.name,
        kind: plan.kind.name,
        profile: plan.profile.name,
        target: target.output,
        root: target.root,
        form: target.form,
        derivedFrom: source?.path,
        sourceInstallationId: source?.installationId,
      ),
    );
    _recovery.persist(
      context.stateRoot(),
      transaction.copyWith(
        phase: AuthoringTransactionPhase.committed,
        receiptId: receiptId,
      ),
    );
    return receiptId;
  }

  /// Records the completed phase of one ordinary publication.
  void _completeTransaction(
    LifecycleContext context,
    AuthoringTransaction transaction,
  ) {
    _recovery.persist(
      context.stateRoot(),
      transaction.copyWith(phase: AuthoringTransactionPhase.completed),
    );
  }

  /// A new coordinated transaction identifier.
  String _newTransactionId() => _evidence.newTransactionId();
}

/// The reviewed target of one publication.
final class _Target {
  const _Target({
    required this.output,
    required this.root,
    required this.form,
    required this.sidecar,
    required this.directory,
  });

  /// The proposed native marker or file.
  final String output;

  /// The native root of the placement, when the placement is a native one.
  final String? root;

  /// The native form of the placement.
  final String form;

  /// The proposed native sidecar of a package.
  final String? sidecar;

  /// The package directory of a package placement.
  final String? directory;

  /// The published artifact location.
  String get artifactLocation => directory ?? output;
}

/// The reviewed source of one publication.
final class _Source {
  const _Source({
    required this.path,
    this.markerSha256,
    this.membersDigest,
    this.installationId,
  });

  /// The location of the reviewed source.
  final String path;

  /// The digest of the reviewed marker.
  final String? markerSha256;

  /// The digest of the reviewed package members.
  final String? membersDigest;

  /// The managed installation of a tracked source.
  final String? installationId;

  /// Whether the source is a native package.
  bool get isPackage => membersDigest != null;
}

/// The native form of a conversion target.
final class _ConversionTarget {
  const _ConversionTarget({
    required this.artifactKind,
    required this.nativeForm,
    required this.nativeProfile,
    required this.nativeDestination,
  });

  final String artifactKind;
  final String nativeForm;
  final String? nativeProfile;
  final String nativeDestination;
}

/// The digest of the reviewed bytes.
String _digestBytes(List<int> bytes) => sha256.convert(bytes).toString();
