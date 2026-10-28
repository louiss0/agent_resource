import '../core/io/cli_io.dart';
import '../core/io/console_io.dart';
import '../core/style/theme.dart';

class PromptGlobals {
  static CliIO defaultIO = ConsoleIO();
  static CliTheme defaultTheme = CliTheme.defaultTheme();

  static void configure({CliIO? io, CliTheme? theme}) {
    if (io != null) defaultIO = io;
    if (theme != null) defaultTheme = theme;
  }
}
