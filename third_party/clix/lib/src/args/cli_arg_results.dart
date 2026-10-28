import 'package:args/args.dart';

/// Enhanced wrapper for ArgResults with Clix utilities
class CliArgResults {
  final ArgResults _results;

  CliArgResults._(this._results);

  /// Factory constructor to create CliArgResults from ArgResults
  factory CliArgResults.from(ArgResults results) => CliArgResults._(results);

  /// Get the value of a flag
  bool flag(String name) => _results[name] as bool? ?? false;

  /// Get the value of an option
  String? option(String name) => _results[name] as String?;

  /// Get the values of a multi-option
  List<String>? multiOption(String name) => _results[name] as List<String>?;

  /// Get remaining positional arguments
  List<String> get rest => _results.rest;

  /// Get remaining arguments (alias for rest)
  List<String> get arguments => _results.rest;

  /// Get the first positional argument, if any
  String? get firstArgument =>
      _results.rest.isNotEmpty ? _results.rest.first : null;

  /// Get the last positional argument, if any
  String? get lastArgument =>
      _results.rest.isNotEmpty ? _results.rest.last : null;

  /// Get argument at specific index
  String? argumentAt(int index) {
    return index < _results.rest.length ? _results.rest[index] : null;
  }

  /// Check if an option was provided
  bool wasParsed(String name) => _results.wasParsed(name);

  /// Get all options
  Iterable<String> get options => _results.options;

  /// Get command information if this is a command
  CliArgResults? get command {
    final cmd = _results.command;
    return cmd != null ? CliArgResults.from(cmd) : null;
  }

  /// Get command name if this is a command
  String? get commandName => _results.command?.name;

  /// Access the underlying ArgResults for advanced usage
  ArgResults get original => _results;

  /// Access option value with [] operator
  dynamic operator [](String name) => _results[name];
}
