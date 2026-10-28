/// Custom exception for CLI argument parsing errors
class CliArgException implements Exception {
  final String message;

  const CliArgException(this.message);

  @override
  String toString() => 'Argument error: $message';
}
