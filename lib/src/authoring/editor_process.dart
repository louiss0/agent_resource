import 'dart:async';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;

import 'editor_interaction.dart';

/// The program that an editor command names.
///
/// The resolution is the answer to one question: which file would the
/// operating system launch for this spelling, and is that file a program
/// that may be launched without a command processor?
final class EditorExecutableResolution {
  const EditorExecutableResolution({
    required this.requested,
    required this.resolvedPath,
    required this.isBatchLauncher,
  });

  /// The spelling that the configuration used.
  final String requested;

  /// The absolute path of the program, when it was found.
  ///
  /// A null path means that no program was found. The caller never launches
  /// the requested spelling when a program was resolved: the program that
  /// was checked is the program that is launched.
  final String? resolvedPath;

  /// Whether the program is a batch launcher.
  ///
  /// A batch launcher may be interpreted by a command processor even when the
  /// process is started without one.
  final bool isBatchLauncher;
}

/// Resolves the program that an editor command names.
///
/// The resolver is the seam of the launch: the program that it resolves is
/// the program that is launched.
abstract interface class EditorProgramResolver {
  /// Resolves one executable spelling.
  EditorExecutableResolution resolve(
    String executable, {
    required String workingDirectory,
    required Map<String, String> environment,
  });
}

/// Resolves the program that an editor command names.
///
/// The resolution exists for one safety property: a program that the
/// operating system may interpret through a command processor is not a
/// program that this application launches. A Windows batch launcher is
/// refused, and a batch launcher that is only found through the search path
/// is refused as well: the refusal follows the program, not the spelling of
/// the configuration.
///
/// The resolution and the launch use the same environment and the same
/// working directory, so the program that is checked is the program that
/// runs.
final class EditorExecutableResolver implements EditorProgramResolver {
  const EditorExecutableResolver([
    this._fileSystem = const local.LocalFileSystem(),
  ]);

  final fslib.FileSystem _fileSystem;

  @override
  EditorExecutableResolution resolve(
    String executable, {
    required String workingDirectory,
    required Map<String, String> environment,
  }) {
    final requested = executable;
    if (_isBatchName(_baseName(executable))) {
      return EditorExecutableResolution(
        requested: requested,
        resolvedPath: null,
        isBatchLauncher: true,
      );
    }
    final candidates = <String>[];
    if (_hasSeparator(executable)) {
      final base = _fileSystem.path.isAbsolute(executable)
          ? executable
          : _fileSystem.path.join(workingDirectory, executable);
      candidates.addAll(_completions(base, environment));
    } else {
      // The current directory of the session comes first on Windows only. A
      // program of the working directory must never shadow the search path of
      // a posix system, where the current directory is not searched.
      if (Platform.isWindows) {
        candidates.addAll(
          _completions(
            _fileSystem.path.join(workingDirectory, executable),
            environment,
          ),
        );
      }
      for (final directory in _searchPath(environment)) {
        candidates.addAll(
          _completions(
            _fileSystem.path.join(directory, executable),
            environment,
          ),
        );
      }
    }
    for (final candidate in candidates) {
      // A linked program is a program: the link is followed to decide
      // whether the candidate is a file.
      if (_fileSystem.typeSync(candidate, followLinks: true) !=
          FileSystemEntityType.file) {
        continue;
      }
      final actual = _actualPath(candidate);
      return EditorExecutableResolution(
        requested: requested,
        resolvedPath: actual,
        isBatchLauncher: _isBatchName(actual),
      );
    }
    return EditorExecutableResolution(
      requested: requested,
      resolvedPath: null,
      isBatchLauncher: false,
    );
  }

  /// The path of the file with the name that the storage uses.
  ///
  /// The search path completion may produce a name with another spelling of
  /// the extension. The resolved program is the file that exists, with the
  /// name that it has. Only a storage that ignores the case of the name can
  /// report another spelling; a posix storage keeps the name that was asked
  /// for, so that a file of another name is never selected.
  String _actualPath(String candidate) {
    if (!Platform.isWindows) return candidate;
    final directory = _fileSystem.path.dirname(candidate);
    final name = _fileSystem.path.basename(candidate);
    final entries = _fileSystem.directory(directory).listSync();
    for (final entry in entries) {
      final entryName = _fileSystem.path.basename(entry.path);
      if (entryName.toLowerCase() == name.toLowerCase()) return entry.path;
    }
    return candidate;
  }

  /// The candidate files of one name.
  ///
  /// A name with an extension is one candidate. A name without an extension
  /// is completed with the executable extensions of the environment on
  /// Windows and is one candidate elsewhere.
  List<String> _completions(String base, Map<String, String> environment) {
    if (_hasExtension(_baseName(base))) return <String>[base];
    if (!Platform.isWindows) return <String>[base];
    return <String>[
      for (final extension in _executableExtensions(environment))
        '$base$extension',
    ];
  }

  /// The directories of the search path of the environment.
  ///
  /// Environment variable names are case-insensitive on Windows, so the key
  /// is looked up without regard to case.
  List<String> _searchPath(Map<String, String> environment) {
    final raw = _environmentValue(environment, 'PATH');
    if (raw == null || raw.trim().isEmpty) return const <String>[];
    final separator = Platform.isWindows ? ';' : ':';
    return raw
        .split(separator)
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }

  /// The executable extensions completed for a bare name.
  ///
  /// Only binary executables are completed. Batch launchers (`.bat`/`.cmd`)
  /// and script hosts are never completed through the search path, so a
  /// search-path lookup can never silently start a program through a command
  /// processor. A batch launcher spelled explicitly is still refused by name.
  List<String> _executableExtensions(Map<String, String> environment) {
    final raw = _environmentValue(environment, 'PATHEXT') ?? '.COM;.EXE';
    return raw
        .split(';')
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .where(
          (entry) =>
              entry.toLowerCase() == '.com' || entry.toLowerCase() == '.exe',
        )
        .toList(growable: false);
  }

  /// The value of an environment variable, looked up without regard to case.
  ///
  /// Environment variable names are case-insensitive on Windows; on posix,
  /// the exact spelling is used.
  String? _environmentValue(Map<String, String> environment, String name) {
    if (!Platform.isWindows) return environment[name];
    for (final entry in environment.entries) {
      if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
    }
    return null;
  }

  bool _hasSeparator(String executable) =>
      executable.contains('/') || executable.contains('\\');

  bool _hasExtension(String name) => name.lastIndexOf('.') > 0;

  String _baseName(String executable) {
    final normalized = executable.replaceAll('\\', '/');
    final index = normalized.lastIndexOf('/');
    return index < 0 ? normalized : normalized.substring(index + 1);
  }

  bool _isBatchName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.cmd') || lower.endsWith('.bat');
  }
}

/// The runner that launches a program with an argument vector.
///
/// The runner never uses a command processor: the executable and the
/// arguments are handed to the operating system as they are. The output of
/// the launcher is drained and discarded, so a noisy launcher cannot block
/// and the instruction body is never logged.
///
/// The runner refuses a batch launcher at the launch boundary itself: the
/// refusal does not depend on the caller having checked the program.
final class RealEditorProcessRunner {
  const RealEditorProcessRunner();

  /// Launches one program and observes its completion.
  ///
  /// A program that inherits the terminal of the session keeps the streams
  /// of the operator and still reports an exit code. A program with a
  /// documented completion contract is started with piped streams that are
  /// drained and discarded, and its exit is awaited.
  ///
  /// A program without a documented completion contract is detached: it may
  /// run until the operator closes it, and the session must neither wait for
  /// it nor keep its streams open. A detached program has no communication
  /// channel, so the parent process can end while the program runs on.
  Future<EditorProcessOutcome> run(EditorProcessRequest request) async {
    if (_isBatchLauncher(request.executable)) {
      return const EditorProcessOutcome.failed(
        'The editor is a batch launcher; a command processor may interpret it, '
        'so the argument boundaries of the draft cannot be preserved.',
      );
    }
    try {
      if (request.inheritTerminal) {
        final process = await Process.start(
          request.executable,
          request.arguments,
          runInShell: false,
          environment: request.environment,
          includeParentEnvironment: false,
          workingDirectory: request.workingDirectory,
          mode: ProcessStartMode.inheritStdio,
        );
        if (!request.awaitCompletion) {
          return const EditorProcessOutcome(started: true);
        }
        final exitCode = await process.exitCode;
        return EditorProcessOutcome(started: true, exitCode: exitCode);
      }
      if (!request.awaitCompletion) {
        await Process.start(
          request.executable,
          request.arguments,
          runInShell: false,
          environment: request.environment,
          includeParentEnvironment: false,
          workingDirectory: request.workingDirectory,
          mode: ProcessStartMode.detached,
        );
        return const EditorProcessOutcome(started: true);
      }
      final process = await Process.start(
        request.executable,
        request.arguments,
        runInShell: false,
        environment: request.environment,
        includeParentEnvironment: false,
        workingDirectory: request.workingDirectory,
        mode: ProcessStartMode.normal,
      );
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      final exitCode = await process.exitCode;
      return EditorProcessOutcome(started: true, exitCode: exitCode);
    } on ProcessException catch (error) {
      return EditorProcessOutcome.failed(
        'The editor could not be started: ${error.message}',
      );
    }
  }

  bool _isBatchLauncher(String executable) {
    final normalized = executable.replaceAll('\\', '/');
    final name = normalized
        .substring(normalized.lastIndexOf('/') + 1)
        .toLowerCase();
    return name.endsWith('.cmd') || name.endsWith('.bat');
  }
}
