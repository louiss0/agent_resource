/// CLI Logger - Advanced terminal logging with styling and progress tracking
library;

import '../core/io/cli_io.dart';
import '../core/io/console_io.dart';
import '../core/formatter/formatter.dart';
import '../core/formatter/basic_formatter.dart';
import '../core/style/theme.dart';
import '../core/style/color.dart';
import '../core/style/point_style.dart';
import '../core/style/padding.dart';
import '../core/style/spacing.dart';
import '../core/style/hint_symbol.dart';
import '../core/style/line_spacing.dart';
import '../core/icons/cli_icons.dart';
import '../core/indentation/indent_level.dart';
import '../core/indentation/tree_symbol.dart';
import '../progress/progress.dart';
import '../progress/enums/progress_style.dart';
import '../progress/spinner.dart';
import '../progress/enums/spinner_type.dart';
import '../progress/multi_spinner.dart';
import '../table/table.dart';
import 'log_level.dart';

/// **CliLogger - Main logging class with comprehensive CLI features**
///
/// Central logging system providing styled output, progress tracking, and data display.
/// Designed for professional CLI applications requiring rich terminal interaction.
class CliLogger {
  /// **IO Interface** - Input/output operations (console, mock, etc.)
  final CliIO io;

  /// **Theme Configuration** - Styling and color scheme
  final CliTheme theme;

  /// **Text Formatter** - Message formatting and layout
  final CliFormatter formatter;

  /// **Minimum Log Level** - Filter messages below this level
  LogLevel minimumLevel;

  /// **Timestamp Display** - Show timestamps with log messages
  bool showTimestamps;

  /// **Full Constructor** - Complete logger configuration
  ///
  /// Create a logger with full control over all components:
  /// ```dart
  /// final logger = CliLogger(
  ///   io: CustomIO(),                    // Custom IO implementation
  ///   theme: CliTheme.dark(),           // Dark theme
  ///   formatter: CustomFormatter(),     // Custom formatting
  ///   minimumLevel: LogLevel.info,      // Filter debug messages
  ///   showTimestamps: true,            // Show timestamps
  /// );
  /// ```
  CliLogger({
    CliIO? io,
    CliTheme? theme,
    CliFormatter? formatter,
    this.minimumLevel = LogLevel.plain,
    this.showTimestamps = false,
  }) : io = io ?? ConsoleIO(),
       theme = theme ?? CliTheme.defaultTheme(),
       formatter = formatter ?? BasicFormatter();

  /// **⚡ Quick Setup Constructor** - Logger with sensible defaults
  ///
  /// Create a logger with default settings, perfect for most applications:
  /// ```dart
  /// // Simple logger with defaults
  /// final logger = CliLogger.defaults();
  ///
  /// // With custom log level and timestamps
  /// final logger = CliLogger.defaults(
  ///   minimumLevel: LogLevel.info,
  ///   showTimestamps: true,
  /// );
  /// ```
  CliLogger.defaults({
    this.minimumLevel = LogLevel.plain,
    this.showTimestamps = false,
  }) : io = ConsoleIO(),
       theme = CliTheme.defaultTheme(),
       formatter = BasicFormatter();

  /// **🏭 Factory Constructor** - Alternative creation method
  ///
  /// Factory method providing the same functionality as the main constructor.
  /// Useful for dependency injection and testing scenarios:
  /// ```dart
  /// final logger = CliLogger.create(
  ///   io: MockIO(),
  ///   theme: CliTheme.dark(),
  ///   minimumLevel: LogLevel.debug,
  /// );
  /// ```
  factory CliLogger.create({
    CliIO? io,
    CliTheme? theme,
    CliFormatter? formatter,
    LogLevel minimumLevel = LogLevel.plain,
    bool showTimestamps = false,
  }) {
    return CliLogger(
      io: io ?? ConsoleIO(),
      theme: theme ?? CliTheme.defaultTheme(),
      formatter: formatter ?? BasicFormatter(),
      minimumLevel: minimumLevel,
      showTimestamps: showTimestamps,
    );
  }

  String _formatMessage(
    String message, {
    LogLevel? level,
    bool showPrefix = false,
  }) {
    var formatted = formatter.format(message);
    if (showTimestamps) {
      final timestamp = DateTime.now().toIso8601String();
      formatted = '[$timestamp] $formatted';
    }
    if (level != null && showPrefix) {
      final levelStr = level.name.toUpperCase();
      formatted = '[$levelStr] $formatted';
    }
    return formatted;
  }

  // ==========================================
  //  📝 LOGGING METHODS - Core message output functionality
  // ==========================================

  /// **🐛 Debug Logging** - Detailed debugging information
  ///
  /// Log technical details, variable states, and debugging information.
  /// Typically filtered out in production builds.
  ///
  /// ```dart
  /// logger.debug('Processing user input: $input');
  /// logger.debug('Cache hit rate: 85%', showPrefix: true);
  /// logger.debug('  Nested debug info', indent: IndentLevel.single);
  /// ```
  ///
  /// **Parameters:**
  /// - `message`: Debug message content
  /// - `showPrefix`: Add [DEBUG] prefix to message
  /// - `indent`: Indentation level for hierarchical messages
  void debug(
    String message, {
    bool showPrefix = false,
    IndentLevel indent = IndentLevel.none,
  }) {
    if (LogLevel.debug.shouldLog(minimumLevel)) {
      final indentedMessage = '${indent.spacing}$message';
      io.writeln(
        theme.debug(
          _formatMessage(
            indentedMessage,
            level: LogLevel.debug,
            showPrefix: showPrefix,
          ),
        ),
      );
    }
  }

  /// **ℹ️ Info Logging** - General information and status updates
  ///
  /// Log application status, progress updates, and general information.
  /// Most common logging level for user-facing messages.
  ///
  /// ```dart
  /// logger.info('Application started successfully');
  /// logger.info('Processing 1,245 files...', showPrefix: true);
  /// logger.info('  Configuration loaded', indent: IndentLevel.single);
  /// ```
  ///
  /// **Parameters:**
  /// - `message`: Information message content
  /// - `showPrefix`: Add [INFO] prefix to message
  /// - `indent`: Indentation level for message hierarchy
  void info(
    String message, {
    bool showPrefix = false,
    IndentLevel indent = IndentLevel.none,
  }) {
    if (LogLevel.info.shouldLog(minimumLevel)) {
      final indentedMessage = '${indent.spacing}$message';
      io.writeln(
        theme.info(
          _formatMessage(
            indentedMessage,
            level: LogLevel.info,
            showPrefix: showPrefix,
          ),
        ),
      );
    }
  }

  /// **⚠️ Warning Logging** - Cautions and potential issues
  ///
  /// Log warnings, deprecation notices, and non-critical issues that need attention.
  /// Indicates problems that don't stop execution but should be addressed.
  ///
  /// ```dart
  /// logger.warn('Configuration file not found, using defaults');
  /// logger.warn('API rate limit approaching', showPrefix: true);
  /// logger.warn('  Consider upgrading plan', indent: IndentLevel.single);
  /// ```
  ///
  /// **Parameters:**
  /// - `message`: Warning message content
  /// - `showPrefix`: Add [WARN] prefix to message
  /// - `indent`: Indentation level for message organization
  void warn(
    String message, {
    bool showPrefix = false,
    IndentLevel indent = IndentLevel.none,
  }) {
    if (LogLevel.warning.shouldLog(minimumLevel)) {
      final indentedMessage = '${indent.spacing}$message';
      io.writeln(
        theme.warn(
          _formatMessage(
            indentedMessage,
            level: LogLevel.warning,
            showPrefix: showPrefix,
          ),
        ),
      );
    }
  }

  /// **❌ Error Logging** - Critical errors and failures
  ///
  /// Log errors, exceptions, and critical failures that affect application operation.
  /// Used for problems that require immediate attention or cause functionality loss.
  ///
  /// ```dart
  /// logger.error('Database connection failed');
  /// logger.error('Invalid user credentials', showPrefix: true);
  /// logger.error('  Check connection settings', indent: IndentLevel.single);
  /// ```
  ///
  /// **Parameters:**
  /// - `message`: Error message content
  /// - `showPrefix`: Add [ERROR] prefix to message
  /// - `indent`: Indentation level for error details
  void error(
    String message, {
    bool showPrefix = false,
    IndentLevel indent = IndentLevel.none,
  }) {
    if (LogLevel.error.shouldLog(minimumLevel)) {
      final indentedMessage = '${indent.spacing}$message';
      io.writeln(
        theme.error(
          _formatMessage(
            indentedMessage,
            level: LogLevel.error,
            showPrefix: showPrefix,
          ),
        ),
      );
    }
  }

  /// **Success Logging** - Positive outcomes and completions
  ///
  /// Log successful operations, completions, and positive outcomes.
  /// Provides clear feedback when operations complete successfully.
  ///
  /// ```dart
  /// logger.success('Build completed successfully');
  /// logger.success('All tests passed', showPrefix: true);
  /// logger.success('  Coverage: 98%', indent: IndentLevel.single);
  /// ```
  ///
  /// **Parameters:**
  /// - `message`: Success message content
  /// - `showPrefix`: Add [SUCCESS] prefix to message
  /// - `indent`: Indentation level for success details
  void success(
    String message, {
    bool showPrefix = false,
    IndentLevel indent = IndentLevel.none,
  }) {
    if (LogLevel.success.shouldLog(minimumLevel)) {
      final indentedMessage = '${indent.spacing}$message';
      io.writeln(
        theme.success(
          _formatMessage(
            indentedMessage,
            level: LogLevel.success,
            showPrefix: showPrefix,
          ),
        ),
      );
    }
  }

  /// **📄 Plain Logging** - Unstyled output for raw content
  ///
  /// Log messages without special styling or semantic meaning.
  /// Perfect for outputting raw data, file contents, or user-generated content.
  ///
  /// ```dart
  /// logger.plain('Raw output data');
  /// logger.plain('File contents: Hello World');
  /// logger.plain('  Indented content', indent: IndentLevel.single);
  /// ```
  ///
  /// **Parameters:**
  /// - `message`: Plain message content
  /// - `showPrefix`: Add [PLAIN] prefix (rarely used)
  /// - `indent`: Indentation level for content organization
  void plain(
    String message, {
    bool showPrefix = false,
    IndentLevel indent = IndentLevel.none,
  }) {
    if (LogLevel.plain.shouldLog(minimumLevel)) {
      final indentedMessage = '${indent.spacing}$message';
      io.writeln(
        theme.plain(
          _formatMessage(
            indentedMessage,
            level: LogLevel.plain,
            showPrefix: showPrefix,
          ),
        ),
      );
    }
  }

  /// Print results without prefix or level
  void result(String message) {
    io.writeln(theme.primary(formatter.format(message)));
  }

  /// Print in the package's primary color
  void primary(String message, {IndentLevel indent = IndentLevel.none}) {
    final indentedMessage = '${indent.spacing}${formatter.format(message)}';
    io.writeln(theme.primary(indentedMessage));
  }

  /// Print in the package's secondary color
  void secondary(String message, {IndentLevel indent = IndentLevel.none}) {
    final indentedMessage = '${indent.spacing}${formatter.format(message)}';
    io.writeln(theme.secondary(indentedMessage));
  }

  /// Print in white for important texts
  void white(String message, {IndentLevel indent = IndentLevel.none}) {
    final indentedMessage = '${indent.spacing}${formatter.format(message)}';
    io.writeln(CliColor.white(indentedMessage));
  }

  /// Print in red
  void red(String message, {IndentLevel indent = IndentLevel.none}) {
    final indentedMessage = '${indent.spacing}${formatter.format(message)}';
    io.writeln(CliColor.red(indentedMessage));
  }

  /// Print in green
  void green(String message, {IndentLevel indent = IndentLevel.none}) {
    final indentedMessage = '${indent.spacing}${formatter.format(message)}';
    io.writeln(CliColor.green(indentedMessage));
  }

  /// Print in blue
  void blue(String message, {IndentLevel indent = IndentLevel.none}) {
    final indentedMessage = '${indent.spacing}${formatter.format(message)}';
    io.writeln(CliColor.blue(indentedMessage));
  }

  /// Print in yellow
  void yellow(String message, {IndentLevel indent = IndentLevel.none}) {
    final indentedMessage = '${indent.spacing}${formatter.format(message)}';
    io.writeln(CliColor.yellow(indentedMessage));
  }

  /// Print in cyan
  void cyan(String message, {IndentLevel indent = IndentLevel.none}) {
    final indentedMessage = '${indent.spacing}${formatter.format(message)}';
    io.writeln(CliColor.cyan(indentedMessage));
  }

  // Background color methods

  /// Print with custom background and text colors
  void onBackground(
    String message, {
    CliColor? textColor,
    CliColor? backgroundColor,
    IndentLevel indent = IndentLevel.none,
    Padding padding = Padding.none,
  }) {
    final formattedMessage = formatter.format(message);
    final paddedMessage = padding.apply(formattedMessage);
    final backgroundMessage = CliColor.withBackground(
      paddedMessage,
      textColor: textColor,
      backgroundColor: backgroundColor,
    );
    // Print indent spaces without background, then message with background
    io.writeln('${indent.spacing}$backgroundMessage');
  }

  /// Print with red background
  void onRed(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.white,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.red,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with green background
  void onGreen(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.black,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.green,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with blue background
  void onBlue(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.white,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.blue,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with yellow background
  void onYellow(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.black,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.yellow,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with white background
  void onWhite(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.black,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.white,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with black background
  void onBlack(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.white,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.black,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with cyan background
  void onCyan(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.black,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.cyan,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with magenta background
  void onMagenta(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.white,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.magenta,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with success background (green)
  void onSuccess(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.black,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.success,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with error background (red)
  void onError(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.white,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.error,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with warning background (yellow)
  void onWarning(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.black,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.warning,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with info background (cyan)
  void onInfo(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.black,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.info,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with primary background
  void onPrimary(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.black,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.primary,
      indent: indent,
      padding: padding,
    );
  }

  // Enhanced background methods with better contrast

  /// Print with dark red background (better contrast for yellow/cyan text)
  void onDarkRed(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.white,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.darkRed,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with deep red background (excellent contrast)
  void onDeepRed(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.white,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.deepRed,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with maroon background (best contrast for bright colors)
  void onMaroon(
    String message, {
    IndentLevel indent = IndentLevel.none,
    CliColor textColor = CliColor.white,
    Padding padding = Padding.none,
  }) {
    onBackground(
      message,
      textColor: textColor,
      backgroundColor: CliColor.maroon,
      indent: indent,
      padding: padding,
    );
  }

  /// Print with an icon from the predefined set
  void withIcon(
    String message, {
    required CliIcons icon,
    CliColor color = CliColor.primary,
    IndentLevel indent = IndentLevel.none,
  }) {
    final colorFunc = color;
    final indentedMessage =
        '${indent.spacing}${icon.symbol} ${formatter.format(message)}';
    io.writeln(colorFunc(indentedMessage));
  }

  /// Print with a custom icon
  void withIconCustom(
    String message, {
    required String icon,
    CliColor color = CliColor.primary,
    IndentLevel indent = IndentLevel.none,
  }) {
    final colorFunc = color;
    final indentedMessage =
        '${indent.spacing}$icon ${formatter.format(message)}';
    io.writeln(colorFunc(indentedMessage));
  }

  /// Print with tree structure
  void tree(
    String message, {
    TreeSymbol symbol = TreeSymbol.root,
    CliColor color = CliColor.primary,
  }) {
    final colorFunc = color;
    final formattedMessage = '${symbol.symbol}${formatter.format(message)}';
    io.writeln(colorFunc(formattedMessage));
  }

  /// Print with tree structure and icons
  void treeWithIcon(
    String message, {
    required CliIcons icon,
    TreeSymbol symbol = TreeSymbol.root,
    CliColor color = CliColor.primary,
  }) {
    final colorFunc = color;
    final formattedMessage =
        '${symbol.symbol}${icon.symbol} ${formatter.format(message)}';
    io.writeln(colorFunc(formattedMessage));
  }

  /// Print with bullet point for lists and enumeration
  void point(
    String message, {
    PointStyle style = PointStyle.bullet,
    CliColor color = CliColor.primary,
    IndentLevel indent = IndentLevel.none,
    int spacing = 1,
  }) {
    final colorFunc = color;
    final spacingStr = ' ' * spacing;
    final indentedMessage =
        '${indent.spacing}${style.symbol}$spacingStr${formatter.format(message)}';
    io.writeln(colorFunc(indentedMessage));
  }

  /// Print with tree structure and bullet points
  void treePoint(
    String message, {
    PointStyle style = PointStyle.bullet,
    TreeSymbol symbol = TreeSymbol.level1,
    CliColor color = CliColor.primary,
    int spacing = 1,
  }) {
    final colorFunc = color;
    final spacingStr = ' ' * spacing;
    final formattedMessage =
        '${symbol.symbol}${style.symbol}$spacingStr${formatter.format(message)}';
    io.writeln(colorFunc(formattedMessage));
  }

  /// Print empty line(s)
  void newLine([int count = 1]) {
    for (int i = 0; i < count; i++) {
      io.writeln('');
    }
  }

  /// Same as result but with clearer name
  void output(String message) {
    result(message);
  }

  /// Success message with ✅ icon
  void successIcon(String message, {IndentLevel indent = IndentLevel.none}) {
    withIcon(
      message,
      icon: CliIcons.success,
      color: CliColor.success,
      indent: indent,
    );
  }

  /// Error message with ❌ icon
  void errorIcon(String message, {IndentLevel indent = IndentLevel.none}) {
    withIcon(
      message,
      icon: CliIcons.error,
      color: CliColor.error,
      indent: indent,
    );
  }

  /// Warning message with ⚠️ icon
  void warnIcon(String message, {IndentLevel indent = IndentLevel.none}) {
    withIcon(
      message,
      icon: CliIcons.warning,
      color: CliColor.warning,
      indent: indent,
    );
  }

  /// Info message with ℹ️ icon
  void infoIcon(String message, {IndentLevel indent = IndentLevel.none}) {
    withIcon(
      message,
      icon: CliIcons.info,
      color: CliColor.info,
      indent: indent,
    );
  }

  /// Idea/tip message with 💡 icon
  void ideaIcon(String message, {IndentLevel indent = IndentLevel.none}) {
    withIcon(
      message,
      icon: CliIcons.idea,
      color: CliColor.yellow,
      indent: indent,
    );
  }

  // ========================================
  // Message with Hint Methods
  // ========================================

  /// **💬 Message with Hint** - Display message with additional hint information
  ///
  /// Shows a message with an optional hint using customizable spacing and symbols.
  /// Perfect for providing additional context or next steps after operations.
  ///
  /// ```dart
  /// logger.messageWithHint(
  ///   'Build completed successfully',
  ///   hint: 'Run tests with: dart test',
  ///   spacing: Spacing.medium,
  ///   hintSymbol: HintSymbol.arrow,
  /// );
  /// // Result: Build completed successfully    → Run tests with: dart test
  ///
  /// logger.messageWithHint(
  ///   'Configuration loaded',
  ///   hint: 'Edit config.yaml to customize',
  ///   color: CliColor.success,
  ///   hintColor: CliColor.lightGray,
  ///   spacing: Spacing.large,
  ///   hintSymbol: HintSymbol.lightBulb,
  /// );
  /// // Result: Configuration loaded      💡 Edit config.yaml to customize
  /// ```
  ///
  /// **Parameters:**
  /// - `message`: Main message content
  /// - `hint`: Additional hint or instruction (optional)
  /// - `indent`: Indentation level for the entire line
  /// - `color`: Color for the main message
  /// - `hintColor`: Color for the hint text
  /// - `spacing`: Amount of space between message and hint
  /// - `hintSymbol`: Symbol to prefix the hint
  void messageWithHint(
    String message, {
    String hint = '',
    IndentLevel indent = IndentLevel.none,
    CliColor color = CliColor.primary,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.dot,
  }) {
    final formattedMessage = formatter.format(message);

    if (hint.isEmpty) {
      // Display message only
      final indentedMessage = '${indent.spacing}$formattedMessage';
      io.writeln(color(indentedMessage));
    } else {
      // Display message with hint
      final coloredMessage = color('${indent.spacing}$formattedMessage');
      final hintWithSymbol = hintSymbol.apply(hint);
      final coloredHint = hintColor(hintWithSymbol);

      io.writeln('$coloredMessage${spacing.gap}$coloredHint');
    }
  }

  /// **Message with Icon and Hint** - Display message with icon and hint
  ///
  /// Combines icon display with hint functionality for rich, informative messages.
  /// Perfect for status updates with additional guidance or next steps.
  ///
  /// ```dart
  /// logger.messageIconWithHint(
  ///   'Tests completed',
  ///   hint: 'Coverage report: coverage/index.html',
  ///   icon: CliIcons.success,
  ///   spacing: Spacing.large,
  ///   hintSymbol: HintSymbol.info,
  /// );
  /// // Result: ✅ Tests completed      ℹ Coverage report: coverage/index.html
  ///
  /// logger.messageIconWithHint(
  ///   'Build failed',
  ///   hint: 'Check build.log for details',
  ///   icon: CliIcons.error,
  ///   color: CliColor.error,
  ///   hintSymbol: HintSymbol.arrow,
  /// );
  /// // Result: ❌ Build failed    → Check build.log for details
  /// ```
  ///
  /// **Parameters:**
  /// - `message`: Main message content
  /// - `hint`: Additional hint or instruction (optional)
  /// - `icon`: Icon to display before the message
  /// - `indent`: Indentation level for the entire line
  /// - `color`: Color for the main message and icon
  /// - `hintColor`: Color for the hint text
  /// - `spacing`: Amount of space between message and hint
  /// - `hintSymbol`: Symbol to prefix the hint
  void messageIconWithHint(
    String message, {
    String hint = '',
    required CliIcons icon,
    IndentLevel indent = IndentLevel.none,
    CliColor color = CliColor.primary,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.dot,
  }) {
    final formattedMessage = formatter.format(message);
    final messageWithIcon = '${indent.spacing}${icon.symbol} $formattedMessage';

    if (hint.isEmpty) {
      // Display message with icon only
      io.writeln(color(messageWithIcon));
    } else {
      // Display message with icon and hint
      final coloredMessage = color(messageWithIcon);
      final hintWithSymbol = hintSymbol.apply(hint);
      final coloredHint = hintColor(hintWithSymbol);

      io.writeln('$coloredMessage${spacing.gap}$coloredHint');
    }
  }

  /// Print multiple lines with specified log level
  void lines(
    List<String> messages, {
    LogLevel level = LogLevel.plain,
    IndentLevel indent = IndentLevel.none,
    bool showPrefix = false,
    LineSpacing lineSpacing = LineSpacing.none,
  }) {
    for (int i = 0; i < messages.length; i++) {
      final message = messages[i];

      switch (level) {
        case LogLevel.plain:
          plain(message, showPrefix: showPrefix, indent: indent);
        case LogLevel.debug:
          debug(message, showPrefix: showPrefix, indent: indent);
        case LogLevel.info:
          info(message, showPrefix: showPrefix, indent: indent);
        case LogLevel.warning:
          warn(message, showPrefix: showPrefix, indent: indent);
        case LogLevel.error:
          error(message, showPrefix: showPrefix, indent: indent);
        case LogLevel.success:
          success(message, showPrefix: showPrefix, indent: indent);
      }

      // Add spacing between lines if specified
      if (lineSpacing != LineSpacing.none && i < messages.length - 1) {
        newLine(lineSpacing.lines);
      }
    }
  }

  /// Display completed prompt result with question and answer
  /// Format: ✓ Question Answer
  void promptResult(String question, String answer) {
    final checkMark = CliColor.success('✓');
    final questionText = theme.primary(question);
    final answerText = CliColor.white(' $answer');
    io.writeln('$checkMark $questionText$answerText');
  }

  /// Display completed multi-select prompt result with question and multiple answers
  /// Format: ✓ Question Answer1, Answer2, Answer3
  void multiPromptResult(
    String question,
    List<String> answers, {
    String separator = ', ',
  }) {
    final checkMark = CliColor.success('✓');
    final questionText = theme.primary(question);
    final answersText = CliColor.white(' ${answers.join(separator)}');
    io.writeln('$checkMark $questionText$answersText');
  }

  // ========================================
  // Specialized Hint Methods
  // ========================================

  /// **Success with Hint** - Success message with additional guidance
  ///
  /// Display successful operation outcome with helpful next steps or additional information.
  /// Perfect for guiding users after successful completion of tasks.
  ///
  /// ```dart
  /// logger.successWithHint(
  ///   'Package installed successfully',
  ///   hint: 'Import with: import \'package:example/example.dart\';',
  /// );
  /// // Result: Package installed successfully    • Import with: import 'package:example/example.dart';
  ///
  /// logger.successWithHint(
  ///   'Build completed',
  ///   hint: 'Run with: dart run',
  ///   spacing: Spacing.large,
  ///   hintSymbol: HintSymbol.arrow,
  /// );
  /// // Result: Build completed      → Run with: dart run
  /// ```
  void successWithHint(
    String message, {
    String hint = '',
    IndentLevel indent = IndentLevel.none,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.dot,
  }) {
    messageWithHint(
      message,
      hint: hint,
      indent: indent,
      color: CliColor.success,
      hintColor: hintColor,
      spacing: spacing,
      hintSymbol: hintSymbol,
    );
  }

  /// **Success Icon with Hint** - Success icon message with guidance
  ///
  /// Display successful operation with checkmark icon and helpful next steps.
  /// Combines visual success indication with actionable guidance.
  ///
  /// ```dart
  /// logger.successIconWithHint(
  ///   'Tests passed',
  ///   hint: 'Coverage: 98% - See coverage/index.html',
  ///   hintSymbol: HintSymbol.info,
  /// );
  /// // Result: ✅ Tests passed    ℹ Coverage: 98% - See coverage/index.html
  ///
  /// logger.successIconWithHint(
  ///   'Deployment complete',
  ///   hint: 'Visit: https://app.example.com',
  ///   spacing: Spacing.large,
  /// );
  /// // Result: ✅ Deployment complete      • Visit: https://app.example.com
  /// ```
  void successIconWithHint(
    String message, {
    String hint = '',
    IndentLevel indent = IndentLevel.none,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.dot,
  }) {
    messageIconWithHint(
      message,
      hint: hint,
      icon: CliIcons.success,
      indent: indent,
      color: CliColor.success,
      hintColor: hintColor,
      spacing: spacing,
      hintSymbol: hintSymbol,
    );
  }

  /// **❌ Error with Hint** - Error message with troubleshooting guidance
  ///
  /// Display error messages with helpful troubleshooting hints or next steps.
  /// Perfect for providing actionable error recovery information.
  ///
  /// ```dart
  /// logger.errorWithHint(
  ///   'Connection failed',
  ///   hint: 'Check your network connection and try again',
  ///   hintSymbol: HintSymbol.lightBulb,
  /// );
  /// // Result: Connection failed    💡 Check your network connection and try again
  /// ```
  void errorWithHint(
    String message, {
    String hint = '',
    IndentLevel indent = IndentLevel.none,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.lightBulb,
  }) {
    messageWithHint(
      message,
      hint: hint,
      indent: indent,
      color: CliColor.error,
      hintColor: hintColor,
      spacing: spacing,
      hintSymbol: hintSymbol,
    );
  }

  /// **❌ Error Icon with Hint** - Error icon message with troubleshooting
  ///
  /// Display error with cross icon and helpful troubleshooting information.
  /// Combines clear error indication with actionable recovery steps.
  ///
  /// ```dart
  /// logger.errorIconWithHint(
  ///   'Build failed',
  ///   hint: 'Run \'dart pub get\' and try again',
  ///   hintSymbol: HintSymbol.arrow,
  /// );
  /// // Result: ❌ Build failed    → Run 'dart pub get' and try again
  /// ```
  void errorIconWithHint(
    String message, {
    String hint = '',
    IndentLevel indent = IndentLevel.none,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.lightBulb,
  }) {
    messageIconWithHint(
      message,
      hint: hint,
      icon: CliIcons.error,
      indent: indent,
      color: CliColor.error,
      hintColor: hintColor,
      spacing: spacing,
      hintSymbol: hintSymbol,
    );
  }

  /// **⚠️ Warning with Hint** - Warning message with recommendations
  ///
  /// Display warnings with helpful recommendations or preventive actions.
  /// Perfect for alerting users to potential issues with guidance.
  ///
  /// ```dart
  /// logger.warnWithHint(
  ///   'API rate limit approaching',
  ///   hint: 'Consider caching responses or upgrading plan',
  ///   hintSymbol: HintSymbol.star,
  /// );
  /// // Result: API rate limit approaching    ★ Consider caching responses or upgrading plan
  /// ```
  void warnWithHint(
    String message, {
    String hint = '',
    IndentLevel indent = IndentLevel.none,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.lightBulb,
  }) {
    messageWithHint(
      message,
      hint: hint,
      indent: indent,
      color: CliColor.warning,
      hintColor: hintColor,
      spacing: spacing,
      hintSymbol: hintSymbol,
    );
  }

  /// **⚠️ Warning Icon with Hint** - Warning icon message with recommendations
  ///
  /// Display warning with warning icon and helpful recommendations.
  /// Combines clear warning indication with preventive guidance.
  ///
  /// ```dart
  /// logger.warnIconWithHint(
  ///   'Deprecated API used',
  ///   hint: 'Migrate to v2 API - See docs.example.com/migration',
  ///   hintSymbol: HintSymbol.info,
  /// );
  /// // Result: ⚠️ Deprecated API used    ℹ Migrate to v2 API - See docs.example.com/migration
  /// ```
  void warnIconWithHint(
    String message, {
    String hint = '',
    IndentLevel indent = IndentLevel.none,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.lightBulb,
  }) {
    messageIconWithHint(
      message,
      hint: hint,
      icon: CliIcons.warning,
      indent: indent,
      color: CliColor.warning,
      hintColor: hintColor,
      spacing: spacing,
      hintSymbol: hintSymbol,
    );
  }

  /// **ℹ️ Info with Hint** - Information message with additional context
  ///
  /// Display informational messages with helpful additional context.
  /// Perfect for providing supplementary information or next steps.
  ///
  /// ```dart
  /// logger.infoWithHint(
  ///   'Configuration loaded',
  ///   hint: 'Edit config.yaml to customize settings',
  ///   hintSymbol: HintSymbol.chevron,
  /// );
  /// // Result: Configuration loaded    › Edit config.yaml to customize settings
  /// ```
  void infoWithHint(
    String message, {
    String hint = '',
    IndentLevel indent = IndentLevel.none,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.dot,
  }) {
    messageWithHint(
      message,
      hint: hint,
      indent: indent,
      color: CliColor.info,
      hintColor: hintColor,
      spacing: spacing,
      hintSymbol: hintSymbol,
    );
  }

  /// **ℹ️ Info Icon with Hint** - Info icon message with additional context
  ///
  /// Display information with info icon and helpful additional context.
  /// Combines clear informational indication with supplementary guidance.
  ///
  /// ```dart
  /// logger.infoIconWithHint(
  ///   'Server started',
  ///   hint: 'Listening on http://localhost:3000',
  ///   spacing: Spacing.large,
  /// );
  /// // Result: ℹ️ Server started      • Listening on http://localhost:3000
  /// ```
  void infoIconWithHint(
    String message, {
    String hint = '',
    IndentLevel indent = IndentLevel.none,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.dot,
  }) {
    messageIconWithHint(
      message,
      hint: hint,
      icon: CliIcons.info,
      indent: indent,
      color: CliColor.info,
      hintColor: hintColor,
      spacing: spacing,
      hintSymbol: hintSymbol,
    );
  }

  // ========================================
  // Color-Specific Hint Methods
  // ========================================

  /// **Primary Color with Hint** - Primary colored message with guidance
  ///
  /// Display messages in the primary brand color with helpful hints.
  /// Perfect for main actions, important information, and brand messaging.
  ///
  /// ```dart
  /// logger.primaryWithHint(
  ///   'Welcome to MyApp',
  ///   hint: 'Type \'help\' for available commands',
  ///   hintSymbol: HintSymbol.lightBulb,
  /// );
  /// // Result: Welcome to MyApp    💡 Type 'help' for available commands
  ///
  /// logger.primaryWithHint(
  ///   'Installation completed',
  ///   hint: 'Start with: myapp init',
  ///   spacing: Spacing.large,
  ///   hintSymbol: HintSymbol.arrow,
  /// );
  /// // Result: Installation completed      → Start with: myapp init
  /// ```
  void primaryWithHint(
    String message, {
    String hint = '',
    IndentLevel indent = IndentLevel.none,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.dot,
  }) {
    messageWithHint(
      message,
      hint: hint,
      indent: indent,
      color: CliColor.primary,
      hintColor: hintColor,
      spacing: spacing,
      hintSymbol: hintSymbol,
    );
  }

  /// **🔸 Secondary Color with Hint** - Secondary colored message with guidance
  ///
  /// Display messages in the secondary brand color with helpful hints.
  /// Perfect for complementary information, secondary actions, and supporting details.
  ///
  /// ```dart
  /// logger.secondaryWithHint(
  ///   'Optional features available',
  ///   hint: 'Run \'myapp features\' to see options',
  ///   hintSymbol: HintSymbol.chevron,
  /// );
  /// // Result: Optional features available    › Run 'myapp features' to see options
  ///
  /// logger.secondaryWithHint(
  ///   'Configuration saved',
  ///   hint: 'Restart required for changes to take effect',
  ///   spacing: Spacing.extraLarge,
  ///   hintSymbol: HintSymbol.info,
  /// );
  /// // Result: Configuration saved        ℹ Restart required for changes to take effect
  /// ```
  void secondaryWithHint(
    String message, {
    String hint = '',
    IndentLevel indent = IndentLevel.none,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.dot,
  }) {
    messageWithHint(
      message,
      hint: hint,
      indent: indent,
      color: CliColor.secondary,
      hintColor: hintColor,
      spacing: spacing,
      hintSymbol: hintSymbol,
    );
  }

  /// **⚪ White Color with Hint** - White colored message with guidance
  ///
  /// Display messages in pure white with helpful hints.
  /// Perfect for important announcements, clean output, and high-contrast messaging.
  ///
  /// ```dart
  /// logger.whiteWithHint(
  ///   'System ready',
  ///   hint: 'All services are operational',
  ///   hintSymbol: HintSymbol.star,
  /// );
  /// // Result: System ready    ★ All services are operational
  ///
  /// logger.whiteWithHint(
  ///   'Clean installation detected',
  ///   hint: 'First-time setup will begin automatically',
  ///   spacing: Spacing.huge,
  ///   hintSymbol: HintSymbol.triangle,
  /// );
  /// // Result: Clean installation detected          ▶ First-time setup will begin automatically
  /// ```
  void whiteWithHint(
    String message, {
    String hint = '',
    IndentLevel indent = IndentLevel.none,
    CliColor hintColor = CliColor.gray,
    Spacing spacing = Spacing.medium,
    HintSymbol hintSymbol = HintSymbol.dot,
  }) {
    messageWithHint(
      message,
      hint: hint,
      indent: indent,
      color: CliColor.white,
      hintColor: hintColor,
      spacing: spacing,
      hintSymbol: hintSymbol,
    );
  }

  // ========================================
  // Progress & Spinner Convenience Methods
  // ========================================

  /// Create a progress bar for known operations with total steps
  ///
  /// Automatically inherits this logger's theme for consistent styling.
  /// Perfect for file downloads, installations, or any countable operations.
  ///
  /// Example:
  /// ```dart
  /// final progress = logger.progress(total: 100);
  /// for (int i = 0; i <= 100; i += 10) {
  ///   progress.update(i);
  ///   await Future.delayed(Duration(milliseconds: 200));
  /// }
  /// progress.complete();
  /// ```
  ///
  /// For advanced customization, use [Progress] constructor directly.
  Progress progress({
    required int total,
    int width = 40,
    ProgressStyle style = ProgressStyle.basic,
    CliTheme? theme,
    CliIO? io,
  }) {
    return Progress(
      total: total,
      width: width,
      style: style,
      theme: theme ?? this.theme,
      io: io ?? this.io,
    );
  }

  /// Create a spinner for unknown-duration operations
  ///
  /// Automatically inherits this logger's theme for consistent styling.
  /// Perfect for network requests, processing tasks, or waiting operations.
  ///
  /// Example:
  /// ```dart
  /// final spinner = logger.spinner('Connecting to server...');
  /// await Future.delayed(Duration(seconds: 2));
  /// spinner.update('Authenticating...');
  /// await Future.delayed(Duration(seconds: 1));
  /// spinner.complete('Connected successfully!');
  /// ```
  ///
  /// Available types: [SpinnerType.dots], [SpinnerType.circle], etc.
  /// For advanced customization, use [Spinner] constructor directly.
  Spinner spinner(
    String message, {
    SpinnerType type = SpinnerType.dots,
    CliTheme? theme,
    CliLogger? logger,
  }) {
    return Spinner(
      message,
      type: type,
      theme: theme ?? this.theme,
      logger: logger ?? this,
    );
  }

  /// Create a multi-spinner for managing multiple concurrent tasks
  ///
  /// Automatically inherits this logger's theme for consistent styling.
  /// Perfect for parallel operations like downloading multiple files,
  /// or running multiple build steps simultaneously.
  ///
  /// Example:
  /// ```dart
  /// final multiSpinner = logger.multiSpinner();
  /// multiSpinner.add('download', 'Downloading files...');
  /// multiSpinner.add('compile', 'Compiling code...');
  ///
  /// // Complete tasks as they finish
  /// await Future.delayed(Duration(seconds: 1));
  /// multiSpinner.complete('download', 'Files downloaded!');
  /// await Future.delayed(Duration(seconds: 2));
  /// multiSpinner.complete('compile', 'Code compiled!');
  /// ```
  ///
  /// For advanced customization, use [MultiSpinner] constructor directly.
  MultiSpinner multiSpinner({CliTheme? theme, CliLogger? logger}) {
    return MultiSpinner(theme: theme ?? this.theme, logger: logger ?? this);
  }

  /// Create a formatted table with automatic theme inheritance
  ///
  /// Automatically inherits this logger's theme for consistent styling.
  /// Perfect for displaying structured data like configurations, results,
  /// or comparative information in a clean, readable format.
  ///
  /// Example:
  /// ```dart
  /// final table = logger.table(
  ///   columns: [
  ///     TableColumn('Name'),
  ///     TableColumn('Status', alignment: TableAlignment.center),
  ///     TableColumn('Time', alignment: TableAlignment.right),
  ///   ],
  ///   rows: [
  ///     ['Server 1', 'Running', '2.3s'],
  ///     ['Server 2', 'Stopped', '0.0s'],
  ///     ['Server 3', 'Running', '1.8s'],
  ///   ],
  /// );
  /// print(table.render());
  /// ```
  ///
  /// Headers automatically use the logger's primary color with bold styling.
  /// Borders use the logger's debug color for subtle appearance.
  /// For advanced customization, use [Table] constructor directly.
  Table table({
    required List<TableColumn> columns,
    required List<List<String>> rows,
    bool showBorders = true,
    CliTheme? theme,
  }) {
    return Table(
      columns: columns,
      rows: rows,
      showBorders: showBorders,
      theme: theme ?? this.theme,
    );
  }
}
