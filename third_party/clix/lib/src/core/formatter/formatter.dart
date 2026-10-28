/// Abstract text formatter interface for CLI output
///
/// Defines the contract for text formatting implementations in CLI applications.
/// Formatters can transform raw text messages into styled, structured, or
/// modified output before display to the user.
///
/// Common use cases:
/// - Adding colors and styles to text
/// - Applying consistent formatting patterns
/// - Converting plain text to structured output
/// - Adding prefixes, suffixes, or decorations
/// - Implementing custom text transformations
///
/// Usage:
/// ```dart
/// CliFormatter formatter = BasicFormatter();
/// String formatted = formatter.format('Hello World');
///
/// // Custom implementation
/// class PrefixFormatter implements CliFormatter {
///   @override
///   String format(String message) => '[INFO] $message';
/// }
/// ```
library;

abstract class CliFormatter {
  String format(String message);
}
