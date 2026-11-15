import 'dart:io';

import 'package:agent_resource/src/authoring/editor_interaction.dart';
import 'package:agent_resource/src/authoring/editor_process.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('editor program resolution', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync(
        'agent resource resolver ',
      );
    });

    tearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });

    /// The name of the program file of one base name on this platform.
    ///
    /// A posix system runs a program without an extension; a windows system
    /// completes the name with the executable extensions of the environment.
    String programName(String base) => Platform.isWindows ? '$base.exe' : base;

    test('a program of the search path is resolved to its absolute path', () {
      final name = programName('editor');
      File(p.join(directory.path, name)).writeAsBytesSync(<int>[1]);
      final resolver = EditorExecutableResolver(const LocalFileSystem());

      final resolution = resolver.resolve(
        'editor',
        workingDirectory: directory.parent.path,
        environment: <String, String>{'PATH': directory.path},
      );

      expect(resolution.resolvedPath, p.join(directory.path, name));
      expect(resolution.isBatchLauncher, isFalse);
    });

    test('a batch launcher of the search path is not completed', () {
      File(p.join(directory.path, 'editor.cmd')).writeAsBytesSync(<int>[1]);
      final resolver = EditorExecutableResolver(const LocalFileSystem());

      // Batch launchers are not completed through the executable extensions,
      // so a bare name that would only match a batch launcher is not
      // resolved at all (a batch launcher spelled explicitly is still
      // refused by name).
      final resolution = resolver.resolve(
        'editor',
        workingDirectory: directory.parent.path,
        environment: <String, String>{'PATH': directory.path},
      );

      expect(resolution.resolvedPath, isNull);
      expect(resolution.isBatchLauncher, isFalse);
    });

    test('a batch launcher spelling is refused without a lookup', () {
      final resolver = EditorExecutableResolver(const LocalFileSystem());

      final resolution = resolver.resolve(
        'editor.cmd',
        workingDirectory: directory.parent.path,
        environment: const <String, String>{},
      );

      expect(resolution.resolvedPath, isNull);
      expect(resolution.isBatchLauncher, isTrue);
    });

    test('an unknown program is not resolved', () {
      final resolver = EditorExecutableResolver(const LocalFileSystem());

      final resolution = resolver.resolve(
        'editor',
        workingDirectory: directory.parent.path,
        environment: <String, String>{'PATH': directory.path},
      );

      expect(resolution.resolvedPath, isNull);
      expect(resolution.isBatchLauncher, isFalse);
    });

    test('the working directory shadows the search path only on windows', () {
      final working = Directory(
        p.join(directory.parent.path, 'agent resource working'),
      )..createSync(recursive: true);
      addTearDown(() => working.deleteSync(recursive: true));
      final name = programName('editor');
      File(p.join(working.path, name)).writeAsBytesSync(<int>[1]);
      File(p.join(directory.path, name)).writeAsBytesSync(<int>[1]);
      final resolver = EditorExecutableResolver(const LocalFileSystem());

      final resolution = resolver.resolve(
        'editor',
        workingDirectory: working.path,
        environment: <String, String>{'PATH': directory.path},
      );

      if (Platform.isWindows) {
        expect(resolution.resolvedPath, p.join(working.path, name));
      } else {
        expect(resolution.resolvedPath, p.join(directory.path, name));
      }
    });

    test('a program of another spelling is not selected on a posix system', () {
      final other = Platform.isWindows ? 'Editor.exe' : 'Editor';
      File(p.join(directory.path, other)).writeAsBytesSync(<int>[1]);
      final resolver = EditorExecutableResolver(const LocalFileSystem());

      final resolution = resolver.resolve(
        'editor',
        workingDirectory: directory.parent.path,
        environment: <String, String>{'PATH': directory.path},
      );

      if (Platform.isWindows) {
        expect(resolution.resolvedPath, p.join(directory.path, other));
      } else {
        expect(resolution.resolvedPath, isNull);
      }
    });

    test('a linked program is a program', () {
      final program = File(p.join(directory.path, 'real-editor'))
        ..writeAsBytesSync(<int>[1]);
      final name = programName('editor');
      final link = Link(p.join(directory.path, name));
      try {
        link.createSync(program.path);
      } on FileSystemException {
        markTestSkipped('The system does not allow symbolic links.');
        return;
      }
      final resolver = EditorExecutableResolver(const LocalFileSystem());

      final resolution = resolver.resolve(
        name,
        workingDirectory: directory.parent.path,
        environment: <String, String>{'PATH': directory.path},
      );

      expect(resolution.resolvedPath, p.join(directory.path, name));
    });
  });

  group('the real program runner', () {
    test('a batch launcher is refused at the launch boundary', () async {
      final runner = const RealEditorProcessRunner();

      final outcome = await runner.run(
        EditorProcessRequest(
          executable: p.join('some', 'where', 'editor.cmd'),
          arguments: const <String>['draft.txt'],
          environment: Platform.environment,
        ),
      );

      expect(outcome.started, isFalse);
      expect(outcome.reason, contains('batch launcher'));
    });

    test('the arguments of a program keep their boundaries', () async {
      final directory = await Directory.systemTemp.createTemp(
        'agent resource transport ',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      final script = File(p.join(directory.path, 'helper.dart'));
      await script.writeAsString('''
import 'dart:io';

void main(List<String> arguments) {
  File(arguments[0]).writeAsStringSync(arguments.sublist(1).join('\\u0000'));
}
''');
      final recorded = File(p.join(directory.path, 'arguments.txt'));
      final runner = const RealEditorProcessRunner();

      final outcome = await runner.run(
        EditorProcessRequest(
          executable: Platform.resolvedExecutable,
          arguments: <String>[
            script.path,
            recorded.path,
            'a path with spaces & | characters',
            'second argument',
          ],
          environment: Platform.environment,
          awaitCompletion: true,
        ),
      );

      expect(outcome.started, isTrue);
      expect(outcome.exitCode, 0);
      final values = (await recorded.readAsString()).split('\u0000');
      expect(values, <String>[
        'a path with spaces & | characters',
        'second argument',
      ]);
    });

    test('a parent that launches a long-lived program without a wait exits at '
        'once', () async {
      final directory = Directory(
        p.join(
          Directory.current.path,
          'build',
          'editor-lifecycle-${DateTime.now().microsecondsSinceEpoch}',
        ),
      )..createSync(recursive: true);
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final helper = File(p.join(directory.path, 'helper.dart'));
      await helper.writeAsString('''
import 'dart:io';

void main(List<String> arguments) {
  File(arguments[0]).writeAsStringSync('\$pid');
  sleep(const Duration(seconds: 30));
}
''');
      final parent = File(p.join(directory.path, 'parent.dart'));
      await parent.writeAsString('''
import 'dart:io';

import 'package:agent_resource/src/authoring/editor_interaction.dart';
import 'package:agent_resource/src/authoring/editor_process.dart';

Future<void> main(List<String> arguments) async {
  final watch = Stopwatch()..start();
  final outcome = await const RealEditorProcessRunner().run(
    EditorProcessRequest(
      executable: arguments[0],
      arguments: <String>[arguments[1], arguments[2]],
      environment: Platform.environment,
    ),
  );
  watch.stop();
  // The report is a file: the launched program inherits the streams of the
  // parent, so the stream of the parent stays open while it runs on.
  File(arguments[3]).writeAsStringSync(
    '\${outcome.started}\\n\${watch.elapsedMilliseconds}\\n',
  );
}
''');
      final pidFile = File(p.join(directory.path, 'helper.pid'));
      final reportFile = File(p.join(directory.path, 'report.txt'));
      final process = await Process.start(Platform.resolvedExecutable, <String>[
        '--packages=${p.join(Directory.current.path, '.dart_tool', 'package_config.json')}',
        parent.path,
        Platform.resolvedExecutable,
        helper.path,
        pidFile.path,
        reportFile.path,
      ], workingDirectory: Directory.current.path);
      addTearDown(() => process.kill(ProcessSignal.sigkill));

      final code = await process.exitCode.timeout(
        const Duration(seconds: 20),
        onTimeout: () => -1,
      );
      await _stopHelper(pidFile);

      expect(
        code,
        0,
        reason:
            'The parent did not exit; it waited for the program it launched.',
      );
      // The parent reports the duration of its own launch, so that the
      // measurement covers the launch and not the start-up of the parent.
      final lines = reportFile.readAsStringSync().trim().split('\n');
      expect(lines.first, 'true');
      final elapsed = int.tryParse(lines.last) ?? -1;
      expect(
        elapsed,
        lessThan(5000),
        reason:
            'The launch waited for the program it launched; a detached launch '
            'returns at once while the helper runs on for 30 seconds.',
      );
    });
  });
}

/// Stops the helper program of the lifecycle test.
///
/// The helper is bounded by its own runtime, but the test never leaves it
/// behind: it is stopped as soon as the parent is gone.
Future<void> _stopHelper(File pidFile) async {
  int? pid;
  for (var attempt = 0; attempt < 100; attempt++) {
    if (pidFile.existsSync()) {
      pid = int.tryParse(pidFile.readAsStringSync().trim());
      if (pid != null) break;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (pid == null) return;
  try {
    Process.killPid(pid, ProcessSignal.sigkill);
  } on Exception {
    return;
  }
  for (var attempt = 0; attempt < 100; attempt++) {
    try {
      Process.killPid(pid);
    } on Exception {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
