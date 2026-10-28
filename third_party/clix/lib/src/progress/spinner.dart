/// Spinner - Animated loading indicators for indeterminate tasks
library;

import 'dart:async';
import 'dart:io';
import '../logger/logger.dart';
import '../core/style/color.dart';
import '../core/style/theme.dart';
import 'enums/spinner_type.dart';

/// **Spinner Class - Animated loading indicator**
///
/// Provides animated visual feedback for long-running operations where
/// completion time is unknown or variable.
class Spinner {
  /// **Animation Type** - Visual style of the spinner animation
  final SpinnerType _type;

  /// **Logger Instance** - Optional logger for final status messages
  final CliLogger? _logger;

  /// **Animation Interval** - Time between animation frames
  final Duration _interval;

  /// **Theme** - Color scheme for spinner styling
  final CliTheme _theme;

  /// **Animation Timer** - Controls the spinning animation
  Timer? _timer;

  /// **Frame Index** - Current position in animation sequence
  int _frameIndex = 0;

  /// **Start Time** - When spinner started (for elapsed time)
  DateTime? _startTime;

  /// **Active State** - Whether spinner is currently running
  bool _isActive = false;

  /// **Current Message** - Text displayed with spinner
  String _currentMessage;

  /// **Constructor** - Create spinner with message and options
  ///
  /// ```dart
  /// // Basic spinner
  /// final spinner = Spinner('Loading...');
  ///
  /// // Custom spinner
  /// final spinner = Spinner(
  ///   'Processing data...',
  ///   type: SpinnerType.arrows,
  ///   logger: myLogger,
  ///   theme: CliTheme.blue(),
  /// );
  /// ```
  Spinner(
    String message, {
    SpinnerType type = SpinnerType.dots,
    CliLogger? logger,
    CliTheme? theme,
    Duration interval = const Duration(milliseconds: 100),
  }) : _type = type,
       _logger = logger,
       _theme = theme ?? CliTheme.defaultTheme(),
       _interval = interval,
       _currentMessage = message {
    start(); // Auto-start
  }

  /// Get animated symbol frames
  List<String> get _frames {
    switch (_type) {
      case SpinnerType.dots:
        return ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
      case SpinnerType.line:
        return ['-', '\\', '|', '/'];
      case SpinnerType.pipe:
        return ['┤', '┘', '┴', '└', '├', '┌', '┬', '┐'];
      case SpinnerType.clock:
        return [
          '🕛',
          '🕧',
          '🕐',
          '🕜',
          '🕑',
          '🕝',
          '🕒',
          '🕞',
          '🕓',
          '🕟',
          '🕔',
          '🕠',
        ];
      case SpinnerType.arrow:
        return ['←', '↖', '↑', '↗', '→', '↘', '↓', '↙'];
      case SpinnerType.triangle:
        return ['◢', '◣', '◤', '◥'];
      case SpinnerType.square:
        return ['■', '□', '▪', '▫'];
      case SpinnerType.circle:
        return ['◐', '◓', '◑', '◒'];
    }
  }

  /// Start spinner display
  void start() {
    if (_isActive) return;

    _isActive = true;
    _startTime = DateTime.now();
    _frameIndex = 0;

    // Hide cursor
    stdout.write('\u001b[?25l');

    // Show first frame immediately
    _showFrame();

    _timer = Timer.periodic(_interval, (timer) => _showFrame());
  }

  /// Update spinner message
  void update(String message) {
    _currentMessage = message;
  }

  /// Complete spinner successfully
  void complete([String? message]) {
    if (!_isActive) return;

    stop();
    final successMessage = message ?? _currentMessage;
    final elapsed = _formatElapsed();

    stdout.write('${_clearLine()}\r');
    if (_logger != null) {
      _logger.success('✓ $successMessage $elapsed');
    } else {
      stdout.writeln('${CliColor.green('✓')} $successMessage $elapsed');
    }
  }

  /// Complete spinner with failure
  void fail([String? message]) {
    if (!_isActive) return;

    stop();
    final failMessage = message ?? _currentMessage;

    stdout.write('${_clearLine()}\r');
    if (_logger != null) {
      _logger.error('✗ $failMessage');
    } else {
      stdout.writeln('${CliColor.red('✗')} $failMessage');
    }
  }

  /// Cancel spinner and hide line
  void cancel() {
    if (!_isActive) return;

    stop();
    stdout.write('${_clearLine()}\r');
  }

  /// Stop spinner
  void stop() {
    if (!_isActive) return;

    _timer?.cancel();
    _timer = null;
    _isActive = false;

    // Show cursor
    stdout.write('\u001b[?25h');

    _cleanup();
  }

  /// Display current frame
  void _showFrame() {
    if (!_isActive) return;

    final frame = _frames[_frameIndex];
    final elapsed = _formatElapsed();

    // Clear line and show spinner
    stdout.write('\r${_clearLine()}');
    stdout.write('\r${_theme.primaryColor(frame)} $_currentMessage $elapsed');

    _frameIndex = (_frameIndex + 1) % _frames.length;
  }

  /// Format elapsed time
  String _formatElapsed() {
    if (_startTime == null) return '';

    final elapsed = DateTime.now().difference(_startTime!);
    final seconds = elapsed.inMilliseconds / 1000;
    return CliColor.gray('(${seconds.toStringAsFixed(1)}s)');
  }

  /// Clear current line
  String _clearLine() {
    return '\u001b[2K'; // Clear entire line
  }

  /// Cleanup resources
  void _cleanup() {
    // Additional cleanup if needed in the future
  }
}
