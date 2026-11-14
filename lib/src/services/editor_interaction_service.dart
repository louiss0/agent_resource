import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../authoring/editor_interaction.dart';
import '../authoring/editor_process.dart';
import '../authoring/editor_platform.dart';
import '../authoring/instruction_draft.dart';
import '../authoring/instruction_draft_document.dart';
import 'instruction_draft_service.dart';
import 'lifecycle_state_service.dart';

export '../authoring/editor_interaction.dart'
    show
        EditorAcknowledgement,
        EditorAcknowledgementRequest,
        EditorCommand,
        EditorCommandGrammar,
        EditorCompletionMode,
        EditorEditBodyFile,
        EditorEditCancelled,
        EditorEditCompleted,
        EditorEditNotFinished,
        EditorEditOutcome,
        EditorPlatformLauncher,
        EditorPlatformOutcome,
        EditorPlatformRequest,
        EditorProcessOutcome,
        EditorProcessRequest,
        EditorProcessRunner,
        EditorProgramKind,
        EditorRecoveryBodyFile,
        EditorRecoveryCancel,
        EditorRecoveryChoice,
        EditorRecoveryOtherEditor,
        EditorRecoveryPrompt,
        EditorRecoveryRequest,
        EditorRecoveryRetry,
        EditorSelection,
        EditorSelectionSource,
        EditorSessionEnvironment,
        EditorWaitContract;

/// The number of launches one session attempts before it gives up.
const int maxEditorSessionAttempts = 3;

/// Runs one editing session over a protected instruction draft.
///
/// The session owns the interaction with the operator and the launch of the
/// editor. It never publishes anything, it never records an approval and it
/// never removes the retained draft: a cancelled or failed session keeps its
/// draft and reports its location.
///
/// The completion of a session is evidence that the editing finished, never
/// evidence that the result may be published. A later frontend reviews the
/// edited draft and confirms the publication on its own.
///
/// The file system of the session is the file system of the draft service:
/// the paths of the protected storage are composed with it.
interface class EditorInteractionService {
  factory EditorInteractionService({
    required InstructionDraftService drafts,
    EditorProcessRunner? processRunner,
    EditorPlatformLauncher? platformLauncher,
    EditorSessionEnvironment? environment,
    EditorAcknowledgement? acknowledge,
    EditorRecoveryPrompt? recover,
    EditorProgramResolver? executables,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) => EditorInteractionService._(
    drafts,
    processRunner ?? const RealEditorProcessRunner().run,
    platformLauncher ?? const PlatformEditorLauncher().launch,
    environment ??
        EditorSessionEnvironment(
          hasTerminal: _hasTerminal(),
          hasDisplay: _hasDisplay(),
        ),
    acknowledge,
    recover,
    executables ?? EditorExecutableResolver(fileSystem),
    fileSystem,
  );

  EditorInteractionService._(
    this._drafts,
    this._processRunner,
    this._platformLauncher,
    this._environment,
    this._acknowledge,
    this._recover,
    this._executables,
    this._fileSystem,
  );

  final InstructionDraftService _drafts;
  final EditorProcessRunner _processRunner;
  final EditorPlatformLauncher _platformLauncher;
  final EditorSessionEnvironment _environment;
  final EditorAcknowledgement? _acknowledge;
  final EditorRecoveryPrompt? _recover;
  final EditorProgramResolver _executables;
  final fslib.FileSystem _fileSystem;

  /// Edits one retained instruction draft.
  ///
  /// The session prepares the editable working copy of the draft, launches
  /// the selected editor on it and reports the effective instructions once
  /// the editing finished. The instructions of the draft are never sent as
  /// an argument of the editor and they are never logged.
  ///
  /// A dry-run session and an unattended session are refused before any
  /// storage is written and before any program is launched: they never ask a
  /// question, they never wait and they never leave a working copy behind.
  Future<EditorEditOutcome> edit(
    LifecycleOptions options,
    String draftId, {
    String? editorChoice,
  }) async {
    if (options.dryRun) {
      throw MambaException(
        'An editor session prepares protected storage and launches a program; '
        'it is not available in dry-run mode.',
        exitCode: 4,
      );
    }
    if (!_environment.hasTerminal) {
      throw MambaException(
        'An editor session needs an interactive session; supply the '
        'instructions as a body file instead.',
        exitCode: 4,
      );
    }
    // The protected storage is confirmed before the working copy is used
    // and before the editor is launched.
    final draft = await _drafts.inspect(options, draftId);
    final workingPath = await _workingCopy(options, draft);
    await _drafts.read(options, draftId);
    final EditorSelection? selection;
    try {
      selection = selectEditor(
        explicitChoice: editorChoice,
        environment: options.environment,
      );
    } on MambaException catch (error) {
      // A broken configuration is not a missing configuration: it never
      // falls through to another source. The operator chooses the way out.
      return _recoverFrom(
        options,
        draftId,
        workingPath,
        null,
        error.message,
        attempts: 0,
        editorChoice: editorChoice,
      );
    }
    return _run(
      options,
      draftId,
      workingPath,
      selection,
      attempts: 0,
      editorChoice: editorChoice,
    );
  }

  /// The editable working copy of one draft.
  ///
  /// An existing working copy is reused, never rewritten. Its ownership was
  /// confirmed by the inspection of the draft; its place and its kind are
  /// confirmed again before the editor is launched.
  Future<String> _workingCopy(
    LifecycleOptions options,
    InstructionDraft draft,
  ) async {
    if (draft.hasWorkingCopy) {
      final path = _fileSystem.path.join(
        draft.path,
        instructionDraftWorkingFileName,
      );
      if (!_fileSystem.path.isWithin(draft.path, path)) {
        throw MambaException(
          'The working copy of the instruction draft escapes its storage.',
          exitCode: 6,
        );
      }
      return path;
    }
    return _drafts.prepareWorkingCopy(options, draft.draftId);
  }

  /// Confirms the draft again before a launch or a hand over.
  ///
  /// The confirmation is read-only: it never repairs the storage and it
  /// never writes to it. A substituted draft, a changed snapshot or a
  /// substituted working copy refuses the launch.
  Future<void> _revalidate(
    LifecycleOptions options,
    String draftId,
    String workingPath,
  ) async {
    final draft = await _drafts.inspect(options, draftId);
    if (!_fileSystem.path.isWithin(draft.path, workingPath)) {
      throw MambaException(
        'The working copy of the instruction draft escapes its storage.',
        exitCode: 6,
      );
    }
    // The read confirms the immutable snapshot and the working copy itself:
    // a substituted link or a replaced snapshot refuses the launch.
    await _drafts.read(options, draftId);
  }

  /// Runs one launch attempt and completes or recovers from it.
  Future<EditorEditOutcome> _run(
    LifecycleOptions options,
    String draftId,
    String workingPath,
    EditorSelection selection, {
    required int attempts,
    String? editorChoice,
  }) async {
    // The draft is confirmed again before every launch.
    await _revalidate(options, draftId, workingPath);
    final command = selection.command;
    if (command == null) {
      return _runPlatformDefault(
        options,
        draftId,
        workingPath,
        selection,
        attempts: attempts,
        editorChoice: editorChoice,
      );
    }
    final environment = _effectiveEnvironment(options);
    final resolution = _executables.resolve(
      command.executable,
      workingDirectory: options.processWorkingDirectory,
      environment: environment,
    );
    if (resolution.isBatchLauncher) {
      return _recoverFrom(
        options,
        draftId,
        workingPath,
        selection,
        'The editor ${resolution.resolvedPath ?? command.executable} is a '
        'batch launcher; a command processor may interpret it, so the '
        'argument boundaries of the draft cannot be preserved.',
        attempts: attempts,
        editorChoice: editorChoice,
      );
    }
    final program = resolution.resolvedPath;
    if (program == null) {
      return _recoverFrom(
        options,
        draftId,
        workingPath,
        selection,
        'The editor ${command.executable} was not found; no program was '
        'launched.',
        attempts: attempts,
        editorChoice: editorChoice,
      );
    }
    final kind = editorProgramKind(command);
    final terminal = kind == EditorProgramKind.terminal;
    final documentedWait =
        selection.completion == EditorCompletionMode.documentedWait;
    final outcome = await _processRunner(
      EditorProcessRequest(
        executable: program,
        arguments: command.opening(workingPath).arguments,
        environment: environment,
        workingDirectory: options.processWorkingDirectory,
        inheritTerminal: terminal,
        awaitCompletion: documentedWait || terminal,
      ),
    );
    if (!outcome.started) {
      return _recoverFrom(
        options,
        draftId,
        workingPath,
        selection,
        outcome.reason ?? 'The editor could not be started.',
        attempts: attempts,
        editorChoice: editorChoice,
      );
    }
    if (documentedWait) {
      final exitCode = outcome.exitCode;
      if (exitCode == null) {
        return _recoverFrom(
          options,
          draftId,
          workingPath,
          selection,
          'The editor did not report that the editing had finished.',
          attempts: attempts,
          editorChoice: editorChoice,
        );
      }
      if (exitCode != 0) {
        return _recoverFrom(
          options,
          draftId,
          workingPath,
          selection,
          'The editor ended with the exit code $exitCode.',
          attempts: attempts,
          editorChoice: editorChoice,
        );
      }
    }
    return _complete(options, draftId, workingPath, selection);
  }

  /// Runs one launch attempt with the platform-default text editor.
  Future<EditorEditOutcome> _runPlatformDefault(
    LifecycleOptions options,
    String draftId,
    String workingPath,
    EditorSelection selection, {
    required int attempts,
    String? editorChoice,
  }) async {
    if (!_environment.hasDisplay) {
      return _recoverFrom(
        options,
        draftId,
        workingPath,
        selection,
        'The session has no display for a graphical editor.',
        attempts: attempts,
        editorChoice: editorChoice,
      );
    }
    final outcome = await _platformLauncher(
      EditorPlatformRequest(path: workingPath),
    );
    if (!outcome.launched) {
      return _recoverFrom(
        options,
        draftId,
        workingPath,
        selection,
        outcome.reason ?? 'The platform did not open the file.',
        attempts: attempts,
        editorChoice: editorChoice,
      );
    }
    return _complete(options, draftId, workingPath, selection);
  }

  /// Completes the session after the editing finished.
  ///
  /// The completion of a documented wait is the documented event of the
  /// editor. Every other editor needs the explicit acknowledgement of the
  /// operator that the file was saved and the editing was finished. The
  /// exit of a terminal editor is not acceptance either: it only says that
  /// the editor closed.
  ///
  /// The acknowledgement permits the reading of the draft; it is never a
  /// publication approval.
  Future<EditorEditOutcome> _complete(
    LifecycleOptions options,
    String draftId,
    String workingPath,
    EditorSelection selection,
  ) async {
    if (selection.completion ==
        EditorCompletionMode.savedAndFinishedAcknowledgement) {
      final acknowledged = await _askForAcknowledgement(draftId, workingPath);
      if (!acknowledged) {
        return EditorEditNotFinished(
          draftId: draftId,
          path: workingPath,
          reason:
              'The operator did not confirm that the instructions were saved '
              'and that the editing had finished.',
        );
      }
    }
    final body = await _drafts.read(options, draftId);
    return EditorEditCompleted(
      draftId: draftId,
      path: workingPath,
      body: body,
      completion: selection.completion,
      selection: selection,
    );
  }

  /// Asks the operator to confirm that the editing finished.
  Future<bool> _askForAcknowledgement(
    String draftId,
    String workingPath,
  ) async {
    final ask = _acknowledge;
    if (ask == null) return false;
    try {
      return await ask(
        EditorAcknowledgementRequest(draftId: draftId, path: workingPath),
      );
    } on Exception {
      return false;
    }
  }

  /// Asks the operator how to continue after a failed launch.
  ///
  /// A missing editor capability, an unusable configuration and a failed
  /// launch are answered the same way: the operator retries, chooses another
  /// editor, continues with the working copy as a body file, or cancels. The
  /// session never chooses a program on its own.
  Future<EditorEditOutcome> _recoverFrom(
    LifecycleOptions options,
    String draftId,
    String workingPath,
    EditorSelection? selection,
    String reason, {
    required int attempts,
    String? editorChoice,
  }) async {
    final ask = _recover;
    if (ask == null) {
      return EditorEditCancelled(draftId: draftId, reason: reason);
    }
    final EditorRecoveryChoice choice;
    try {
      choice = await ask(
        EditorRecoveryRequest(
          draftId: draftId,
          path: workingPath,
          reason: reason,
          attempts: attempts,
        ),
      );
    } on Exception {
      return EditorEditCancelled(draftId: draftId, reason: reason);
    }
    switch (choice) {
      case EditorRecoveryRetry():
        if (attempts + 1 >= maxEditorSessionAttempts) {
          return EditorEditCancelled(
            draftId: draftId,
            reason: 'The editor did not start after ${attempts + 1} attempts.',
          );
        }
        final next = selection ?? _select(options, editorChoice);
        if (next == null) {
          return _recoverFrom(
            options,
            draftId,
            workingPath,
            null,
            reason,
            attempts: attempts + 1,
            editorChoice: editorChoice,
          );
        }
        return _run(
          options,
          draftId,
          workingPath,
          next,
          attempts: attempts + 1,
          editorChoice: editorChoice,
        );
      case EditorRecoveryOtherEditor(:final editor):
        if (attempts + 1 >= maxEditorSessionAttempts) {
          return EditorEditCancelled(
            draftId: draftId,
            reason: 'The editor did not start after ${attempts + 1} attempts.',
          );
        }
        final EditorCommand command;
        try {
          command = EditorCommandGrammar.parse(editor);
        } on MambaException catch (error) {
          return _recoverFrom(
            options,
            draftId,
            workingPath,
            null,
            error.message,
            attempts: attempts + 1,
            editorChoice: editorChoice,
          );
        }
        return _run(
          options,
          draftId,
          workingPath,
          EditorSelection(
            source: EditorSelectionSource.explicitChoice,
            command: command,
            completion: editorCompletionMode(command),
          ),
          attempts: attempts + 1,
          editorChoice: editorChoice,
        );
      case EditorRecoveryBodyFile():
        // The draft is confirmed again before the working copy is handed
        // over as a body file.
        await _revalidate(options, draftId, workingPath);
        return EditorEditBodyFile(draftId: draftId, path: workingPath);
      case EditorRecoveryCancel():
        return EditorEditCancelled(draftId: draftId, reason: reason);
    }
  }

  /// The selection of one editor, when the configuration is usable.
  EditorSelection? _select(LifecycleOptions options, String? editorChoice) {
    try {
      return selectEditor(
        explicitChoice: editorChoice,
        environment: options.environment,
      );
    } on MambaException {
      return null;
    }
  }

  /// The environment of the session.
  ///
  /// The environment is read from the captured configuration
  /// (`LifecycleOptions.environment`). Selection, resolution and launch all
  /// use the same environment, so the program that is checked is the program
  /// that runs and the variables the selection read are the variables the
  /// program inherits. No environment lookup is deferred to the live process
  /// environment after the command has begun its operation.
  Map<String, String> _effectiveEnvironment(LifecycleOptions options) =>
      options.environment;
}

/// Whether the session of the process has a terminal.
bool _hasTerminal() {
  try {
    return stdin.hasTerminal && stdout.hasTerminal;
  } on Exception {
    return false;
  }
}

/// Whether the session of the process has a display.
///
/// A desktop session is assumed on the platforms whose default text editor
/// is a graphical program. The assumption is a limitation and not a
/// verification: a session without a desktop fails the launch clearly.
bool _hasDisplay() => Platform.isWindows || Platform.isMacOS;
