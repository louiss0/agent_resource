import 'dart:convert';
import 'dart:io' show FileSystemEntityType, stdin, stdout;

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../../components/context_template_selector.dart';
import '../../components/guided_value.dart';
import '../../components/installation_approval.dart';
import '../authoring/authoring_inputs.dart';
import '../authoring/authoring_receipt.dart';
import '../context/context_authoring_plan.dart';
import '../context/context_types.dart';
import 'context_template_service.dart';
import 'editor_interaction_service.dart';
import 'instruction_draft_service.dart';
import 'lifecycle_state_service.dart';

/// Collects a missing template name. A null answer cancels the prompt.
typedef ContextTemplateAsk = Future<String?> Function(String label);

/// Selects one name from the stored templates. A null answer cancels.
typedef ContextTemplateSelect = Future<String?> Function(List<String> options);

/// Approves one reviewed publication.
typedef ContextTemplateConfirm = Future<bool> Function(String summary);

/// One external request to create or edit a context template.
final class const ContextAuthoringRequest({
  required final String command,
  required final bool create,
  required final String? positionalName,
  required final String? optionName,
  required final bool interactive,
  required final bool unattended,
  required final bool empty,
  required final String? bodyFile,
  required final bool bodyStdin,
  required final String? bodyText,
  final String? standardInput,
  final String? editorChoice,
  final String? planId,
  required final bool apply,
  required final bool yes,
  required final bool dryRun,
  required final bool showInstructions,
  required final LifecycleOptions options,
});

/// The dedicated authoring adapter for user-scope context templates.
///
/// It reuses the protected draft, editor, recovery and receipt machinery
/// without extending the native `AuthoringKind` enum. It owns the context
/// plan identity, the template target and the publication discipline.
interface class ContextTemplateAuthoringService {
  factory ContextTemplateAuthoringService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    ContextTemplateService? templates,
    InstructionDraftService? drafts,
    EditorInteractionService? editor,
    ContextTemplateAsk? ask,
    ContextTemplateSelect? select,
    ContextTemplateConfirm? confirm,
    bool Function()? terminal,
    LifecycleIO? io,
  }) {
    final lifecycleIO = io ?? LifecycleIO(fs: fileSystem);
    final state = LifecycleStateService(io: lifecycleIO);
    final draftService =
        drafts ??
        InstructionDraftService(
          fileSystem: fileSystem,
          state: state,
          privacy: (_) {},
          verifier: (_) {},
        );
    return ContextTemplateAuthoringService._(
      fileSystem,
      lifecycleIO,
      state,
      templates ?? ContextTemplateService(fileSystem: fileSystem),
      draftService,
      editor ??
          EditorInteractionService(
            drafts: draftService,
            fileSystem: fileSystem,
          ),
      ask ?? ((label) async => GuidedValueComponent(label: label).render()),
      select ??
          ((options) async =>
              ContextTemplateSelectorComponent(options: options).render()),
      confirm ??
          ((summary) async =>
              InstallationApprovalComponent(label: summary).render()),
      terminal ?? _processHasTerminal,
    );
  }

  ContextTemplateAuthoringService._(
    this._fileSystem,
    this._io,
    this._state,
    this._templates,
    this._drafts,
    this._editor,
    this._ask,
    this._select,
    this._confirm,
    this._terminal,
  );

  final fslib.FileSystem _fileSystem;
  final LifecycleIO _io;
  final LifecycleStateService _state;
  final ContextTemplateService _templates;
  final InstructionDraftService _drafts;
  final EditorInteractionService _editor;
  final ContextTemplateAsk _ask;
  final ContextTemplateSelect _select;
  final ContextTemplateConfirm _confirm;
  final bool Function() _terminal;

  /// The file system shared with the composition root.
  fslib.FileSystem get fileSystem => _fileSystem;

  /// Whether this session can drive a line prompt or an editor.
  bool get hasTerminal => _terminal();

  /// Runs one authoring request and returns its house envelope payload.
  ///
  /// Publication checks the reviewed target again after approval and before
  /// writing recovery or staging files. This detects observed drift, not
  /// changes by a writer racing between that check and publication.
  Future<LifecycleResult> run(ContextAuthoringRequest request) async {
    final name = await _resolveName(request);
    if (!isValidContextTemplateName(name)) {
      throw _refuse(
        'INVALID_TEMPLATE_NAME',
        'Context template name "$name" is not portable.',
        request,
      );
    }

    final options = request.options;
    final directory = _templates.store.templateDirectory(options);
    final target = _fileSystem.path.join(directory, '$name.md');
    final existing = request.create
        ? null
        : _readExisting(request, options, name, target);
    if (request.create &&
        _io.type(target, followLinks: false) != FileSystemEntityType.notFound) {
      throw _refuse(
        'TARGET_OCCUPIED',
        'A context template named "$name" already exists.',
        request,
      );
    }

    _Instruction? instruction;
    final draftRef = _DraftReference();
    try {
      instruction = await _resolveBody(request, existing, draftRef);
    } on MambaException catch (error) {
      throw MambaException(
        _withDraftSuffix(error.message, draftRef),
        exitCode: error.exitCode,
      );
    }

    final body = instruction;
    if (!request.empty && body.text.trim().isEmpty) {
      throw _refuse(
        'BODY_EMPTY',
        'A context template body cannot be empty unless --empty was supplied.',
        request,
        draft: draftRef,
      );
    }

    final bytes = utf8.encode(body.text);
    if (bytes.length > maxInstructionDraftBodyBytes) {
      throw _refuse(
        'BODY_TOO_LARGE',
        'The context template body exceeds the 1 MiB limit.',
        request,
        draft: draftRef,
      );
    }
    final plan = ContextAuthoringPlan(
      operation: request.create ? 'create' : 'edit',
      name: name,
      targetPath: target,
      empty: request.empty,
      bodySha256: sha256.convert(bytes).toString(),
      bodyByteLength: bytes.length,
      existingSha256: existing?.metadata.sha256,
      existingByteLength: existing?.metadata.byteLength,
    );
    final data = _planData(plan, request, body.text, bytes.length);

    if (!request.apply || request.dryRun) {
      return LifecycleResult(
        command: request.command,
        outcome: 'planned',
        data: data,
      );
    }

    _verifyPlan(plan, request, draftRef);
    _observeTarget(plan, request, existing, draftRef);
    await _approve(plan, request, draftRef);
    _observeTarget(plan, request, existing, draftRef);

    String? recoveryPath;
    if (!request.create) {
      recoveryPath = await _retainRecovery(
        plan,
        existing!,
        draftRef,
        _fileSystem.path.join(
          LifecycleContext.resolve(
            options,
            fileSystem: _fileSystem,
          ).stateRoot(LifecycleScope.user),
          'authoring-recovery',
          plan.planId,
          'source.md',
        ),
      );
    }
    final staged = _fileSystem.path.join(
      LifecycleContext.resolve(
        options,
        fileSystem: _fileSystem,
      ).stateRoot(LifecycleScope.user),
      'authoring-staging',
      plan.planId,
      'candidate',
    );
    _stage(target, staged, bytes, request, draftRef);
    _publish(target, staged, bytes, request, draftRef);

    if (draftRef.id != null) {
      final cleanup = await _drafts.cleanupOwned(options, draftRef.id!);
      data['draftCleaned'] = cleanup.cleaned;
      if (!cleanup.cleaned && cleanup.reason != null) {
        data['draftCleanupFailure'] = cleanup.reason;
      }
    }

    final receiptId = authoringReceiptId(plan.planId, target);
    writeAuthoringReceipt(
      state: _state,
      stateRoot: LifecycleContext.resolve(
        options,
        fileSystem: _fileSystem,
      ).stateRoot(LifecycleScope.user),
      document: authoringReceiptDocument(
        receiptId: receiptId,
        planId: plan.planId,
        operation: plan.operation,
        kind: 'contextTemplate',
        profile: 'context',
        target: target,
      ),
    );

    data
      ..['recoveryPath'] = recoveryPath
      ..['receiptId'] = receiptId;
    if (draftRef.id != null) {
      data
        ..['draftId'] = draftRef.id
        ..['draftPath'] = draftRef.path;
    }
    return LifecycleResult(
      command: request.command,
      outcome: 'published',
      data: data,
    );
  }

  Future<String> _resolveName(ContextAuthoringRequest request) async {
    final positional = request.positionalName;
    final option = request.optionName;
    if (positional != null && option != null) {
      throw _refuse(
        'AMBIGUOUS_TEMPLATE_NAME',
        'Supply either <name> or --name, not both.',
        request,
      );
    }
    final supplied = positional ?? option;
    if (supplied != null) return supplied.trim();

    if (!request.interactive || request.unattended || !hasTerminal) {
      throw _refuse(
        'MISSING_TEMPLATE_NAME',
        'Supply a context template name as <name> or --name.',
        request,
      );
    }
    if (request.create) {
      final answer = await _ask('Context template name');
      if (answer == null || answer.trim().isEmpty) {
        throw _cancel(
          'NAME_PROMPT_CANCELLED',
          'No template name was supplied.',
        );
      }
      return answer.trim();
    }
    final names = _templates
        .list(request.options)
        .map((template) => template.name)
        .toList(growable: false);
    if (names.isEmpty) {
      throw _refuse(
        'NO_TEMPLATES',
        'No context templates are available to edit.',
        request,
      );
    }
    final selected = await _select(names);
    if (selected == null || selected.trim().isEmpty) {
      throw _cancel(
        'TEMPLATE_SELECTION_CANCELLED',
        'No template was selected.',
      );
    }
    return selected.trim();
  }

  ContextTemplateRead _readExisting(
    ContextAuthoringRequest request,
    LifecycleOptions options,
    String name,
    String target,
  ) {
    final type = _io.type(target, followLinks: false);
    switch (type) {
      case FileSystemEntityType.notFound:
        throw _refuse(
          'TEMPLATE_NOT_FOUND',
          'No context template "$name" exists.',
          request,
        );
      case FileSystemEntityType.link:
        throw _refuse(
          'SYMLINK_REFUSED',
          'Context template is a link: $target',
          request,
        );
      case FileSystemEntityType.file:
        return _templates.inspect(options, name);
      default:
        throw _refuse(
          'NON_REGULAR_TEMPLATE_REFUSED',
          'Context template is not a regular file: $target',
          request,
        );
    }
  }

  Future<_Instruction> _resolveBody(
    ContextAuthoringRequest request,
    ContextTemplateRead? existing,
    _DraftReference draftRef,
  ) async {
    if (request.empty) {
      return const _Instruction(text: '');
    }
    if (request.bodyFile != null ||
        request.bodyStdin ||
        request.bodyText != null) {
      final text = _readFlagBody(request);
      return _Instruction(text: text);
    }
    if (!request.interactive || request.dryRun || !hasTerminal) {
      throw _refuse(
        'BODY_EMPTY',
        'Supply --body-file, --body-text, --body-stdin or --empty.',
        request,
      );
    }

    final seed = existing?.content ?? '';
    final operation = request.create
        ? AuthoringOperation.create
        : AuthoringOperation.edit;
    final prepared = await _drafts.prepare(
      request.options,
      AuthoringInputs(
        operation: operation,
        kind: AuthoringKind.prompt,
        profile: AuthoringProfile.global,
        scope: LifecycleScope.user,
        source: AuthoringSourceSelection(path: existing?.metadata.path),
        body: AuthoringBodySelection(kind: BodyInputKind.literal, text: seed),
        fields: const <String, AuthoringFieldValue>{},
        manage: false,
      ),
    );
    draftRef
      ..id = prepared.draftId
      ..path = prepared.path;

    final outcome = await _editor.edit(
      request.options,
      prepared.draftId,
      editorChoice: request.editorChoice,
    );
    return switch (outcome) {
      EditorEditCompleted(:final body) => _Instruction(text: body.text),
      EditorEditBodyFile(:final path) => _Instruction(
        text: _readEditorBody(path),
      ),
      EditorEditCancelled(:final reason) => throw _cancel(
        'EDITOR_CANCELLED',
        reason,
        draft: draftRef,
      ),
      EditorEditNotFinished(:final reason) => throw _cancel(
        'EDITOR_NOT_FINISHED',
        reason,
        draft: draftRef,
      ),
    };
  }

  String _readFlagBody(ContextAuthoringRequest request) {
    if (request.bodyStdin) return request.standardInput ?? '';
    if (request.bodyText != null) return request.bodyText!;
    final path = LifecycleContext.resolve(
      request.options,
      fileSystem: _fileSystem,
    ).resolvePath(request.bodyFile!);
    final type = _io.type(path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw MambaException(
        'SYMLINK_REFUSED: Body file is a link: $path',
        exitCode: 4,
      );
    }
    if (type != FileSystemEntityType.file) {
      throw MambaException(
        'BODY_FILE_NOT_FOUND: Body file is not regular: $path',
        exitCode: 4,
      );
    }
    final bytes = _io.read(path, maxInstructionDraftBodyBytes);
    if (bytes.length > maxInstructionDraftBodyBytes) {
      throw MambaException(
        'BODY_TOO_LARGE: Body file exceeds 1 MiB.',
        exitCode: 4,
      );
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw MambaException(
        'INVALID_BODY_UTF8: Body file is not UTF-8.',
        exitCode: 4,
      );
    }
  }

  String _readEditorBody(String path) {
    final bytes = _io.read(path, maxInstructionDraftBodyBytes);
    return utf8.decode(bytes);
  }

  void _verifyPlan(
    ContextAuthoringPlan plan,
    ContextAuthoringRequest request,
    _DraftReference draftRef,
  ) {
    final supplied = request.planId;
    if (supplied != null && supplied != plan.planId) {
      throw _refuse(
        'STALE_PLAN',
        'The supplied plan ID is stale; the current proposal is '
            '${plan.planId}.',
        request,
        draft: draftRef,
      );
    }
  }

  void _observeTarget(
    ContextAuthoringPlan plan,
    ContextAuthoringRequest request,
    ContextTemplateRead? existing,
    _DraftReference draftRef,
  ) {
    final type = _io.type(plan.targetPath, followLinks: false);
    if (request.create) {
      if (type != FileSystemEntityType.notFound) {
        throw _refuse(
          'TARGET_OCCUPIED',
          'A context template named "${plan.name}" already exists.',
          request,
          draft: draftRef,
        );
      }
      return;
    }
    if (type == FileSystemEntityType.link) {
      throw _refuse(
        'SYMLINK_REFUSED',
        'Context template is a link: '
            '${plan.targetPath}',
        request,
        draft: draftRef,
      );
    }
    if (type != FileSystemEntityType.file) {
      throw _refuse(
        'TEMPLATE_NOT_FOUND',
        'No context template '
            '"${plan.name}" exists.',
        request,
        draft: draftRef,
      );
    }
    if (existing == null ||
        existing.metadata.sha256 != plan.existingSha256 ||
        existing.metadata.byteLength != plan.existingByteLength) {
      throw _refuse(
        'TARGET_DRIFT',
        'The context template changed after the plan was made.',
        request,
        draft: draftRef,
      );
    }
    final currentBytes = _io.read(
      plan.targetPath,
      maxInstructionDraftBodyBytes,
    );
    if (sha256.convert(currentBytes).toString() != plan.existingSha256) {
      throw _refuse(
        'TARGET_DRIFT',
        'The context template changed after the plan was made.',
        request,
        draft: draftRef,
      );
    }
  }

  Future<void> _approve(
    ContextAuthoringPlan plan,
    ContextAuthoringRequest request,
    _DraftReference draftRef,
  ) async {
    final summary = 'Apply context plan ${plan.planId} for "${plan.name}"?';
    if (request.interactive && !request.unattended && hasTerminal) {
      final approved = await _confirm(summary);
      if (!approved) {
        throw _cancel(
          'PUBLICATION_CANCELLED',
          'The reviewed publication was cancelled; no output was written.',
          draft: draftRef,
        );
      }
      return;
    }
    if (!request.yes) {
      throw _refuse(
        'MISSING_APPROVAL',
        'Publication requires --yes in an unattended session.',
        request,
        draft: draftRef,
      );
    }
  }

  Future<String?> _retainRecovery(
    ContextAuthoringPlan plan,
    ContextTemplateRead existing,
    _DraftReference draft,
    String path,
  ) async {
    if (_io.type(path, followLinks: false) != FileSystemEntityType.notFound) {
      throw _publicationFailure(
        'RECOVERY_OCCUPIED',
        'The recovery copy of ${plan.planId} already exists.',
        draft,
      );
    }
    _state.writeProtectedDocument(path, utf8.encode(existing.content));
    return path;
  }

  void _stage(
    String target,
    String staged,
    List<int> bytes,
    ContextAuthoringRequest request,
    _DraftReference draftRef,
  ) {
    final directory = _fileSystem.path.dirname(target);
    if (_io.type(directory, followLinks: false) == FileSystemEntityType.link) {
      throw _refuse(
        'SYMLINK_REFUSED',
        'Context template directory is a link: $directory',
        request,
        draft: draftRef,
      );
    }
    _io.createDirectory(directory);
    _state.protectDirectory(directory);
    _io.createDirectory(_fileSystem.path.dirname(staged));
    _state.protectDirectory(_fileSystem.path.dirname(staged));
    if (_io.type(staged, followLinks: false) != FileSystemEntityType.notFound) {
      throw _publicationFailure(
        'STAGING_OCCUPIED',
        'The staged candidate already exists.',
        draftRef,
      );
    }
    _io.write(staged, bytes);
    final observed = _io.read(staged, maxInstructionDraftBodyBytes);
    if (sha256.convert(observed).toString() !=
        sha256.convert(bytes).toString()) {
      throw _publicationFailure(
        'STAGING_DRIFT',
        'The staged candidate changed before publication.',
        draftRef,
      );
    }
  }

  void _publish(
    String target,
    String staged,
    List<int> bytes,
    ContextAuthoringRequest request,
    _DraftReference draftRef,
  ) {
    _io.rename(staged, target);
    final published = _io.read(target, maxInstructionDraftBodyBytes);
    if (sha256.convert(published).toString() !=
        sha256.convert(bytes).toString()) {
      throw _publicationFailure(
        'PUBLICATION_DRIFT',
        'The published template does not match the plan.',
        draftRef,
      );
    }
  }

  Map<String, Object?> _planData(
    ContextAuthoringPlan plan,
    ContextAuthoringRequest request,
    String text,
    int byteLength,
  ) => <String, Object?>{
    'planId': plan.planId,
    'operation': plan.operation,
    'name': plan.name,
    'path': plan.targetPath,
    'byteLength': byteLength,
    'isEmpty': byteLength == 0,
    'sha256': plan.bodySha256,
    'empty': plan.empty,
    if (plan.operation == 'edit') ...<String, Object?>{
      'existingSha256': plan.existingSha256,
      'existingByteLength': plan.existingByteLength,
    },
    if (request.showInstructions) 'content': text,
  };

  MambaException _refuse(
    String code,
    String message,
    ContextAuthoringRequest request, {
    _DraftReference? draft,
  }) => MambaException(
    '$code: $message${_withDraftSuffix('', draft)}',
    exitCode: 4,
  );

  MambaException _cancel(
    String code,
    String message, {
    _DraftReference? draft,
  }) => MambaException(_withDraftSuffix('$code: $message', draft), exitCode: 7);

  MambaException _publicationFailure(
    String code,
    String message,
    _DraftReference draft,
  ) => MambaException(_withDraftSuffix('$code: $message', draft), exitCode: 6);

  String _withDraftSuffix(String message, _DraftReference? draft) {
    if (draft?.id == null || message.contains('draftId ')) return message;
    return '$message draftId ${draft!.id} draftPath ${draft.path}';
  }
}

final class _DraftReference {
  String? id;
  String? path;
}

final class const _Instruction({required final String text});

bool _processHasTerminal() {
  try {
    return stdin.hasTerminal && stdout.hasTerminal;
  } on Object {
    return false;
  }
}
