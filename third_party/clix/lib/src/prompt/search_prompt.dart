import 'dart:io';
import 'prompt.dart';
import '../core/io/cli_io.dart';
import '../core/style/theme.dart';

class Search extends Prompt<int> {
  final String prompt;
  final dynamic options; // List<String> أو Function
  final String? Function(String)? validator;
  final int minQueryLength;
  final int maxResults;
  final int? defaultIndex;
  final String? placeholder;

  Search({
    required this.prompt,
    required this.options,
    this.validator,
    this.minQueryLength = 1,
    this.maxResults = 10,
    this.defaultIndex,
    this.placeholder,
  });

  @override
  Future<int> run(CliIO io, CliTheme theme) async {
    while (true) {
      // Phase 1: Get search query
      final query = await _getSearchQuery(io, theme);

      if (query.isEmpty) continue;

      // Skip loading, go directly to results
      final results = await _getSearchResults(query);

      if (results.isEmpty) {
        _showNoResults(io, theme);
        continue;
      }

      // If only one result, auto-select it without showing selection interface
      if (results.length == 1) {
        final selectedValue = results[0];
        if (validator != null) {
          final error = validator!(selectedValue);
          if (error != null) {
            _showValidationError(io, theme, error);
            continue;
          }
        }
        final originalIndex = _findOriginalIndex(selectedValue, results);
        _showConfirmation(io, theme, selectedValue, 1);
        return originalIndex;
      }

      // Phase 4: Show results with Select-style interface
      final selectedIndex = await _showSelectResults(io, theme, query, results);

      if (selectedIndex == -1) {
        // User chose to search again
        continue;
      } else if (selectedIndex == -2) {
        // User cancelled
        throw Exception('Search cancelled');
      }

      // Validate selection
      final selectedValue = results[selectedIndex];
      if (validator != null) {
        final error = validator!(selectedValue);
        if (error != null) {
          _showValidationError(io, theme, error);
          continue;
        }
      }

      // Show confirmation and return original index
      final originalIndex = _findOriginalIndex(selectedValue, results);
      _showConfirmation(io, theme, selectedValue, results.length);
      return originalIndex;
    }
  }

  Future<String> _getSearchQuery(CliIO io, CliTheme theme) async {
    // Simple prompt like Input
    io.write('${theme.primary(prompt)}: ');
    final query = io.readLine().trim();
    return query;
  }

  Future<List<String>> _getSearchResults(String query) async {
    if (query.length < minQueryLength) {
      return [];
    }

    if (options is List<String>) {
      // Static list filtering
      final list = options as List<String>;
      return list
          .where((item) => item.toLowerCase().contains(query.toLowerCase()))
          .take(maxResults)
          .toList();
    } else if (options is Function) {
      // Dynamic function
      try {
        final result = options(query);
        if (result is Future) {
          final asyncResult = await result;
          return List<String>.from(asyncResult).take(maxResults).toList();
        } else {
          return List<String>.from(result).take(maxResults).toList();
        }
      } catch (e) {
        return [];
      }
    }

    return [];
  }

  Future<int> _showSelectResults(
    CliIO io,
    CliTheme theme,
    String query,
    List<String> results,
  ) async {
    int selectedIndex = defaultIndex != null && defaultIndex! < results.length
        ? defaultIndex!
        : 0;

    // If only one result, auto-select it
    if (results.length == 1) {
      return 0;
    }

    // Show initial screen - simpler like Select
    io.writeln('${theme.primary(prompt)}:');

    // Show initial options
    for (int i = 0; i < results.length; i++) {
      final isSelected = i == selectedIndex;
      final prefix = isSelected ? '❯' : ' ';
      final option = results[i];

      if (isSelected) {
        io.writeln('  ${theme.primary(prefix)} ${theme.primary(option)}');
      } else {
        io.writeln('  $prefix $option');
      }
    }

    io.writeln('');
    // Show all available options
    io.writeln(
      theme.plain('↑↓ Navigate • Enter Select • r Search Again • q Quit'),
    );

    // Enable raw mode for capturing arrow keys
    stdin.echoMode = false;
    stdin.lineMode = false;

    try {
      while (true) {
        final input = stdin.readByteSync();

        if (input == 27) {
          // Escape sequence (arrow keys)
          final next1 = stdin.readByteSync();
          final next2 = stdin.readByteSync();

          if (next1 == 91) {
            if (next2 == 65) {
              // Up arrow
              selectedIndex =
                  (selectedIndex - 1 + results.length) % results.length;
              _renderSearchOptions(io, theme, results, selectedIndex);
            } else if (next2 == 66) {
              // Down arrow
              selectedIndex = (selectedIndex + 1) % results.length;
              _renderSearchOptions(io, theme, results, selectedIndex);
            }
          }
        } else if (input == 10 || input == 13) {
          // Enter key - select current option
          stdin.echoMode = true;
          stdin.lineMode = true;
          return selectedIndex;
        } else if (input == 114) {
          // 'r' key - search again
          stdin.echoMode = true;
          stdin.lineMode = true;
          return -1;
        } else if (input == 113) {
          // 'q' key - quit
          stdin.echoMode = true;
          stdin.lineMode = true;
          return -2;
        }
      }
    } catch (e) {
      stdin.echoMode = true;
      stdin.lineMode = true;
      rethrow;
    }
  }

  void _renderSearchOptions(
    CliIO io,
    CliTheme theme,
    List<String> results,
    int selectedIndex,
  ) {
    // Move cursor up to redraw options (results + help line + 1 extra)
    io.write('\x1B[${results.length + 2}A');

    // Redraw all options
    for (int i = 0; i < results.length; i++) {
      // Clear the line first
      io.write('\x1B[2K');

      final isSelected = i == selectedIndex;
      final prefix = isSelected ? '❯' : ' ';
      final option = results[i];

      if (isSelected) {
        io.writeln('  ${theme.primary(prefix)} ${theme.primary(option)}');
      } else {
        io.writeln('  $prefix $option');
      }
    }

    // Redraw help line
    io.write('\x1B[2K'); // Clear empty line
    io.writeln('');
    io.write('\x1B[2K'); // Clear help line
    io.writeln(
      theme.plain('↑↓ Navigate • Enter Select • r Search Again • q Quit'),
    );
  }

  void _showNoResults(CliIO io, CliTheme theme) {
    io.writeln('');
    io.writeln(theme.error('❌ No results found. Try a different search term.'));
    io.writeln(theme.plain('Press Enter to search again...'));
    io.readLine();
  }

  void _showValidationError(CliIO io, CliTheme theme, String error) {
    io.writeln('');
    io.writeln(theme.error('❌ $error'));
    io.writeln(theme.plain('Press Enter to search again...'));
    io.readLine();
  }

  int _findOriginalIndex(String selectedValue, List<String> searchResults) {
    if (options is List<String>) {
      return (options as List<String>).indexOf(selectedValue);
    }

    // For dynamic searches, return the index from search results
    return searchResults.indexOf(selectedValue);
  }

  void _showConfirmation(
    CliIO io,
    CliTheme theme,
    String result, [
    int? resultsCount,
  ]) {
    if (resultsCount != null && resultsCount > 1) {
      // Clear the results display (options + help line + empty line)
      final linesToClear =
          resultsCount + 3; // results + empty line + help line + prompt line
      io.write('\x1B[${linesToClear}A'); // Move up
      for (int i = 0; i < linesToClear; i++) {
        io.write('\x1B[2K'); // Clear line
        if (i < linesToClear - 1) io.write('\x1B[1B'); // Move down if not last
      }
      io.write('\x1B[${linesToClear - 1}A'); // Move back to prompt line
    } else {
      // Single line clear for auto-selected results or simple cases
      io.write('\x1B[1A\x1B[2K');
    }

    final checkmark = theme.success('✓');
    final question = theme.primary(prompt);
    final answer = theme.plain(result);

    io.writeln('$checkmark $question $answer');
  }
}
