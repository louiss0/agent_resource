/// Enum for controlling spacing between elements
///
/// This enum provides predefined spacing options between text elements,
/// allowing for better visual separation and readability.
///
/// Example usage:
/// ```dart
/// logger.messageWithHint('Success', hint: 'Next step', spacing: Spacing.medium);
/// // Result: Success    • Next step
///
/// logger.messageWithHint('Error', hint: 'Check logs', spacing: Spacing.large);
/// // Result: Error      • Check logs
/// ```
enum Spacing {
  /// No spacing - elements touch each other
  /// Example: Success• Next step
  none(0),

  /// Small spacing - 2 spaces between elements
  /// Example: Success  • Next step
  small(2),

  /// Medium spacing - 4 spaces between elements
  /// Example: Success    • Next step
  medium(4),

  /// Large spacing - 6 spaces between elements
  /// Example: Success      • Next step
  large(6),

  /// Extra large spacing - 8 spaces between elements
  /// Example: Success        • Next step
  extraLarge(8),

  /// Huge spacing - 10 spaces between elements
  /// Example: Success          • Next step
  huge(10);

  const Spacing(this.spaces);

  /// Number of spaces between elements
  final int spaces;

  /// Get the spacing string (spaces for separation)
  String get gap => ' ' * spaces;

  /// Apply spacing between two text elements
  String apply(String first, String second) => '$first$gap$second';

  /// Apply spacing with custom separator
  String applyWithSeparator(String first, String second, String separator) =>
      '$first$gap$separator$gap$second';
}
