/// CLI Style System - Complete text styling and formatting
///
/// Comprehensive styling system for terminal text with:
/// - Text Colors & Backgrounds: Full color support
/// - Text Formatting: Bold, italic, underline, strikethrough
/// - Visual Effects: Dim, blink, reverse effects
/// - Interactive Symbols: Selection, checkboxes, radio buttons
/// - Navigation Icons: Arrows, progress indicators
/// - Status Symbols: Success, error, warning indicators
///
/// Key Features:
/// - Chainable Styling: Combine multiple effects easily
/// - Rich Symbol Library: 20+ predefined symbols
/// - Cross-Platform: Works on all terminal types
/// - Performance Optimized: Efficient ANSI code generation
///
/// Usage Examples:
/// ```dart
/// // Basic text styling
/// final style = CliStyle(color: CliColor.cyan, bold: true);
/// print(style.apply('Important message'));
///
/// // Interactive elements
/// print('${CliStyle.selectedPrefix} Selected item');
/// print('${CliStyle.checkedBox} Completed task');
/// print('${CliStyle.successSymbol} Operation successful');
///
/// // Complex styling
/// final errorStyle = CliStyle(
///   color: CliColor.white,
///   backgroundColor: CliColor.error,
///   bold: true,
/// );
/// print(errorStyle.apply('CRITICAL ERROR'));
/// ```
library;

import 'color.dart';

/// CliStyle - Advanced text styling and visual effects
///
/// Main styling class providing comprehensive text formatting capabilities
/// with support for colors, backgrounds, and text effects.
class CliStyle {
  /// Text Color - Foreground color for text display
  final CliColor? color;

  /// Background Color - Background color behind text
  final CliColor? backgroundColor;

  /// Text Effects - Various formatting options
  final bool bold; // Bold/thick text weight
  final bool italic; // Italicized text style
  final bool underline; // Underlined text
  final bool strikethrough; // Strike-through text
  final bool dim; // Dimmed/faded text
  final bool blink; // Blinking text effect
  final bool reverse; // Reversed colors (swap fg/bg)

  // PREDEFINED SYMBOLS - Ready-to-use visual elements

  /// Interactive Selection Symbols - For menus and lists
  ///
  /// Used in prompts, menus, and interactive selections:
  /// - selectedPrefix: Indicator for currently selected item
  /// - unselectedPrefix: Indicator for non-selected items
  ///
  /// ```dart
  /// print('${CliStyle.selectedPrefix} Selected option');
  /// print('${CliStyle.unselectedPrefix} Other option');
  /// ```
  static const String selectedPrefix = '❯'; // Pointer for selected items
  static const String unselectedPrefix = ' '; // Space for unselected items
  static const String selectedSuffix = ''; // Suffix for selected (none)
  static const String unselectedSuffix = ''; // Suffix for unselected (none)

  /// Checkbox Symbols - For multi-select and task lists
  ///
  /// Perfect for todo lists, feature selections, and multi-option prompts:
  /// - checkedBox: Completed/selected state
  /// - uncheckedBox: Available/unselected state
  /// - partiallyCheckedBox: Partially selected state
  ///
  /// ```dart
  /// print('${CliStyle.checkedBox} Install dependencies');
  /// print('${CliStyle.uncheckedBox} Run tests');
  /// print('${CliStyle.partiallyCheckedBox} Optional features');
  /// ```
  static const String checkedBox = '☑'; // Selected checkbox
  static const String uncheckedBox = '☐'; // Empty checkbox
  static const String partiallyCheckedBox = '☒'; // Partially checked

  /// Radio Button Symbols - For single-select options
  ///
  /// Used for exclusive choice selections and option groups:
  /// - radioSelected: Currently selected radio option
  /// - radioUnselected: Available but not selected option
  ///
  /// ```dart
  /// print('${CliStyle.radioSelected} Development mode');
  /// print('${CliStyle.radioUnselected} Production mode');
  /// ```
  static const String radioSelected = '●'; // Selected radio button
  static const String radioUnselected = '○'; // Unselected radio button

  /// Navigation Symbols - For directional guidance
  ///
  /// Navigation arrows and directional indicators for user guidance:
  ///
  /// ```dart
  /// print('Use ${CliStyle.upArrow}${CliStyle.downArrow} to navigate');
  /// print('Press ${CliStyle.rightArrow} to continue');
  /// print('${CliStyle.leftArrow} Back to menu');
  /// ```
  static const String upArrow = '↑'; // Up navigation
  static const String downArrow = '↓'; // Down navigation
  static const String leftArrow = '←'; // Left/back navigation
  static const String rightArrow = '→'; // Right/forward navigation

  /// Progress Bar Symbols - For visual progress indication
  ///
  /// Building blocks for creating custom progress bars and loading indicators:
  /// - emptyProgress: Empty/unfilled progress sections
  /// - filledProgress: Completed/filled progress sections
  /// - leadingProgress: Current progress position indicator
  ///
  /// ```dart
  /// // Custom progress bar: ████████░░ 80%
  /// final progress = '${CliStyle.filledProgress * 8}${CliStyle.emptyProgress * 2}';
  /// print('Progress: $progress 80%');
  /// ```
  static const String emptyProgress = '░'; // Empty progress block
  static const String filledProgress = '█'; // Filled progress block
  static const String leadingProgress = '█'; // Leading edge of progress

  /// Status Symbols - For operation and task status
  ///
  /// Clear visual indicators for different states and outcomes:
  /// - loading: Active operations in progress
  /// - completed: Successfully finished operations
  /// - failed: Operations that encountered errors
  /// - warning: Operations with warnings or concerns
  ///
  /// ```dart
  /// print('${CliStyle.loading} Installing packages...');
  /// print('${CliStyle.completed} Build successful');
  /// print('${CliStyle.failed} Test failed');
  /// print('${CliStyle.warning} Deprecated API used');
  /// ```
  static const String loading = '⣿'; // Loading/in-progress indicator
  static const String completed = '✓'; // Success/completion indicator
  static const String failed = '✗'; // Error/failure indicator
  static const String warning = '⚠'; // Warning/caution indicator

  /// Constructor - Create custom styled text
  ///
  /// Build custom styles by combining colors, backgrounds, and effects.
  /// All parameters are optional, allowing for flexible styling combinations.
  ///
  /// ```dart
  /// // Bold red text
  /// final errorStyle = CliStyle(color: CliColor.error, bold: true);
  ///
  /// // White text on blue background with underline
  /// final headerStyle = CliStyle(
  ///   color: CliColor.white,
  ///   backgroundColor: CliColor.blue,
  ///   underline: true,
  /// );
  ///
  /// // Dim italic text for comments
  /// final commentStyle = CliStyle(dim: true, italic: true);
  /// ```
  const CliStyle({
    this.color,
    this.backgroundColor,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.strikethrough = false,
    this.dim = false,
    this.blink = false,
    this.reverse = false,
  });

  /// Modifier Methods - Create new styles with additional properties

  /// Change Text Color - Create new style with different text color
  ///
  /// ```dart
  /// final baseStyle = CliStyle(bold: true);
  /// final redStyle = baseStyle.withColor(CliColor.red);
  /// ```
  CliStyle withColor(CliColor color) => CliStyle(
    color: color,
    backgroundColor: backgroundColor,
    bold: bold,
    italic: italic,
    underline: underline,
    strikethrough: strikethrough,
    dim: dim,
    blink: blink,
    reverse: reverse,
  );

  /// Change Background Color - Create new style with different background
  ///
  /// ```dart
  /// final style = CliStyle(color: CliColor.white);
  /// final highlightStyle = style.withBackgroundColor(CliColor.blue);
  /// ```
  CliStyle withBackgroundColor(CliColor color) => CliStyle(
    color: this.color,
    backgroundColor: color,
    bold: bold,
    italic: italic,
    underline: underline,
    strikethrough: strikethrough,
    dim: dim,
    blink: blink,
    reverse: reverse,
  );

  /// Text Effect Modifiers - Add formatting effects to existing styles
  ///
  /// Chain these methods to build complex styles:
  /// ```dart
  /// final fancyStyle = CliStyle()
  ///   .withColor(CliColor.cyan)
  ///   .makeBold()
  ///   .makeUnderline();
  /// ```
  CliStyle makeBold() => _copyWith(bold: true); // Make text bold
  CliStyle makeItalic() => _copyWith(italic: true); // Make text italic
  CliStyle makeUnderline() => _copyWith(underline: true); // Add underline
  CliStyle makeStrikethrough() =>
      _copyWith(strikethrough: true); // Add strikethrough
  CliStyle makeDim() => _copyWith(dim: true); // Make text dimmed
  CliStyle makeBlink() => _copyWith(blink: true); // Make text blink
  CliStyle makeReverse() => _copyWith(reverse: true); // Reverse colors

  CliStyle _copyWith({
    CliColor? color,
    CliColor? backgroundColor,
    bool? bold,
    bool? italic,
    bool? underline,
    bool? strikethrough,
    bool? dim,
    bool? blink,
    bool? reverse,
  }) => CliStyle(
    color: color ?? this.color,
    backgroundColor: backgroundColor ?? this.backgroundColor,
    bold: bold ?? this.bold,
    italic: italic ?? this.italic,
    underline: underline ?? this.underline,
    strikethrough: strikethrough ?? this.strikethrough,
    dim: dim ?? this.dim,
    blink: blink ?? this.blink,
    reverse: reverse ?? this.reverse,
  );

  /// Apply Style to Text - Transform text with all style settings
  ///
  /// Main method to apply the complete style (colors, background, effects) to text.
  /// This method combines all styling properties into properly formatted ANSI codes.
  ///
  /// ```dart
  /// final style = CliStyle(
  ///   color: CliColor.white,
  ///   backgroundColor: CliColor.error,
  ///   bold: true,
  ///   underline: true,
  /// );
  ///
  /// // Apply style to text
  /// print(style('CRITICAL ERROR'));
  /// // or explicitly:
  /// print(style.call('CRITICAL ERROR'));
  /// ```
  ///
  /// Performance Note: This method efficiently combines all style properties
  /// in the correct order for optimal terminal rendering.
  String call(String text) {
    var result = text;
    final codes = <int>[];

    // Text effects
    if (bold) codes.add(1);
    if (dim) codes.add(2);
    if (italic) codes.add(3);
    if (underline) codes.add(4);
    if (blink) codes.add(5);
    if (reverse) codes.add(7);
    if (strikethrough) codes.add(9);

    // Apply effects
    if (codes.isNotEmpty) {
      result = '\x1B[${codes.join(";")}m$result\x1B[0m';
    }

    // Apply colors
    if (backgroundColor != null) {
      final bg = backgroundColor!;
      result = '\x1B[48;2;${bg.r};${bg.g};${bg.b}m$result\x1B[0m';
    }
    if (color != null) {
      result = color!(result);
    }

    return result;
  }

  /// Plain Style Factory - Create unstyled/default style
  ///
  /// Returns a basic CliStyle with no colors, backgrounds, or effects.
  /// Useful as a starting point for building custom styles or for removing styling.
  ///
  /// ```dart
  /// final plainStyle = CliStyle.plain();
  /// final customStyle = plainStyle
  ///   .withColor(CliColor.blue)
  ///   .makeBold();
  /// ```
  static CliStyle plain() => CliStyle();
}
