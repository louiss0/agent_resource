import 'package:args/args.dart';
import '../logger/logger.dart';
import '../core/style/color.dart';
import '../core/indentation/indent_level.dart';
import '../core/style/point_style.dart';
import '../exceptions/cli_arg_exception.dart';
import 'cli_arg_results.dart';

/// Utility class for enhanced args functionality with Clix styling
class CliArgsHelper {
  /// Format help text with Clix styling
  static String formatHelp(String usage, String? programName) {
    final buffer = StringBuffer();

    buffer.writeln(
      CliColor.primary('Usage: ${programName ?? 'program'} [options]'),
    );
    buffer.writeln();

    if (usage.trim().isNotEmpty) {
      buffer.writeln(CliColor.cyan('Options:'));

      // Format the usage text with colors
      for (final line in usage.split('\n')) {
        if (line.trim().isEmpty) {
          buffer.writeln();
          continue;
        }

        if (line.trim().startsWith('-')) {
          // Option line - make it cyan
          buffer.writeln(CliColor.cyan('  ${line.trim()}'));
        } else if (line.trim().startsWith('[') || line.contains('(')) {
          // Description or allowed values - make it gray
          buffer.writeln(CliColor.gray('    ${line.trim()}'));
        } else {
          // Other text - keep as is but indented
          buffer.writeln('    ${line.trim()}');
        }
      }
    }

    return buffer.toString();
  }

  /// Display parsed results in a formatted way
  static void showParsedResults(CliArgResults results, CliLogger logger) {
    logger.primary('Parsed arguments:');

    // Show options that were provided
    final providedOptions = <String>[];
    for (final option in results.options) {
      if (results.wasParsed(option)) {
        final value = results[option];
        if (value != null) {
          providedOptions.add(option);
          if (value is List) {
            logger.point(
              '$option: ${value.join(', ')}',
              indent: IndentLevel.level1,
              color: CliColor.primary,
            );
          } else {
            logger.point(
              '$option: $value',
              indent: IndentLevel.level1,
              color: CliColor.primary,
            );
          }
        }
      }
    }

    if (providedOptions.isEmpty) {
      logger.point(
        'No options provided',
        indent: IndentLevel.level1,
        color: CliColor.gray,
      );
    }

    // Show positional arguments
    if (results.arguments.isNotEmpty) {
      logger.primary('Positional arguments:');
      for (int i = 0; i < results.arguments.length; i++) {
        logger.point(
          '[$i] ${results.arguments[i]}',
          indent: IndentLevel.level1,
          style: PointStyle.arrow,
          color: CliColor.secondary,
        );
      }
    }

    // Show command info if present
    if (results.command != null) {
      logger.primary('Command: ${results.commandName}');
    }
  }

  /// Handle argument parsing errors with Clix styling
  static void handleError(Object error, CliLogger logger) {
    if (error is ArgParserException) {
      logger.errorIcon(error.message);
      logger.ideaIcon('Use --help for usage information');
    } else if (error is CliArgException) {
      logger.errorIcon(error.message);
      logger.ideaIcon('Use --help for usage information');
    } else {
      logger.errorIcon('Unexpected error: $error');
    }
  }

  /// Validate file arguments exist
  static bool validateFiles(List<String> files, CliLogger logger) {
    for (final file in files) {
      // This is a simple check - in real usage you'd use dart:io
      if (file.isEmpty) {
        logger.errorIcon('Empty file path provided');
        return false;
      }
    }
    return true;
  }

  /// Show usage examples
  static void showExamples(List<String> examples, CliLogger logger) {
    if (examples.isEmpty) return;

    logger.ideaIcon('Examples:');
    for (final example in examples) {
      logger.point(
        example,
        indent: IndentLevel.level1,
        style: PointStyle.arrow,
        color: CliColor.success,
      );
    }
  }
}
