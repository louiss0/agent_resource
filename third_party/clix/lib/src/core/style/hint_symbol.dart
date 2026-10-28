/// Enum for hint symbols and separators
///
/// This enum provides predefined symbols for hints and additional information,
/// allowing for better visual separation and clarity in messages.
///
/// Example usage:
/// ```dart
/// logger.messageWithHint('Build completed',
///   hint: 'Run tests next',
///   hintSymbol: HintSymbol.dot);
/// // Result: Build completed    • Run tests next
///
/// logger.messageWithHint('Error occurred',
///   hint: 'Check logs',
///   hintSymbol: HintSymbol.arrow);
/// // Result: Error occurred    → Check logs
/// ```
enum HintSymbol {
  /// No symbol - hint appears without prefix
  /// Example: Success    Next step
  none(''),

  /// Dot symbol - clean and minimal
  /// Example: Success    • Next step
  dot('•'),

  /// Arrow pointing right - indicates next action
  /// Example: Success    → Next step
  arrow('→'),

  /// Em dash - professional separator
  /// Example: Success    – Next step
  dash('–'),

  /// Pipe symbol - technical style separator
  /// Example: Success    | Next step
  pipe('|'),

  /// Chevron - modern directional indicator
  /// Example: Success    › Next step
  chevron('›'),

  /// Diamond - decorative separator
  /// Example: Success    ◆ Next step
  diamond('◆'),

  /// Triangle - action indicator
  /// Example: Success    ▶ Next step
  triangle('▶'),

  /// Double arrow - emphasis on next action
  /// Example: Success    ⇒ Next step
  doubleArrow('⇒'),

  /// Star symbol - highlight important hints
  /// Example: Success    ★ Next step
  star('★'),

  /// Info symbol - informational hints
  /// Example: Success    ℹ Next step
  info('ℹ'),

  /// Light bulb - tips and suggestions
  /// Example: Success    💡 Next step
  lightBulb('💡');

  const HintSymbol(this.symbol);

  /// The visual symbol character
  final String symbol;

  /// Check if this symbol needs spacing around it
  bool get needsSpacing => symbol.isNotEmpty;

  /// Apply symbol with proper spacing
  String apply(String hint) {
    if (symbol.isEmpty || hint.isEmpty) return hint;
    return '$symbol $hint';
  }

  /// Get symbol with spacing for inline use
  String get withSpacing => symbol.isEmpty ? '' : '$symbol ';
}
