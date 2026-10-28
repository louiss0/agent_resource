/// Enum for controlling spacing between lines in multi-line logging
///
/// This enum provides predefined line spacing options for better control
/// and prevents excessive spacing that could make output unreadable.
///
/// Example usage:
/// ```dart
/// logger.lines(['Line 1', 'Line 2'], lineSpacing: LineSpacing.single);
/// // Result:
/// // Line 1
/// //
/// // Line 2
/// ```
enum LineSpacing {
  /// No spacing between lines (default)
  /// Lines appear directly one after another
  none(0),

  /// Single empty line between each line
  /// Standard spacing for better readability
  single(1),

  /// Double empty lines between each line
  /// More prominent separation
  double(2),

  /// Triple empty lines between each line
  /// Maximum spacing for very distinct sections
  triple(3);

  const LineSpacing(this.lines);

  /// Number of empty lines to add between content lines
  final int lines;

  /// Get the spacing string (newlines)
  String get spacing => '\n' * lines;
}
