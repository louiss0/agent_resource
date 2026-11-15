import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../../components/guided_value.dart';
import '../../components/installation_approval.dart';
import '../authoring/authoring_inputs.dart';
import 'authoring_plan_service.dart';
import 'authoring_publication_service.dart';
import 'editor_interaction_service.dart';
import 'instruction_draft_service.dart';
import 'lifecycle_state_service.dart';

/// The default question that collects one native field value.
Future<String?> defaultGuidedValue(String label) =>
    GuidedValueComponent(label: label).render();

/// The default question that confirms the publication.
Future<bool> defaultGuidedConfirmation(String summary) =>
    InstallationApprovalComponent(label: summary).render();

/// The number of correction rounds one guided run attempts.
///
/// The bound keeps a guided session finite: a proposal that does not become
/// ready is refused instead of asking the operator forever.
const int maxGuidedCorrectionAttempts = 3;

/// The question that asks the operator for one native field value.
///
/// A null answer cancels the guided session.
typedef GuidedValueRequest = Future<String?> Function(String label);

/// The question that asks the operator to confirm the publication.
typedef GuidedConfirmationRequest = Future<bool> Function(String summary);

/// One guided create run.
///
/// The request carries the named native inputs of the run. It never carries a
/// proposal: the reviewed plan is the only source of the published content.
final class GuidedAuthoringRequest {
  const GuidedAuthoringRequest({
    required this.command,
    required this.inputs,
    this.apply = false,
    this.planId,
    this.interactive = false,
    this.editorChoice,
    this.showInstructions = false,
  });

  /// The canonical name of the command that owns the run.
  final String command;

  /// The named native inputs of the run.
  final AuthoringInputs inputs;

  /// Whether the reviewed proposal is published.
  final bool apply;

  /// The reviewed plan identity that the caller expects.
  ///
  /// A stale identity is refused before any effect.
  final String? planId;

  /// Whether the run may ask the operator a question.
  ///
  /// An unattended run never prompts and never waits.
  final bool interactive;

  /// The explicit editor command of an editor-led run.
  final String? editorChoice;

  /// Whether the private instruction text is disclosed.
  final bool showInstructions;
}

/// The result of one guided create run.
///
/// The outcome is `planned` for a read-only review, `published` for a
/// successful publication and `rejected` for a proposal that is not ready.
/// A rejection is a refusal of the invocation, not a successful report.
final class GuidedAuthoringOutcome {
  const GuidedAuthoringOutcome({
    required this.command,
    required this.outcome,
    required this.data,
    required this.diagnostics,
  });

  final String command;
  final String outcome;
  final Map<String, Object?> data;
  final List<Map<String, Object?>> diagnostics;

  bool get rejected => outcome == 'rejected';
}

/// Runs the guided create flow for Skills, Agents and Prompts.
///
/// The service owns the order of the flow: it resolves the instruction body,
/// prepares and edits the protected draft, plans the proposal, collects the
/// missing native fields, reviews the target and the ownership, confirms the
/// publication and publishes the reviewed plan.
///
/// The service never adopts a source, never changes a parent configuration
/// and never executes a harness.
interface class GuidedAuthoringService {
  factory GuidedAuthoringService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    AuthoringPlanService? plans,
    AuthoringPublicationService? publication,
    InstructionDraftService? drafts,
    EditorInteractionService? editor,
    Future<String> Function()? standardInput,
    GuidedValueRequest? ask,
    GuidedConfirmationRequest? confirm,
    bool Function()? terminal,
  }) {
    final io = LifecycleIO(fs: fileSystem);
    final state = LifecycleStateService(io: io);
    final draftService =
        drafts ??
        InstructionDraftService(
          fileSystem: fileSystem,
          state: state,
          standardInput: standardInput,
        );
    final planService =
        plans ?? AuthoringPlanService(fileSystem: fileSystem, state: state);
    final editorService =
        editor ??
        EditorInteractionService(drafts: draftService, fileSystem: fileSystem);
    return GuidedAuthoringService._(
      planService,
      publication ?? AuthoringPublicationService(fileSystem: fileSystem),
      draftService,
      editorService,
      ask ?? defaultGuidedValue,
      confirm ?? defaultGuidedConfirmation,
      fileSystem,
      terminal,
    );
  }

  GuidedAuthoringService._(
    this._plans,
    this._publication,
    this._drafts,
    this._editor,
    this._ask,
    this._confirm,
    this._fileSystem,
    this._terminal,
  );

  final AuthoringPlanService _plans;
  final AuthoringPublicationService _publication;
  final InstructionDraftService _drafts;
  final EditorInteractionService _editor;
  final GuidedValueRequest? _ask;
  final GuidedConfirmationRequest? _confirm;
  final fslib.FileSystem _fileSystem;
  final bool Function()? _terminal;

  /// The file system of the guided flow.
  fslib.FileSystem get fileSystem => _fileSystem;

  /// Whether the session of the process has a usable terminal.
  ///
  /// The capability decides whether the guided flow may ask a question. It
  /// is injected so a test can state the capability of the session instead
  /// of depending on the terminal of the test runner.
  bool get hasTerminal => _terminal?.call() ?? _processHasTerminal();

  /// The question that collects a native field value.
  ///
  /// A null question means that the guided flow cannot ask: the run is
  /// refused instead of waiting for an answer that never comes.
  GuidedValueRequest? get valueQuestion => _ask;

  /// The question that confirms the publication.
  GuidedConfirmationRequest? get confirmation => _confirm;

  /// Runs the guided flow.
  ///
  /// A dry run plans and nothing else: it never prepares a draft, never
  /// launches an editor and never publishes. An unattended run never asks a
  /// question: every required value must be supplied explicitly.
  Future<GuidedAuthoringOutcome> run(
    GuidedAuthoringRequest request,
    LifecycleOptions options,
  ) async {
    var inputs = request.inputs;
    String? draftId;
    String? draftPath;

    if (options.dryRun) {
      if (inputs.body == null) {
        throw MambaException(
          'A dry run requires an explicit instruction body: --body-file, '
          '--body-stdin or --body-text.',
          exitCode: 4,
        );
      }
      final body = await _drafts.resolveBody(options, inputs.body!);
      inputs = inputs.copyWith(
        body: AuthoringBodySelection(
          kind: BodyInputKind.literal,
          text: body.text,
        ),
      );
      final plan = await _plans.plan(
        inputs,
        options,
        showInstructions: request.showInstructions,
      );
      return _outcome(request, plan, published: false);
    }

    if (inputs.body != null) {
      // An explicit body is used as it was supplied. The guided flow never
      // opens an editor for it, so an unattended run stays unattended.
      final body = await _drafts.resolveBody(options, inputs.body!);
      inputs = inputs.copyWith(
        body: AuthoringBodySelection(
          kind: BodyInputKind.literal,
          text: body.text,
        ),
      );
    } else {
      if (!request.interactive) {
        throw MambaException(
          'A create operation requires an instruction body: supply '
          '--body-file, --body-stdin or --body-text.',
          exitCode: 4,
        );
      }
      final draft = await _drafts.prepare(
        options,
        inputs,
        body: const AuthoringBodySelection(
          kind: BodyInputKind.literal,
          text: '',
        ),
      );
      draftId = draft.draftId;
      draftPath = draft.path;
      final outcome = await _editor.edit(
        options,
        draft.draftId,
        editorChoice: request.editorChoice,
      );
      switch (outcome) {
        case EditorEditCompleted(:final body):
          inputs = inputs.copyWith(
            body: AuthoringBodySelection(
              kind: BodyInputKind.literal,
              text: body.text,
            ),
          );
        case EditorEditBodyFile(:final path):
          inputs = inputs.copyWith(
            body: AuthoringBodySelection(
              kind: BodyInputKind.file,
              filePath: path,
            ),
          );
        case EditorEditCancelled(:final reason):
          throw MambaException(
            'The authoring session was cancelled; the retained draft is at '
            '$draftPath. $reason',
            exitCode: 7,
          );
        case EditorEditNotFinished(:final reason):
          throw MambaException(
            'The editing did not finish; the retained draft is at $draftPath. '
            '$reason',
            exitCode: 7,
          );
      }
    }

    final collected = await _collectAndPlan(
      request,
      options,
      inputs,
      draftPath: draftPath,
    );
    final reviewed = collected.plan;
    if (reviewed == null) {
      return collected.rejection!;
    }
    final requested = request.planId;
    if (requested != null && requested != reviewed.planId) {
      throw MambaException(
        'The supplied plan ID is stale; the current proposal is '
        '${reviewed.planId}.',
        exitCode: 4,
      );
    }
    if (!request.apply) {
      return _outcome(request, reviewed, published: false);
    }

    var publicationOptions = options;
    if (request.interactive && !options.approved) {
      final confirmed = await _askForConfirmation(_reviewSummary(reviewed));
      if (!confirmed) {
        throw MambaException(
          'The publication was cancelled; no output was written.'
          '${draftPath == null ? '' : ' The retained draft is at $draftPath.'}',
          exitCode: 7,
        );
      }
      publicationOptions = options.copyWith(approved: true);
    } else if (!options.approved) {
      throw MambaException(
        'Publication requires --yes in an unattended session.',
        exitCode: 4,
      );
    }

    final published = await _publication.publish(
      AuthoringPublicationRequest(
        plan: reviewed,
        options: publicationOptions,
        planId: reviewed.planId,
        approved: true,
      ),
    );
    var cleaned = false;
    String? cleanupFailure;
    if (draftId != null) {
      final cleanup = await _drafts.cleanupOwned(publicationOptions, draftId);
      cleaned = cleanup.cleaned;
      cleanupFailure = cleanup.reason;
    }
    return GuidedAuthoringOutcome(
      command: request.command,
      outcome: 'published',
      data: <String, Object?>{
        ...reviewed.data,
        ...published.data,
        'published': true,
        'draftRetained': draftId != null && !cleaned,
        'draftCleaned': cleaned,
        'draftCleanupFailure': ?cleanupFailure,
      },
      diagnostics: <Map<String, Object?>>[
        ...reviewed.diagnostics,
        ...published.diagnostics,
      ],
    );
  }

  /// Plans the proposal and collects the missing native fields.
  ///
  /// The correction loop is bounded. A cancelled session and an exhausted
  /// loop both retain the draft and report its location.
  Future<_CollectedPlan> _collectAndPlan(
    GuidedAuthoringRequest request,
    LifecycleOptions options,
    AuthoringInputs inputs, {
    required String? draftPath,
  }) async {
    var working = inputs;
    var attempts = 0;
    while (true) {
      final plan = await _plans.plan(
        working,
        options,
        showInstructions: request.showInstructions,
      );
      if (plan.ready) {
        return _CollectedPlan(plan: plan);
      }
      final missing = _missingFields(plan);
      if (!request.interactive || missing.isEmpty) {
        return _CollectedPlan(
          rejection: _outcome(request, plan, published: false),
        );
      }
      if (attempts >= maxGuidedCorrectionAttempts) {
        throw MambaException(
          'The proposal did not become ready after $attempts correction '
          'attempts.${draftPath == null ? '' : ' The retained draft is at $draftPath.'}',
          exitCode: 4,
        );
      }
      final corrected = await _collectFields(working, missing);
      if (corrected == null) {
        throw MambaException(
          'The authoring session was cancelled.'
          '${draftPath == null ? '' : ' The retained draft is at $draftPath.'}',
          exitCode: 7,
        );
      }
      working = corrected;
      attempts++;
    }
  }

  /// The required native fields that the proposal is missing.
  List<String> _missingFields(AuthoringPlan plan) {
    final names = <String>{};
    for (final diagnostic in plan.diagnostics) {
      if (diagnostic['code'] != 'FIELD_REQUIRED') continue;
      final field = diagnostic['field'];
      if (field is String) names.add(field);
    }
    return names.toList()..sort();
  }

  /// Asks the operator for the missing native fields.
  ///
  /// A null answer cancels the session. A blank answer keeps the field
  /// missing, so the next round of the bounded loop asks again.
  Future<AuthoringInputs?> _collectFields(
    AuthoringInputs inputs,
    List<String> missing,
  ) async {
    final ask = _ask;
    if (ask == null) return null;
    final fields = <String, AuthoringFieldValue>{...inputs.fields};
    var changed = false;
    for (final name in missing) {
      final spec = inputs.matrix.specFor(name);
      final label = spec == null
          ? name
          : '${spec.name}: ${spec.description.isEmpty ? 'the native value' : spec.description}';
      final answer = await ask(label);
      if (answer == null) return null;
      final value = answer.trim();
      if (value.isEmpty) continue;
      fields[name] = switch (spec?.valueKind) {
        NativeFieldValueKind.list => ListFieldValue(
          value
              .split(',')
              .map((entry) => entry.trim())
              .where((entry) => entry.isNotEmpty)
              .toList(),
        ),
        _ => TextFieldValue(value),
      };
      changed = true;
    }
    if (!changed) return null;
    return inputs.copyWith(fields: fields);
  }

  /// Asks the operator to confirm the publication.
  Future<bool> _askForConfirmation(String summary) async {
    final confirm = _confirm;
    if (confirm == null) return false;
    return confirm(summary);
  }

  /// The review that the operator confirms.
  ///
  /// The review names the target, the ownership and the declared changes. It
  /// never carries the instruction text unless the caller disclosed it.
  String _reviewSummary(AuthoringPlan plan) {
    final target = plan.data['target'] as Map<String, Object?>?;
    final fields = plan.data['fields'] as Map<String, Object?>?;
    final body = plan.data['body'] as Map<String, Object?>?;
    final lines = <String>[
      'Publish the reviewed ${plan.kind.name} proposal?',
      '  target: ${target?['output']}',
      '  ownership: ${plan.ownership.name}',
      '  fields: ${fields == null || fields.isEmpty ? 'none' : (fields.keys.toList()..sort()).join(', ')}',
      '  instructions: ${body?['byteLength'] ?? 0} bytes',
    ];
    return lines.join('\n');
  }

  GuidedAuthoringOutcome _outcome(
    GuidedAuthoringRequest request,
    AuthoringPlan plan, {
    required bool published,
  }) => GuidedAuthoringOutcome(
    command: request.command,
    outcome: plan.ready ? 'planned' : 'rejected',
    data: <String, Object?>{
      ...plan.data,
      'published': published,
      'review': _reviewSummary(plan),
    },
    diagnostics: plan.diagnostics,
  );
}

/// Whether the session of the process has a usable terminal.
bool _processHasTerminal() {
  try {
    return stdin.hasTerminal && stdout.hasTerminal;
  } on Exception {
    return false;
  }
}

/// The JSON encoding of one guided outcome.
String encodeGuidedOutcome(GuidedAuthoringOutcome outcome) =>
    jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'command': outcome.command,
      'outcome': outcome.outcome,
      'data': outcome.data,
      'diagnostics': outcome.diagnostics,
    });

/// The result of the planning round of a guided run.
///
/// The plan is present when the proposal is ready. The rejection is present
/// when the proposal is not ready and the run cannot correct it.
final class _CollectedPlan {
  const _CollectedPlan({this.plan, this.rejection});

  final AuthoringPlan? plan;
  final GuidedAuthoringOutcome? rejection;
}
