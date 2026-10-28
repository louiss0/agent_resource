import '../core/io/cli_io.dart';
import '../core/style/theme.dart';
import 'prompt_globals.dart';

abstract class Prompt<T> {
  Future<T> run(CliIO io, CliTheme theme);

  Future<T> interact([CliIO? io, CliTheme? theme]) {
    final effectiveIO = io ?? PromptGlobals.defaultIO;
    final effectiveTheme = theme ?? PromptGlobals.defaultTheme;

    return run(effectiveIO, effectiveTheme);
  }
}
