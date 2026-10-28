import 'package:args/args.dart';
import '../exceptions/cli_arg_exception.dart';
import 'cli_arg_results.dart';
import 'cli_args_helper.dart';

/// Wrapper class that enhances the args package with Clix styling and utilities
class CliParser {
  final ArgParser _parser = ArgParser();

  /// Add a flag option (boolean)
  void addFlag(
    String name, {
    String? abbr,
    String? help,
    bool? defaultsTo,
    bool negatable = true,
    void Function(bool)? callback,
    bool hide = false,
    bool hideNegatedUsage = false,
    List<String> aliases = const [],
  }) {
    _parser.addFlag(
      name,
      abbr: abbr,
      help: help,
      defaultsTo: defaultsTo,
      negatable: negatable,
      callback: callback,
      hide: hide,
      hideNegatedUsage: hideNegatedUsage,
      aliases: aliases,
    );
  }

  /// Add a value option (string)
  void addOption(
    String name, {
    String? abbr,
    String? help,
    String? valueHelp,
    Iterable<String>? allowed,
    Map<String, String>? allowedHelp,
    String? defaultsTo,
    void Function(String?)? callback,
    bool mandatory = false,
    bool hide = false,
    List<String> aliases = const [],
  }) {
    _parser.addOption(
      name,
      abbr: abbr,
      help: help,
      valueHelp: valueHelp,
      allowed: allowed,
      allowedHelp: allowedHelp,
      defaultsTo: defaultsTo,
      callback: callback,
      mandatory: mandatory,
      hide: hide,
      aliases: aliases,
    );
  }

  /// Add a multi-value option
  void addMultiOption(
    String name, {
    String? abbr,
    String? help,
    String? valueHelp,
    Iterable<String>? allowed,
    Map<String, String>? allowedHelp,
    Iterable<String>? defaultsTo,
    void Function(List<String>)? callback,
    bool splitCommas = true,
    bool hide = false,
    List<String> aliases = const [],
  }) {
    _parser.addMultiOption(
      name,
      abbr: abbr,
      help: help,
      valueHelp: valueHelp,
      allowed: allowed,
      allowedHelp: allowedHelp,
      defaultsTo: defaultsTo,
      callback: callback,
      splitCommas: splitCommas,
      hide: hide,
      aliases: aliases,
    );
  }

  /// Add a command to the parser
  ArgParser addCommand(String name, [ArgParser? parser]) {
    return _parser.addCommand(name, parser);
  }

  /// Access the underlying ArgParser for advanced usage
  ArgParser get parser => _parser;

  /// Parse arguments with enhanced error handling
  CliArgResults parse(List<String> arguments) {
    try {
      final results = _parser.parse(arguments);
      return CliArgResults.from(results);
    } on ArgParserException catch (e) {
      throw CliArgException(e.message);
    }
  }

  /// Generate help text with Clix formatting
  String generateHelp({String? programName}) {
    return CliArgsHelper.formatHelp(_parser.usage, programName);
  }

  /// Get the basic usage string
  String get usage => _parser.usage;
}
