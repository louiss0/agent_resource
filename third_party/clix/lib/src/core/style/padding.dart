/// Enum for controlling padding inside background colors
///
/// This enum provides predefined padding options for text within colored backgrounds,
/// allowing for better visual spacing and readability.
///
/// Example usage:
/// ```dart
/// logger.onRed('Message', padding: Padding.medium);
/// // Result: [  Message  ] with spaces inside the background
///
/// logger.onGreen('Alert', padding: Padding.large);
/// // Result: [    Alert    ] with more spaces inside
/// ```
enum Padding {
  /// No padding - text touches background edges
  /// Example: [Message]
  none(0),

  /// Small padding - 1 space on each side
  /// Example: [ Message ]
  small(1),

  /// Medium padding - 2 spaces on each side
  /// Example: [  Message  ]
  medium(2),

  /// Large padding - 3 spaces on each side
  /// Example: [   Message   ]
  large(3),

  /// Extra large padding - 4 spaces on each side
  /// Example: [    Message    ]
  extraLarge(4),

  /// Custom padding for special cases - 5 spaces on each side
  /// Example: [     Message     ]
  huge(5);

  const Padding(this.spaces);

  /// Number of spaces to add on each side of the text
  final int spaces;

  /// Get the padding string (spaces before text)
  String get leftPadding => ' ' * spaces;

  /// Get the padding string (spaces after text)
  String get rightPadding => ' ' * spaces;

  /// Apply padding to text (both sides)
  String apply(String text) => '$leftPadding$text$rightPadding';
}
