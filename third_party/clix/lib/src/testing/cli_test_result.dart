/// Represents the result of executing a CLI command or test.
class CliTestResult {
  /// The standard output from the command
  final String stdout;

  /// The standard error from the command
  final String stderr;

  /// The exit code from the command
  final int exitCode;

  /// The duration the command took to execute
  final Duration? duration;

  /// Additional context or metadata
  final Map<String, dynamic>? context;

  const CliTestResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
    this.duration,
    this.context,
  });

  /// Returns true if the command executed successfully (exit code 0)
  bool get isSuccess => exitCode == 0;

  /// Returns true if the command failed (non-zero exit code)
  bool get isFailure => exitCode != 0;

  /// Returns true if there are errors in stderr
  bool get hasErrors => stderr.trim().isNotEmpty;

  /// Returns true if there is output in stdout
  bool get hasOutput => stdout.trim().isNotEmpty;

  /// Returns the combined output (stdout + stderr)
  String get combinedOutput {
    final buffer = StringBuffer();
    if (stdout.isNotEmpty) buffer.writeln(stdout);
    if (stderr.isNotEmpty) buffer.writeln(stderr);
    return buffer.toString().trim();
  }

  /// Creates a successful test result
  static CliTestResult success({
    required String stdout,
    String stderr = '',
    Duration? duration,
    Map<String, dynamic>? context,
  }) {
    return CliTestResult(
      stdout: stdout,
      stderr: stderr,
      exitCode: 0,
      duration: duration,
      context: context,
    );
  }

  /// Creates a failed test result
  static CliTestResult failure({
    String stdout = '',
    required String stderr,
    required int exitCode,
    Duration? duration,
    Map<String, dynamic>? context,
  }) {
    return CliTestResult(
      stdout: stdout,
      stderr: stderr,
      exitCode: exitCode,
      duration: duration,
      context: context,
    );
  }

  @override
  String toString() {
    return 'CliTestResult(exitCode: $exitCode, hasOutput: $hasOutput, hasErrors: $hasErrors)';
  }
}
