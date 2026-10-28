/// Exception thrown when configuration operations fail
///
/// This exception provides detailed information about configuration errors,
/// including the specific context where the error occurred.
///
/// Example usage:
/// ```dart
/// try {
///   config.loadFromFile('invalid.json');
/// } catch (e) {
///   if (e is CliConfigException) {
///     print('Config error: ${e.message}');
///     print('Context: ${e.context}');
///   }
/// }
/// ```
class CliConfigException implements Exception {
  /// The error message describing what went wrong
  final String message;

  /// Optional context information about where the error occurred
  final String? context;

  /// Creates a new configuration exception
  ///
  /// [message] is the error description
  /// [context] is optional context information (e.g., file path, configuration key)
  const CliConfigException(this.message, [this.context]);

  @override
  String toString() {
    return context != null
        ? 'Configuration error in $context: $message'
        : 'Configuration error: $message';
  }
}
