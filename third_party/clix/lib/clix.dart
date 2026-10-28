/// Clix - A comprehensive CLI development toolkit for Dart
///
/// **Complete CLI solution combining logging, styling, prompts, and progress tracking**
///
/// Combines the best features of Interact, Tint, and Durham Logger
/// into a single, cohesive package for building interactive CLI applications.
///
/// ## Core Features:
/// - **Advanced Styling**: Colors, themes, and formatting
/// - **Rich Logging**: Multiple levels with timestamps and styling
/// - **Interactive Prompts**: Input, select, confirm, and more
/// - **Progress Tracking**: Bars, spinners, and multi-task progress
/// - **Data Tables**: Formatted table output with alignment
/// - **Configuration**: Easy setup and customization
/// - **Testing Utilities**: CLI testing tools and helpers
///
/// ## Quick Start:
/// ```dart
/// import 'package:clix/clix.dart';
///
/// void main() {
///   // Simple logging
///   Clix.logger.info('Hello from Clix!');
///
///   // Interactive prompt
///   final name = InputPrompt('What is your name?').ask();
///
///   // Progress tracking
///   final progress = Progress(total: 100);
///   progress.update(50);
/// }
/// ```
library;

// Core imports for Clix class functionality
import 'src/core/io/console_io.dart';
import 'src/core/style/theme.dart';
import 'src/logger/logger.dart';

///
/// ## Exported Components:
///
/// ### **Logging System**
/// - [CliLogger] - Main logger with multiple levels and formatting
/// - [LogLevel] - Debug, info, warning, error, and success levels

export 'src/logger/logger.dart';
export 'src/logger/log_level.dart';

/// ### 🔌 **IO & Core Infrastructure**
/// - [CliIO] - Abstract IO interface for testing and flexibility
/// - [ConsoleIO] - Real console implementation for production use

export 'src/core/io/cli_io.dart';
export 'src/core/io/console_io.dart';

/// ### **Styling & Theming**
/// - [CliStyle] - Text styling with colors and formatting
/// - [CliColor] - Comprehensive color system (25+ colors + hex)
/// - [CliTheme] - Consistent theming across components
/// - [PointStyle] - List and bullet point styles
/// - [Padding] - Layout and spacing control
/// - [LineSpacing] - Line height and vertical spacing

export 'src/core/style/style.dart';
export 'src/core/style/color.dart';
export 'src/core/style/theme.dart';
export 'src/core/style/point_style.dart';
export 'src/core/style/padding.dart';
export 'src/core/style/spacing.dart';
export 'src/core/style/hint_symbol.dart';
export 'src/core/style/line_spacing.dart';

/// ### **Icons & Visual Elements**
/// - [CliIcons] - Ready-to-use CLI icons and symbols

export 'src/core/icons/cli_icons.dart';

/// ### **Layout & Structure**
/// - [IndentLevel] - Hierarchical indentation control
/// - [TreeSymbol] - Tree-like structure visualization

export 'src/core/indentation/indent_level.dart';
export 'src/core/indentation/tree_symbol.dart';

/// ### **Formatting System**
/// - [CliFormatter] - Text and output formatting interface
/// - [BasicFormatter] - Standard formatting implementation

export 'src/core/formatter/formatter.dart';
export 'src/core/formatter/basic_formatter.dart';

/// ### **Interactive Prompts**
/// - [Prompt] - Base prompt functionality
/// - [InputPrompt] - Text input with validation
/// - [ConfirmPrompt] - Yes/no confirmation prompts
/// - [SelectPrompt] - Single selection from list
/// - [NumberPrompt] - Numeric input with validation
/// - [DecimalPrompt] - Decimal number input
/// - [SearchPrompt] - Searchable selection prompt
/// - [MultiSelectPrompt] - Multiple selection from list
/// - [PasswordPrompt] - Hidden password input

export 'src/prompt/prompt.dart';
export 'src/prompt/input_prompt.dart';
export 'src/prompt/confirm_prompt.dart';
export 'src/prompt/select_prompt.dart';
export 'src/prompt/number_prompt.dart';
export 'src/prompt/decimal_prompt.dart';
export 'src/prompt/search_prompt.dart';
export 'src/prompt/multi_select_prompt.dart';
export 'src/prompt/password_prompt.dart';

/// ### **Input Validation**
/// - [Validator] - Static validation methods for common patterns
/// - [ValidationRules] - Fluent builder for validation chains

export 'src/validation/validator.dart';
export 'src/validation/validation_rules.dart';

/// ### **Progress & Loading**
/// - [Progress] - Progress bars with multiple styles
/// - [Spinner] - Loading spinners (8+ animation types)
/// - [MultiSpinner] - Multi-task progress tracking
/// - [ProgressStyle] - Progress bar styling options
/// - [SpinnerType] - Available spinner animations
/// - [TaskStatus] - Task state management (pending, running, completed, failed)

export 'src/progress/progress.dart';
export 'src/progress/spinner.dart';
export 'src/progress/multi_spinner.dart';
export 'src/progress/enums/progress_style.dart';
export 'src/progress/enums/spinner_type.dart';
export 'src/progress/enums/task_status.dart';

/// ### **Data Tables**
/// - [Table] - Formatted table output with customization
/// - [TableAlignment] - Text alignment options (left, center, right)

export 'src/table/table.dart';
export 'src/table/enums/table_alignment.dart';

/// ### 🧪 **Testing Utilities**
/// - [CliTestResult] - Test execution results and reporting
/// - [CliTestRunner] - CLI application testing framework

export 'src/testing/cli_test_result.dart';
export 'src/testing/cli_test_runner.dart';

/// ### **Configuration & Arguments**
/// - [CliArgs] - Command-line argument parsing and validation
/// - [CliConfig] - Application configuration management
/// - [CliException] - Standardized error handling

export 'src/args/args.dart';
export 'src/config/cli_config.dart';
export 'src/exceptions/exceptions.dart';

// Re-export essential args types for convenience
export 'package:args/args.dart' show ArgParser, ArgResults, ArgParserException;

/// **Main Clix class - Global access point for CLI operations**
///
/// Provides static access to core Clix functionality including:
/// - Pre-configured IO operations
/// - Theme management and styling
/// - Ready-to-use logger instance
///
/// ## Usage Examples:
/// ```dart
/// // Use default logger
/// Clix.logger.info('Application started');
///
/// // Apply custom theme
/// final myTheme = CliTheme(
///   primary: CliColor.cyan,
///   secondary: CliColor.orange,
/// );
/// Clix.useTheme(myTheme);
///
/// // Access IO operations
/// Clix.io.write('Hello World!');
/// ```
class Clix {
  /// **IO Operations** - Direct console input/output access
  static final io = ConsoleIO();

  /// **Active Theme** - Current styling theme for all components
  static CliTheme theme = CliTheme.defaultTheme();

  /// **Logger Instance** - Pre-configured logger with current theme
  static final logger = CliLogger(theme: theme);

  /// **Set Global Theme** - Apply theme to all Clix components
  ///
  /// Updates the global theme used by all Clix components.
  /// Affects colors, styling, and visual appearance across the library.
  ///
  /// ```dart
  /// final darkTheme = CliTheme(
  ///   primary: CliColor.cyan,
  ///   background: CliColor.black,
  /// );
  /// Clix.useTheme(darkTheme);
  /// ```
  static void useTheme(CliTheme newTheme) {
    theme = newTheme;
  }
}
