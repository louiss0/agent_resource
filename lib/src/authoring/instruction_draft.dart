import 'dart:math';

import 'package:mamba/mamba.dart';

import '../services/authoring_plan_service.dart' show AuthoringPlan;
import '../services/lifecycle_state_service.dart'
    show LifecycleContext, LifecycleScope;
import 'authoring_inputs.dart';

/// The pattern of an instruction draft identifier.
///
/// A draft identity is opaque and narrow: it selects one application-owned
/// draft directory and never an arbitrary filesystem path.
final RegExp instructionDraftIdPattern = RegExp(r'^drf_[a-f0-9]{32}$');

/// Whether the value is an instruction draft identifier.
bool isInstructionDraftId(String value) =>
    instructionDraftIdPattern.hasMatch(value);

/// A new instruction draft identifier.
String newInstructionDraftId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return 'drf_${bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join()}';
}

/// Where the instructions of one draft came from.
///
/// The origin is recorded as metadata. The original input is never a cleanup
/// target: a draft never deletes the file the operator supplied.
enum InstructionDraftBodyOrigin { file, standardInput, literal }

/// The reconstructible authoring intent of one retained draft.
///
/// The intent is the safe part of an authoring request: the operation, the
/// native selectors and the declared native fields. It carries no plan
/// identity, no publication approval and no consent of any kind, so a resume
/// rebuilds the plan from the current observations instead of replaying an
/// old decision.
final class InstructionDraftIntent {
  const InstructionDraftIntent({
    required this.operation,
    required this.kind,
    required this.profile,
    required this.scope,
    required this.sourcePath,
    required this.installationId,
    required this.sourceProfile,
    required this.fields,
    required this.manage,
    required this.composition,
    required this.conversion,
    required this.output,
    required this.decisions,
    required this.references,
  });

  /// The intent of the selected authoring inputs.
  ///
  /// The selected paths are captured as normalized absolute paths against
  /// the context of the preparation. A resume from another working directory
  /// observes the same source and the same output instead of silently
  /// reinterpreting a relative path as another resource.
  factory InstructionDraftIntent.from(
    AuthoringInputs inputs, {
    LifecycleContext? context,
  }) => InstructionDraftIntent(
    operation: inputs.operation,
    kind: inputs.kind,
    profile: inputs.profile,
    scope: inputs.scope,
    sourcePath: _absolute(inputs.source.path, context),
    installationId: inputs.source.installationId,
    sourceProfile: inputs.source.profile,
    fields: Map<String, AuthoringFieldValue>.unmodifiable(inputs.fields),
    manage: inputs.manage,
    composition: inputs.composition,
    conversion: inputs.conversion,
    output: _absolute(inputs.output, context),
    decisions: Set<String>.unmodifiable(inputs.decisions),
    references: Map<String, String>.unmodifiable(inputs.references),
  );

  /// The normalized absolute form of one selected path.
  ///
  /// A retained draft never reinterprets a relative path against another
  /// working directory: the path of the preparation is the path of the
  /// resume.
  static String? _absolute(String? path, LifecycleContext? context) {
    if (path == null) return null;
    return context == null ? path : context.resolvePath(path);
  }

  /// The authoring operation the draft belongs to.
  final AuthoringOperation operation;

  /// The native resource kind of the draft.
  final AuthoringKind kind;

  /// The native profile of the draft.
  final AuthoringProfile profile;

  /// The lifecycle scope the draft belongs to.
  final LifecycleScope scope;

  /// The selected source path, when the source was selected by path.
  final String? sourcePath;

  /// The selected installation identifier, when the source was selected by
  /// installation.
  final String? installationId;

  /// The native profile of the selected source.
  final AuthoringProfile? sourceProfile;

  /// The declared native field values.
  final Map<String, AuthoringFieldValue> fields;

  /// The explicit request for a managed installation record.
  ///
  /// The request is an authoring intent, never a publication approval: the
  /// fresh plan of a resume states the resulting ownership and the
  /// publication still requires the caller's own explicit confirmation.
  final bool manage;

  /// The composition mode of a compose operation.
  final CompositionMode? composition;

  /// The conversion direction of a convert operation.
  final ConversionDirection? conversion;

  /// The explicit output override of the request.
  final String? output;

  /// The recorded field-specific and reference-specific decisions.
  final Set<String> decisions;

  /// The per-reference mappings of the request.
  final Map<String, String> references;

  /// The inputs that rebuild the intent with the current instructions.
  ///
  /// A clone and a conversion preserve the instructions of their source, so
  /// they never carry a drafted body.
  AuthoringInputs toInputs({String? bodyText}) {
    if (bodyText != null &&
        (operation == AuthoringOperation.clone ||
            operation == AuthoringOperation.convert)) {
      throw MambaException(
        'A clone or a conversion preserves the instructions of its source; '
        'it does not carry a drafted body.',
        exitCode: 4,
      );
    }
    return AuthoringInputs(
      operation: operation,
      kind: kind,
      profile: profile,
      scope: scope,
      source: AuthoringSourceSelection(
        path: sourcePath,
        installationId: installationId,
        profile: sourceProfile,
      ),
      body: bodyText == null
          ? null
          : AuthoringBodySelection(kind: BodyInputKind.literal, text: bodyText),
      fields: Map<String, AuthoringFieldValue>.unmodifiable(fields),
      manage: manage,
      composition: composition,
      output: output,
      decisions: Set<String>.unmodifiable(decisions),
      references: Map<String, String>.unmodifiable(references),
      conversion: conversion,
    );
  }
}

/// The retained metadata of one instruction draft.
///
/// The metadata never carries the instruction body. It reports the intent,
/// the origin of the body, the digest of the prepared snapshot and the
/// location of the private storage.
final class InstructionDraft {
  const InstructionDraft({
    required this.draftId,
    required this.intent,
    required this.bodyOrigin,
    required this.bodySha256,
    required this.bodyByteLength,
    required this.path,
    required this.metadataSha256,
    required this.createdAt,
    this.bodySourcePath,
    this.hasWorkingCopy = false,
  });

  /// The opaque identity of the draft.
  final String draftId;

  /// The reconstructible intent of the draft.
  final InstructionDraftIntent intent;

  /// The origin of the drafted instructions.
  final InstructionDraftBodyOrigin bodyOrigin;

  /// The digest of the prepared instruction snapshot.
  final String bodySha256;

  /// The byte length of the prepared instruction snapshot.
  final int bodyByteLength;

  /// The original input the instructions came from, when they came from a
  /// file. The original input is never modified and never removed.
  final String? bodySourcePath;

  /// The private directory that holds the draft.
  final String path;

  /// The digest of the metadata document.
  final String metadataSha256;

  /// The creation time of the draft.
  final String createdAt;

  /// Whether an editable working copy exists beside the snapshot.
  final bool hasWorkingCopy;
}

/// The listed summary of one retained instruction draft.
///
/// A summary is metadata only: it never carries the instruction body.
final class InstructionDraftSummary {
  const InstructionDraftSummary({
    required this.draftId,
    required this.operation,
    required this.kind,
    required this.profile,
    required this.scope,
    required this.bodyOrigin,
    required this.bodyByteLength,
    required this.bodySha256,
    required this.resolved,
    this.reason,
    this.hasWorkingCopy = false,
  });

  /// A summary of an entry that could not be resolved.
  ///
  /// The unresolved entry keeps its place in the inventory instead of
  /// disappearing from it.
  const InstructionDraftSummary.unresolved(this.draftId, this.reason)
    : operation = null,
      kind = null,
      profile = null,
      scope = null,
      bodyOrigin = null,
      bodyByteLength = null,
      bodySha256 = null,
      resolved = false,
      hasWorkingCopy = false;

  /// The identity of the draft.
  final String draftId;

  /// The authoring operation of the draft.
  final String? operation;

  /// The native resource kind of the draft.
  final String? kind;

  /// The native profile of the draft.
  final String? profile;

  /// The lifecycle scope of the draft.
  final String? scope;

  /// The origin of the drafted instructions.
  final InstructionDraftBodyOrigin? bodyOrigin;

  /// The byte length of the prepared instruction snapshot.
  final int? bodyByteLength;

  /// The digest of the prepared instruction snapshot.
  final String? bodySha256;

  /// Whether the metadata of the draft could be read.
  final bool resolved;

  /// The reason an unresolved draft could not be read.
  final String? reason;

  /// Whether an editable working copy exists beside the snapshot.
  final bool hasWorkingCopy;
}

/// The instructions of one draft as they are read.
///
/// The value is the effective body: the editable working copy when it exists
/// and the prepared snapshot otherwise.
final class InstructionDraftBody {
  const InstructionDraftBody({
    required this.text,
    required this.sha256,
    required this.byteLength,
    required this.origin,
    required this.edited,
    this.sourcePath,
  });

  /// The instruction text.
  final String text;

  /// The digest of the read bytes.
  final String sha256;

  /// The byte length of the read bytes.
  final int byteLength;

  /// The origin of the drafted instructions.
  final InstructionDraftBodyOrigin origin;

  /// Whether the read content differs from the prepared snapshot.
  final bool edited;

  /// The original input the instructions came from, when they came from a
  /// file.
  final String? sourcePath;
}

/// The result of resuming one retained draft.
///
/// The resume rebuilds the plan from the current observations. It never
/// replays an old plan identity and it never carries an approval.
final class InstructionDraftResume {
  const InstructionDraftResume({
    required this.draft,
    required this.body,
    required this.inputs,
    required this.plan,
  });

  /// The retained draft.
  final InstructionDraft draft;

  /// The current instructions of the draft.
  final InstructionDraftBody body;

  /// The rebuilt authoring inputs.
  final AuthoringInputs inputs;

  /// The fresh plan of the rebuilt inputs.
  final AuthoringPlan plan;
}

/// The result of removing one retained draft.
///
/// A cleanup reports its own failure instead of throwing, so a cleanup
/// problem never hides the evidence of a published output.
final class InstructionDraftCleanup {
  const InstructionDraftCleanup({
    required this.draftId,
    required this.cleaned,
    this.reason,
  });

  /// The identity of the draft.
  final String draftId;

  /// Whether the draft was removed.
  final bool cleaned;

  /// The reason the draft was not removed.
  final String? reason;
}
