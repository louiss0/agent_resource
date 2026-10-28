import 'dart:async';
import 'dart:io';

import 'cli_test_result.dart';

/// A utility class for running and testing CLI commands.
class CliTestRunner {
  /// Runs a Dart script and returns the test result
  static Future<CliTestResult> runDartScript(
    String scriptPath, {
    List<String>? arguments,
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    return _runCommand(
      'dart',
      ['run', scriptPath, ...?arguments],
      workingDirectory: workingDirectory,
      environment: environment,
      timeout: timeout,
    );
  }

  /// Runs a Flutter command and returns the test result
  static Future<CliTestResult> runFlutterCommand(
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    return _runCommand(
      'flutter',
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeout: timeout,
    );
  }

  /// Runs any command and returns the test result
  static Future<CliTestResult> runCommand(
    String command,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    return _runCommand(
      command,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      timeout: timeout,
    );
  }

  /// Internal method to run commands
  static Future<CliTestResult> _runCommand(
    String command,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    Duration? timeout,
  }) async {
    final stopwatch = Stopwatch()..start();

    try {
      final result =
          await Process.run(
            command,
            arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            runInShell: Platform.isWindows,
          ).timeout(
            timeout ?? const Duration(minutes: 5),
            onTimeout: () {
              throw TimeoutException(
                'Command timed out after ${timeout?.inSeconds ?? 300} seconds',
                timeout,
              );
            },
          );

      stopwatch.stop();

      return CliTestResult(
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
        exitCode: result.exitCode,
        duration: stopwatch.elapsed,
        context: {
          'command': command,
          'arguments': arguments,
          'workingDirectory': workingDirectory,
        },
      );
    } catch (e) {
      stopwatch.stop();

      return CliTestResult(
        stdout: '',
        stderr: 'Error running command: $e',
        exitCode: -1,
        duration: stopwatch.elapsed,
        context: {
          'command': command,
          'arguments': arguments,
          'error': e.toString(),
        },
      );
    }
  }

  /// Validates that a test result meets certain criteria
  static bool validate(
    CliTestResult result, {
    bool expectSuccess = true,
    bool expectOutput = false,
    bool expectErrors = false,
    List<String>? containsInStdout,
    List<String>? containsInStderr,
    List<String>? notContainsInStdout,
    List<String>? notContainsInStderr,
  }) {
    // Check success/failure expectation
    if (expectSuccess && result.isFailure) return false;
    if (!expectSuccess && result.isSuccess) return false;

    // Check output expectation
    if (expectOutput && !result.hasOutput) return false;
    if (!expectOutput && result.hasOutput) return false;

    // Check errors expectation
    if (expectErrors && !result.hasErrors) return false;
    if (!expectErrors && result.hasErrors) return false;

    // Check stdout contains
    if (containsInStdout != null) {
      for (final text in containsInStdout) {
        if (!result.stdout.contains(text)) return false;
      }
    }

    // Check stderr contains
    if (containsInStderr != null) {
      for (final text in containsInStderr) {
        if (!result.stderr.contains(text)) return false;
      }
    }

    // Check stdout does not contain
    if (notContainsInStdout != null) {
      for (final text in notContainsInStdout) {
        if (result.stdout.contains(text)) return false;
      }
    }

    // Check stderr does not contain
    if (notContainsInStderr != null) {
      for (final text in notContainsInStderr) {
        if (result.stderr.contains(text)) return false;
      }
    }

    return true;
  }

  /// Runs multiple test scenarios and returns a summary
  static Future<CliTestSummary> runTestSuite(
    Map<String, Future<CliTestResult> Function()> tests,
  ) async {
    final results = <String, CliTestResult>{};
    final errors = <String, String>{};

    for (final entry in tests.entries) {
      try {
        results[entry.key] = await entry.value();
      } catch (e) {
        errors[entry.key] = e.toString();
      }
    }

    return CliTestSummary(results: results, errors: errors);
  }
}

/// Summary of multiple test results
class CliTestSummary {
  final Map<String, CliTestResult> results;
  final Map<String, String> errors;

  const CliTestSummary({required this.results, required this.errors});

  /// Number of successful tests
  int get successCount => results.values.where((r) => r.isSuccess).length;

  /// Number of failed tests
  int get failureCount => results.values.where((r) => r.isFailure).length;

  /// Number of tests with errors
  int get errorCount => errors.length;

  /// Total number of tests
  int get totalCount => results.length + errors.length;

  /// Whether all tests passed
  bool get allPassed => failureCount == 0 && errorCount == 0;

  /// Generate a formatted report
  String generateReport() {
    final buffer = StringBuffer();
    buffer.writeln('Test Summary:');
    buffer.writeln('  Total: $totalCount');
    buffer.writeln('  Passed: $successCount');
    buffer.writeln('  Failed: $failureCount');
    buffer.writeln('  Errors: $errorCount');

    if (failureCount > 0 || errorCount > 0) {
      buffer.writeln('\nFailures:');
      for (final entry in results.entries) {
        if (entry.value.isFailure) {
          buffer.writeln('  ${entry.key}: ${entry.value.stderr}');
        }
      }

      if (errors.isNotEmpty) {
        buffer.writeln('\nErrors:');
        for (final entry in errors.entries) {
          buffer.writeln('  ${entry.key}: ${entry.value}');
        }
      }
    }

    return buffer.toString();
  }
}
