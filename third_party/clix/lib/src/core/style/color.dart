/// CLI Color System - Comprehensive terminal color management
///
/// Provides a complete color system for terminal applications with:
/// - **RGB Color Support**: Full 24-bit color definition
/// - **Hex Color Parsing**: Easy hex string to color conversion
/// - **25+ Predefined Colors**: Common and semantic colors
/// - **Background Colors**: Apply colors to text backgrounds
/// - **Professional Color Scheme**: Carefully chosen primary/secondary colors
///
/// ## Key Features:
/// - **Text Coloring**: Apply colors to any text string
/// - **Background Coloring**: Color text backgrounds
/// - **Combined Styling**: Mix text and background colors
/// - **Semantic Colors**: success, warning, error, info
/// - **Professional Palette**: Modern cyan primary, warm orange secondary
///
/// ## Usage Examples:
/// ```dart
/// // Use predefined colors
/// print(CliColor.primary('Important text'));
/// print(CliColor.success('Operation completed!'));
/// print(CliColor.error('Something went wrong'));
///
/// // Create custom colors
/// final customColor = CliColor.rgb(120, 80, 200);
/// print(customColor('Purple text'));
///
/// // Use hex colors
/// final brandColor = CliColor.hex('#FF6B35');
/// print(brandColor('Brand colored text'));
///
/// // Background coloring
/// print(CliColor.primary.background('Highlighted text'));
///
/// // Combined text and background
/// print(CliColor.withBackground(
///   'Important message',
///   textColor: CliColor.white,
///   backgroundColor: CliColor.error,
/// ));
/// ```
class CliColor {
  /// **RGB Values** - Red, green, and blue components (0-255)
  final int r, g, b;

  /// **Create RGB Color** - Define color with red, green, blue values
  ///
  /// ```dart
  /// final purple = CliColor.rgb(128, 0, 128);
  /// final brightRed = CliColor.rgb(255, 0, 0);
  /// ```
  const CliColor.rgb(this.r, this.g, this.b);

  /// **Create Color from Hex String** - Convert hex string to color
  ///
  /// Supports both formats: "#FF5733" and "FF5733"
  ///
  /// ```dart
  /// final orange = CliColor.hex('#FF5733');
  /// final blue = CliColor.hex('0066CC');
  /// ```
  ///
  /// Throws [ArgumentError] if hex string is not exactly 6 characters
  factory CliColor.hex(String hex) {
    final cleanHex = hex.replaceAll('#', '');
    if (cleanHex.length != 6) {
      throw ArgumentError('Hex color must be 6 characters');
    }
    final r = int.parse(cleanHex.substring(0, 2), radix: 16);
    final g = int.parse(cleanHex.substring(2, 4), radix: 16);
    final b = int.parse(cleanHex.substring(4, 6), radix: 16);
    return CliColor.rgb(r, g, b);
  }

  /// **Apply Color to Text** - Color the given text string
  ///
  /// Returns text wrapped with ANSI color codes for terminal display.
  ///
  /// ```dart
  /// final red = CliColor.red;
  /// print(red('This text is red'));
  /// // or use call syntax:
  /// print(red.call('This text is red'));
  /// ```
  String call(String text) {
    return '\x1B[38;2;$r;$g;${b}m$text\x1B[0m';
  }

  /// **Apply Color as Background** - Use this color as text background
  ///
  /// Returns text with colored background for highlighting and emphasis.
  ///
  /// ```dart
  /// print(CliColor.yellow.background('Important notice'));
  /// print(CliColor.error.background('Critical error'));
  /// ```
  String background(String text) {
    return '\x1B[48;2;$r;$g;${b}m$text\x1B[0m';
  }

  /// **Combined Text and Background Colors** - Apply both text and background colors
  ///
  /// Allows full control over text appearance with both foreground and background colors.
  /// Perfect for creating highlighted messages, alerts, and emphasized text.
  ///
  /// ```dart
  /// // White text on red background for errors
  /// print(CliColor.withBackground(
  ///   'CRITICAL ERROR',
  ///   textColor: CliColor.white,
  ///   backgroundColor: CliColor.error,
  /// ));
  ///
  /// // Black text on yellow background for warnings
  /// print(CliColor.withBackground(
  ///   'WARNING: Check configuration',
  ///   textColor: CliColor.black,
  ///   backgroundColor: CliColor.warning,
  /// ));
  /// ```
  static String withBackground(
    String text, {
    CliColor? textColor,
    CliColor? backgroundColor,
  }) {
    if (textColor == null && backgroundColor == null) {
      return text;
    }

    String escape = '\x1B[';
    List<String> codes = [];

    if (textColor != null) {
      codes.add('38;2;${textColor.r};${textColor.g};${textColor.b}');
    }

    if (backgroundColor != null) {
      codes.add(
        '48;2;${backgroundColor.r};${backgroundColor.g};${backgroundColor.b}',
      );
    }

    return '$escape${codes.join(';')}m$text\x1B[0m';
  }

  // ==========================================
  //  PREDEFINED COLORS - Ready to use colors for all applications
  // ==========================================

  /// **Primary & Secondary Colors** - Main branding and accent colors
  ///
  /// Professional color scheme optimized for CLI applications:
  /// - **Primary (Cyan)**: Modern, vibrant, attention-grabbing
  /// - **Secondary (Dark Orange)**: Professional complement, warm balance
  ///
  /// ```dart
  /// print(CliColor.primary('Main action button'));
  /// print(CliColor.secondary('Secondary information'));
  /// ```
  static const primary = CliColor.rgb(0, 255, 255); // Cyan - vibrant and modern
  static const secondary = CliColor.rgb(
    255,
    140,
    0,
  ); // Dark Orange - professional complement

  /// **Basic Colors** - Standard color palette
  ///
  /// Core colors available in all terminal environments.
  /// Perfect for general text coloring and basic styling.
  ///
  /// ```dart
  /// print(CliColor.red('Error message'));
  /// print(CliColor.green('Success message'));
  /// print(CliColor.blue('Information'));
  /// print(CliColor.yellow('Warning text'));
  /// ```
  static const red = CliColor.rgb(255, 0, 0); // Bright red
  static const green = CliColor.rgb(0, 255, 0); // Bright green
  static const blue = CliColor.rgb(0, 0, 255); // Bright blue
  static const yellow = CliColor.rgb(255, 255, 0); // Bright yellow
  static const cyan = CliColor.rgb(0, 255, 255); // Bright cyan
  static const magenta = CliColor.rgb(255, 0, 255); // Bright magenta
  static const white = CliColor.rgb(255, 255, 255); // Pure white
  static const black = CliColor.rgb(0, 0, 0); // Pure black

  /// **Extended Colors** - Additional color variations
  ///
  /// Expanded palette for more styling options and visual variety.
  /// Includes warm colors, neutrals, and darker shades.
  ///
  /// ```dart
  /// print(CliColor.orange('Warm message'));
  /// print(CliColor.purple('Royal text'));
  /// print(CliColor.gray('Subdued information'));
  /// ```
  static const orange = CliColor.rgb(255, 165, 0); // Standard orange
  static const purple = CliColor.rgb(128, 0, 128); // Deep purple
  static const pink = CliColor.rgb(255, 192, 203); // Soft pink
  static const brown = CliColor.rgb(165, 42, 42); // Earth brown
  static const gray = CliColor.rgb(128, 128, 128); // Medium gray
  static const darkGray = CliColor.rgb(64, 64, 64); // Dark gray
  static const lightGray = CliColor.rgb(192, 192, 192); // Light gray

  /// **Semantic Colors** - Meaning-based colors for consistent UX
  ///
  /// Semantic colors provide consistent meaning across your application:
  /// - **Success**: Positive outcomes, completions, confirmations
  /// - **Warning**: Cautions, potential issues, important notices
  /// - **Error**: Problems, failures, critical issues
  /// - **Info**: General information, tips, neutral messages
  ///
  /// ```dart
  /// print(CliColor.success('Operation completed successfully'));
  /// print(CliColor.warning('Configuration file not found'));
  /// print(CliColor.error('Connection failed'));
  /// print(CliColor.info('Processing 1,245 files...'));
  /// ```
  static const success = CliColor.rgb(0, 255, 0); // Green - positive outcomes
  static const warning = CliColor.rgb(255, 255, 0); // Yellow - cautions
  static const error = CliColor.rgb(255, 0, 0); // Red - problems
  static const info = CliColor.rgb(
    30,
    144,
    255,
  ); // Dodger blue - neutral information

  /// **High Contrast Colors** - Optimized for background usage
  ///
  /// Specially tuned colors for background applications and high contrast needs.
  /// Perfect for highlighting, selections, and emphasis where readability is critical.
  ///
  /// ```dart
  /// // Use for highlighting important information
  /// print(CliColor.brightYellow.background('HIGHLIGHTED'));
  /// print(CliColor.darkCyan.background('Selected item'));
  /// ```
  static const brightYellow = CliColor.rgb(
    255,
    255,
    100,
  ); // Bright yellow for emphasis
  static const brightCyan = CliColor.rgb(
    100,
    255,
    255,
  ); // Bright cyan for highlighting
  static const lightYellow = CliColor.rgb(
    255,
    255,
    200,
  ); // Soft yellow background
  static const darkCyan = CliColor.rgb(0, 200, 200); // Dark cyan for contrast

  /// **Enhanced Red Variants** - Multiple red shades for different contexts
  ///
  /// Various red tones for different severity levels and background needs.
  /// Useful for error messages, alerts, and critical information.
  ///
  /// ```dart
  /// print(CliColor.error('Standard error'));      // Bright red
  /// print(CliColor.darkRed('Serious warning'));   // Darker red
  /// print(CliColor.deepRed('Critical alert'));    // Deep red
  /// print(CliColor.maroon('System error'));       // Dark maroon
  /// ```
  static const darkRed = CliColor.rgb(180, 0, 0); // Dark red for serious issues
  static const deepRed = CliColor.rgb(
    139,
    0,
    0,
  ); // Deep red for critical alerts
  static const maroon = CliColor.rgb(
    128,
    0,
    0,
  ); // Maroon for system-level errors
}
