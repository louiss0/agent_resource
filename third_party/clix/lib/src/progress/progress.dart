/// Progress Bar - Visual progress tracking with customizable styles
library;

import '../core/io/cli_io.dart';
import '../core/io/console_io.dart';
import '../core/style/style.dart';
import '../core/style/theme.dart';
import 'enums/progress_style.dart';

/// **Progress Class - Visual progress tracking bar**
///
/// Displays progress as a visual bar with percentage completion.
/// Perfect for file operations, downloads, installations, and batch processing.
class Progress {
  /// **IO Interface** - Output operations for progress display
  final CliIO io;

  /// **Total Steps** - Maximum value representing 100% completion
  final int total;

  /// **Bar Width** - Character width of the progress bar
  final int width;

  /// **Visual Style** - Progress bar appearance and format
  final ProgressStyle style;

  /// **Theme** - Color scheme for progress bar styling
  final CliTheme theme;

  /// **Current Progress** - Current completion value
  int _current = 0;

  /// **Constructor** - Create progress bar with configuration
  ///
  /// ```dart
  /// // Simple progress bar
  /// final progress = Progress(total: 100);
  ///
  /// // Customized progress bar
  /// final progress = Progress(
  ///   total: 50,
  ///   width: 40,           // 40 characters wide
  ///   style: ProgressStyle.detailed, // Detailed style
  ///   theme: CliTheme.cyan(), // Cyan theme
  /// );
  /// ```
  Progress({
    CliIO? io,
    required this.total,
    this.width = 40,
    this.style = ProgressStyle.basic,
    CliTheme? theme,
  }) : io = io ?? ConsoleIO(),
       theme = theme ?? CliTheme.defaultTheme();

  void update(int current) {
    _current = current;
    _render();
  }

  void increment() {
    _current++;
    _render();
  }

  void complete() {
    _current = total;
    _render();
    io.writeln('');
  }

  void _render() {
    final percentage = ((_current / total) * 100).clamp(0.0, 100.0);
    final filled = ((width * _current) / total).round();
    final empty = width - filled;

    final bar = switch (style) {
      ProgressStyle.basic => _renderBasic(filled, empty, percentage),
      ProgressStyle.detailed => _renderDetailed(filled, empty, percentage),
      ProgressStyle.minimal => _renderMinimal(filled, empty, percentage),
      ProgressStyle.clean => _renderClean(filled, empty),
    };

    io.write('\r$bar');
  }

  String _renderBasic(int filled, int empty, double percentage) {
    final bar =
        '${CliStyle.filledProgress * filled}${CliStyle.emptyProgress * empty}';
    final coloredBar = theme.primaryColor(bar);
    return '$coloredBar ${percentage.toStringAsFixed(1)}%';
  }

  String _renderDetailed(int filled, int empty, double percentage) {
    final bar =
        '${CliStyle.filledProgress * filled}${CliStyle.emptyProgress * empty}';
    final coloredBar = theme.primaryColor(bar);
    return '$coloredBar ${percentage.toStringAsFixed(1)}% ($_current/$total)';
  }

  String _renderMinimal(int filled, int empty, double percentage) {
    return '${percentage.toStringAsFixed(0)}%';
  }

  String _renderClean(int filled, int empty) {
    final bar =
        '${CliStyle.filledProgress * filled}${CliStyle.emptyProgress * empty}';
    return theme.primaryColor(bar);
  }
}
