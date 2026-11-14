import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'editor_interaction.dart';

/// The launcher that opens a file with the platform-default text editor.
///
/// The launcher selects the editing action of the platform. It never selects
/// an arbitrary opener: a desktop association that is not an editing action
/// is not an editor capability, and a platform without a documented
/// text-editor action fails clearly instead of opening the file with
/// whatever program happens to be associated with it.
final class PlatformEditorLauncher {
  const PlatformEditorLauncher();

  /// Opens the file with the platform-default text editor.
  Future<EditorPlatformOutcome> launch(EditorPlatformRequest request) async {
    if (Platform.isWindows) return _launchWindows(request.path);
    if (Platform.isMacOS) return _launchMac(request.path);
    return const EditorPlatformOutcome.failed(
      'This platform has no documented default text editor action; a desktop '
      'file association is not an editor capability.',
    );
  }

  /// Opens the file with the Windows edit verb.
  ///
  /// The verb is the editing action of the shell. A file type without that
  /// verb fails clearly: the launcher never falls back to the open verb or
  /// to another program.
  Future<EditorPlatformOutcome> _launchWindows(String path) async {
    try {
      final shell = DynamicLibrary.open('shell32.dll');
      final execute = shell
          .lookupFunction<
            IntPtr Function(
              IntPtr,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Int32,
            ),
            int Function(
              int,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              Pointer<Utf16>,
              int,
            )
          >('ShellExecuteW');
      final verb = 'edit'.toNativeUtf16();
      final file = path.toNativeUtf16();
      try {
        final result = execute(0, verb, file, nullptr, nullptr, 1);
        if (result.toInt() > 32) {
          return const EditorPlatformOutcome(launched: true);
        }
        return EditorPlatformOutcome.failed(
          'The platform did not open the file with its edit action '
          '(shell result $result).',
        );
      } finally {
        calloc.free(verb);
        calloc.free(file);
      }
    } on ArgumentError {
      return const EditorPlatformOutcome.failed(
        'The Windows edit action is not available on this system.',
      );
    }
  }

  /// Opens the file with the macOS default text editor.
  ///
  /// The launcher does not wait for the editor: the exit of the launcher is
  /// not evidence that the document was saved, so the session asks the
  /// operator for the saved-and-finished acknowledgement.
  Future<EditorPlatformOutcome> _launchMac(String path) async {
    try {
      final process = await Process.start('/usr/bin/open', <String>[
        '-t',
        path,
      ], runInShell: false);
      // The output of the launcher is drained and discarded: it is never
      // reported and it never blocks the session.
      unawaited(process.stdout.drain<void>());
      unawaited(process.stderr.drain<void>());
      final exitCode = await process.exitCode;
      if (exitCode == 0) {
        return const EditorPlatformOutcome(launched: true);
      }
      return EditorPlatformOutcome.failed(
        'The default text editor did not open the file (exit code $exitCode).',
      );
    } on ProcessException catch (error) {
      return EditorPlatformOutcome.failed(
        'The default text editor could not be started: ${error.message}',
      );
    }
  }
}
