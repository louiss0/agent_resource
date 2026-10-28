/// Basic pass-through text formatter implementation
///
/// Provides a simple formatter that returns text unchanged. This is the
/// default formatter implementation when no special text processing is
/// needed. Useful as a null-object pattern or baseline formatter.
///
/// Features:
/// - Returns input text without modification
/// - Zero overhead text processing
/// - Safe default for all text types
/// - Base implementation for custom formatters
///
/// Usage:
/// ```dart
/// final formatter = BasicFormatter();
/// String result = formatter.format('Hello World');
/// print(result); // Output: Hello World
///
/// // Use as default in CLI components
/// class Logger {
///   final CliFormatter _formatter;
///   Logger({CliFormatter? formatter})
///     : _formatter = formatter ?? BasicFormatter();
/// }
/// ```
library;

import 'formatter.dart';

class BasicFormatter implements CliFormatter {
  @override
  String format(String message) => message;
}
