import 'package:mamba/mamba.dart';

import 'instruction_draft.dart';

/// Where the selected editor came from.
///
/// The precedence is a contract of this application: an explicit choice of the
/// caller first, then the configured `VISUAL` variable, then the configured
/// `EDITOR` variable and finally the platform-default text editor
/// capability. A configuration that cannot be used is an error; it never
/// falls through to the next source.
enum EditorSelectionSource {
  explicitChoice,
  visualVariable,
  editorVariable,
  platformDefault,
}

/// One editor invocation.
///
/// An editor is an executable and an argument vector. It is never a shell
/// expression: the arguments keep their boundaries and they are never
/// re-parsed by a command processor.
final class EditorCommand {
  EditorCommand({
    required String executable,
    List<String> arguments = const <String>[],
  }) : executable = _validatedExecutable(executable),
       arguments = List<String>.unmodifiable(arguments);

  /// The program that is launched.
  final String executable;

  /// The arguments of the program, before the edited file is appended.
  final List<String> arguments;

  /// The invocation that opens one file.
  ///
  /// The file is appended as one argument. It is never concatenated into the
  /// other arguments and it is never quoted for a command processor.
  EditorCommand opening(String path) => EditorCommand(
    executable: executable,
    arguments: <String>[...arguments, path],
  );

  /// The file name of the executable, without its directory.
  String get executableName {
    final normalized = executable.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  /// Whether the executable is a Windows batch launcher.
  ///
  /// A batch launcher is refused even when the process is started without a
  /// command processor: the operating system may still interpret it.
  bool get isBatchLauncher {
    final name = executableName.toLowerCase();
    return name.endsWith('.cmd') || name.endsWith('.bat');
  }

  static String _validatedExecutable(String executable) {
    if (executable.trim().isEmpty) {
      throw ArgumentError.value(
        executable,
        'executable',
        'An editor command needs an executable.',
      );
    }
    return executable;
  }
}

/// The grammar of an editor configuration value.
///
/// The value is an executable followed by arguments. The arguments are
/// separated by whitespace. A double-quoted segment is one literal argument
/// that may contain whitespace; inside a quoted segment a backslash escapes
/// a backslash or a double quote. Every other character is literal data.
///
/// A value that carries a shell expression is refused: the pipes, redirects,
/// substitutions and command separators of a command processor are not part
/// of the grammar. A shell interpreter is refused as the executable, so the
/// grammar can never be handed to one.
abstract final class EditorCommandGrammar {
  /// The characters that carry a shell expression.
  static const String shellCharacters = r'|&;<>$`()';

  /// The program names that interpret a shell expression.
  static const Set<String> shellInterpreters = <String>{
    'cmd',
    'cmd.exe',
    'command',
    'command.com',
    'powershell',
    'powershell.exe',
    'pwsh',
    'pwsh.exe',
    'sh',
    'bash',
    'zsh',
    'ksh',
    'csh',
    'tcsh',
    'fish',
    'dash',
    'wscript',
    'wscript.exe',
    'cscript',
    'cscript.exe',
  };

  /// Parses one editor configuration value.
  ///
  /// The parse fails closed: a value that is not an executable with an
  /// argument vector is refused instead of being reinterpreted.
  static EditorCommand parse(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw MambaException('The editor configuration is empty.', exitCode: 4);
    }
    final tokens = <String>[];
    final buffer = StringBuffer();
    var quoted = false;
    var started = false;
    for (var index = 0; index < trimmed.length; index++) {
      final character = trimmed[index];
      if (character == '\n' || character == '\r') {
        throw MambaException(
          'The editor configuration must be a single line.',
          exitCode: 4,
        );
      }
      if (quoted) {
        if (character == r'\' && index + 1 < trimmed.length) {
          final next = trimmed[index + 1];
          if (next == r'\' || next == '"') {
            buffer.write(next);
            index++;
            continue;
          }
        }
        if (character == '"') {
          quoted = false;
          continue;
        }
        buffer.write(character);
        continue;
      }
      if (character == '"') {
        quoted = true;
        started = true;
        continue;
      }
      if (character == ' ' || character == '\t') {
        if (started) {
          tokens.add(buffer.toString());
          buffer.clear();
          started = false;
        }
        continue;
      }
      if (shellCharacters.contains(character)) {
        throw MambaException(
          'The editor configuration carries a shell expression; only an '
          'executable and its arguments are accepted.',
          exitCode: 4,
        );
      }
      buffer.write(character);
      started = true;
    }
    if (quoted) {
      throw MambaException(
        'The editor configuration has an unterminated quoted argument.',
        exitCode: 4,
      );
    }
    if (started) {
      tokens.add(buffer.toString());
    }
    if (tokens.isEmpty) {
      throw MambaException('The editor configuration is empty.', exitCode: 4);
    }
    final executable = tokens.first;
    final name = executable.replaceAll('\\', '/');
    final separator = name.lastIndexOf('/');
    final base = (separator < 0 ? name : name.substring(separator + 1))
        .toLowerCase();
    if (shellInterpreters.contains(base)) {
      throw MambaException(
        'The editor configuration selects a command interpreter; only an '
        'editor executable and its arguments are accepted.',
        exitCode: 4,
      );
    }
    return EditorCommand(executable: executable, arguments: tokens.sublist(1));
  }
}

/// The completion evidence one editor can provide.
///
/// A documented wait is the completion event that the editor itself
/// documents. Every other editor needs an explicit acknowledgement that the
/// operator saved the file and finished editing.
enum EditorCompletionMode { documentedWait, savedAndFinishedAcknowledgement }

/// The completion contract of one editor command.
///
/// The contract is recognized only for the editors whose documentation states
/// it. No generic wait flag is assumed for an arbitrary program.
enum EditorWaitContract { none, documented }

/// The kind of program that an editor command names.
///
/// A terminal editor reads and writes the terminal of the operator, so it
/// inherits the terminal of the session. A graphical editor needs a display.
/// An unknown program is treated like a graphical one: it is never awaited,
/// because it may run until the operator closes it.
enum EditorProgramKind { terminal, graphical, unknown }

/// The program names that are known terminal editors.
///
/// The list is a documented heuristic of this application: a program that is
/// not on it is never assumed to read the terminal.
const Set<String> knownTerminalEditors = <String>{
  'vi',
  'vim',
  'nvim',
  'vim.basic',
  'nano',
  'emacs',
  'emacsclient',
  'emacsclient.exe',
  'helix',
  'hx',
  'micro',
  'kak',
  'pico',
  'ed',
  'joe',
};

/// Recognizes the completion contract of one editor command.
///
/// The Visual Studio Code command line interface documents `--wait` as
/// waiting until the files are closed, and GNU Emacs documents that
/// `emacsclient` normally waits for the editing to finish. Every other
/// command waits for nothing: its exit is not evidence that the document was
/// saved.
///
/// The name of the program decides, not the spelling of its path: the
/// documented wait of an editor is the same contract when the program is
/// named by its absolute path. The Windows binary of Visual Studio Code is
/// `Code.exe`, and that spelling is the only one that this module may
/// launch, because the `code.cmd` launcher of the search path is refused.
EditorWaitContract editorWaitContract(EditorCommand command) {
  final name = command.executableName.toLowerCase();
  if (name == 'emacsclient' || name == 'emacsclient.exe') {
    return _emacsClientWaits(command)
        ? EditorWaitContract.documented
        : EditorWaitContract.none;
  }
  const waitCapable = <String>{'code', 'code-insiders'};
  final binary = name.endsWith('.exe')
      ? name.substring(0, name.length - '.exe'.length)
      : name;
  if (waitCapable.contains(binary) && command.arguments.contains('--wait')) {
    return EditorWaitContract.documented;
  }
  return EditorWaitContract.none;
}

/// Whether the Emacs client waits for the editing to finish.
///
/// The client does not wait when it is asked not to: `--no-wait` and its
/// value form disable the wait, and `-n` opens a new frame instead of
/// waiting for the editing of the frame.
bool _emacsClientWaits(EditorCommand command) {
  for (final argument in command.arguments) {
    if (argument == '--no-wait' || argument.startsWith('--no-wait=')) {
      return false;
    }
    if (argument == '-n') return false;
  }
  return true;
}

/// The completion mode of one editor command.
EditorCompletionMode editorCompletionMode(EditorCommand command) =>
    editorWaitContract(command) == EditorWaitContract.documented
    ? EditorCompletionMode.documentedWait
    : EditorCompletionMode.savedAndFinishedAcknowledgement;

/// The kind of program that an editor command names.
EditorProgramKind editorProgramKind(EditorCommand command) {
  final name = command.executableName.toLowerCase();
  if (knownTerminalEditors.contains(name)) return EditorProgramKind.terminal;
  if (name.endsWith('.exe')) return EditorProgramKind.graphical;
  return EditorProgramKind.unknown;
}

/// The selected editor of one editing session.
final class EditorSelection {
  const EditorSelection({
    required this.source,
    required this.completion,
    this.command,
  });

  /// Where the selection came from.
  final EditorSelectionSource source;

  /// The editor command, when a configured editor was selected.
  ///
  /// A null command selects the platform-default text editor capability.
  final EditorCommand? command;

  /// The completion evidence the selected editor provides.
  final EditorCompletionMode completion;
}

/// Selects the editor of one editing session.
///
/// The precedence is the contract of this application: an explicit choice of
/// the caller, then the configured `VISUAL` variable, then the configured
/// `EDITOR` variable and finally the platform-default text editor
/// capability.
///
/// A configuration that cannot be used is an error. It never falls through
/// to the next source: a broken configuration is not a missing configuration.
EditorSelection selectEditor({
  String? explicitChoice,
  required Map<String, String> environment,
}) {
  final explicit = _configuredValue(explicitChoice);
  if (explicit != null) {
    final command = EditorCommandGrammar.parse(explicit);
    return EditorSelection(
      source: EditorSelectionSource.explicitChoice,
      command: command,
      completion: editorCompletionMode(command),
    );
  }
  final visual = _configuredValue(environment['VISUAL']);
  if (visual != null) {
    final command = EditorCommandGrammar.parse(visual);
    return EditorSelection(
      source: EditorSelectionSource.visualVariable,
      command: command,
      completion: editorCompletionMode(command),
    );
  }
  final editor = _configuredValue(environment['EDITOR']);
  if (editor != null) {
    final command = EditorCommandGrammar.parse(editor);
    return EditorSelection(
      source: EditorSelectionSource.editorVariable,
      command: command,
      completion: editorCompletionMode(command),
    );
  }
  return const EditorSelection(
    source: EditorSelectionSource.platformDefault,
    completion: EditorCompletionMode.savedAndFinishedAcknowledgement,
  );
}

/// The value of a configuration entry, when it carries one.
String? _configuredValue(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// The capabilities of the session that runs the editor.
///
/// The terminal is the capability that allows an acknowledgement and a
/// recovery question. The display is the capability that a graphical editor
/// needs.
final class EditorSessionEnvironment {
  const EditorSessionEnvironment({
    required this.hasTerminal,
    required this.hasDisplay,
  });

  /// Whether the session has a terminal to ask the operator in.
  final bool hasTerminal;

  /// Whether the session has a display for a graphical editor.
  final bool hasDisplay;
}

/// One request to launch a program with an argument vector.
final class EditorProcessRequest {
  EditorProcessRequest({
    required String executable,
    required List<String> arguments,
    Map<String, String> environment = const <String, String>{},
    this.workingDirectory,
    this.inheritTerminal = false,
    this.awaitCompletion = false,
  }) : executable = _validated(executable, 'executable'),
       arguments = List<String>.unmodifiable(arguments),
       environment = Map<String, String>.unmodifiable(environment);

  /// The program that is launched.
  ///
  /// The program is the absolute path that the resolution checked. The
  /// spelling of the configuration is never launched directly.
  final String executable;

  /// The argument vector of the program.
  final List<String> arguments;

  /// The environment of the launched program.
  ///
  /// The environment is the captured one, so the program that is launched
  /// searches the same search path as the resolution did.
  final Map<String, String> environment;

  /// The working directory of the launched program.
  final String? workingDirectory;

  /// Whether the program inherits the terminal of the session.
  ///
  /// A terminal editor needs the terminal of the operator. An inherited
  /// terminal still reports an exit code, so a terminal editor may be waited
  /// for, but its exit is never acceptance of the edited text.
  final bool inheritTerminal;

  /// Whether the launch waits for the exit of the program.
  ///
  /// Only a program with a documented completion contract and a terminal
  /// editor are waited for. An unknown graphical program is never awaited: it
  /// may run until the operator closes it, and the session asks the operator
  /// instead.
  final bool awaitCompletion;

  static String _validated(String value, String label) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, label, 'The value must not be blank.');
    }
    return value;
  }
}

/// The outcome of one program launch.
final class EditorProcessOutcome {
  const EditorProcessOutcome({
    required this.started,
    this.exitCode,
    this.reason,
  });

  /// A launch that did not start the program.
  const EditorProcessOutcome.failed(this.reason)
    : started = false,
      exitCode = null;

  /// Whether the program was started.
  final bool started;

  /// The exit code of the program, when it was observed.
  final int? exitCode;

  /// The reason a launch failed.
  final String? reason;
}

/// The runner that launches a program with an argument vector.
///
/// The runner never uses a command processor. The arguments keep their
/// boundaries and the output of the launcher is never the instruction body.
typedef EditorProcessRunner = Future<EditorProcessOutcome> Function(
  EditorProcessRequest request,
);

/// One request to open a file with the platform-default text editor.
final class EditorPlatformRequest {
  EditorPlatformRequest({required String path}) : path = _validated(path);

  /// The file that is opened.
  final String path;

  static String _validated(String value) {
    if (value.trim().isEmpty) {
      throw ArgumentError.value(value, 'path', 'The path must not be blank.');
    }
    return value;
  }
}

/// The outcome of one platform-default launch.
final class EditorPlatformOutcome {
  const EditorPlatformOutcome({required this.launched, this.reason});

  /// A launch that did not open the file.
  const EditorPlatformOutcome.failed(this.reason) : launched = false;

  /// Whether the platform opened the file.
  final bool launched;

  /// The reason the platform did not open the file.
  final String? reason;
}

/// The launcher that opens a file with the platform-default text editor.
///
/// The launcher selects the editing action of the platform. It never selects
/// an arbitrary opener: a platform association that is not an editing action
/// is not an editor capability.
typedef EditorPlatformLauncher = Future<EditorPlatformOutcome> Function(
  EditorPlatformRequest request,
);

/// The question that asks the operator to save the file and finish editing.
///
/// The acknowledgement is never a publication approval: it only permits the
/// reading and the validation of the edited draft.
typedef EditorAcknowledgement = Future<bool> Function(
  EditorAcknowledgementRequest request,
);

/// The request of one saved-and-finished acknowledgement.
final class EditorAcknowledgementRequest {
  const EditorAcknowledgementRequest({
    required this.draftId,
    required this.path,
  });

  /// The identity of the edited draft.
  final String draftId;

  /// The editable working copy of the draft.
  final String path;
}

/// The question that asks the operator how to continue after a failure.
typedef EditorRecoveryPrompt = Future<EditorRecoveryChoice> Function(
  EditorRecoveryRequest request,
);

/// The request of one recovery question.
final class EditorRecoveryRequest {
  const EditorRecoveryRequest({
    required this.draftId,
    required this.path,
    required this.reason,
    required this.attempts,
  });

  /// The identity of the retained draft.
  final String draftId;

  /// The editable working copy of the draft.
  final String path;

  /// The reason the last attempt failed.
  final String reason;

  /// The number of failed attempts.
  final int attempts;
}

/// The answer to one recovery question.
sealed class EditorRecoveryChoice {
  const EditorRecoveryChoice();
}

/// The answer that launches the same editor again.
final class EditorRecoveryRetry extends EditorRecoveryChoice {
  const EditorRecoveryRetry();
}

/// The answer that launches another editor.
final class EditorRecoveryOtherEditor extends EditorRecoveryChoice {
  const EditorRecoveryOtherEditor(this.editor);

  /// The editor configuration of the other editor.
  final String editor;
}

/// The answer that continues with the working copy as a body file.
final class EditorRecoveryBodyFile extends EditorRecoveryChoice {
  const EditorRecoveryBodyFile();
}

/// The answer that keeps the draft and stops the session.
final class EditorRecoveryCancel extends EditorRecoveryChoice {
  const EditorRecoveryCancel();
}

/// The outcome of one editing session.
///
/// An outcome never carries a publication approval: the edited draft is a
/// proposal that a later frontend reviews and confirms on its own.
sealed class EditorEditOutcome {
  const EditorEditOutcome({required this.draftId});

  /// The identity of the edited draft.
  final String draftId;
}

/// The outcome of a finished editing session.
final class EditorEditCompleted extends EditorEditOutcome {
  const EditorEditCompleted({
    required super.draftId,
    required this.path,
    required this.body,
    required this.completion,
    required this.selection,
  });

  /// The editable working copy of the draft.
  final String path;

  /// The effective instructions of the draft after the session.
  final InstructionDraftBody body;

  /// The completion evidence the session used.
  final EditorCompletionMode completion;

  /// The editor that was used.
  final EditorSelection selection;
}

/// The outcome of a session that the operator did not finish.
final class EditorEditNotFinished extends EditorEditOutcome {
  const EditorEditNotFinished({
    required super.draftId,
    required this.path,
    required this.reason,
  });

  /// The editable working copy of the draft.
  final String path;

  /// The reason the session did not finish.
  final String reason;
}

/// The outcome of a session that offers the working copy as a body file.
final class EditorEditBodyFile extends EditorEditOutcome {
  const EditorEditBodyFile({required super.draftId, required this.path});

  /// The editable working copy of the draft.
  ///
  /// The copy stays inside the protected draft storage. It is the body file
  /// of a later authoring run; it is never a publication path and it is
  /// never a cleanup target of the original input.
  final String path;
}

/// The outcome of a cancelled session.
///
/// The draft is retained: a cancellation never removes the protected storage.
final class EditorEditCancelled extends EditorEditOutcome {
  const EditorEditCancelled({required super.draftId, required this.reason});

  /// The reason the session was cancelled.
  final String reason;
}
