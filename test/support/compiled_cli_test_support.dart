import 'dart:io';

import 'package:test/test.dart';

import 'process_test_support.dart';

/// Builds the current sources once per suite, outside individual test budgets.
/// Each invocation still runs the real entrypoint in its own isolated process.
/// A fresh temporary artifact avoids stale binaries after source/dependency edits.
Future<String> compileTestCli({
  required String script,
  required String packageConfig,
}) async {
  final directory = await Directory.systemTemp.createTemp('cli-test-kernel-');
  tearDownAll(() => directory.delete(recursive: true));
  try {
    final output = File.fromUri(directory.uri.resolve('agent_resource.dill'));
    final result = await runProcess(
      Platform.resolvedExecutable,
      [
        'compile',
        'kernel',
        '--packages=$packageConfig',
        '--output=${output.path}',
        script,
      ],
      workingDirectory: File(script).parent,
      environment: Platform.environment,
      timeout: const Duration(seconds: 90),
    );
    if (result.exitCode != 0 || !output.existsSync()) {
      throw StateError(
        'Failed to compile the process-test CLI (${result.exitCode}).\n'
        '${result.stdout}\n${result.stderr}',
      );
    }
    return output.path;
  } catch (_) {
    await directory.delete(recursive: true);
    rethrow;
  }
}
