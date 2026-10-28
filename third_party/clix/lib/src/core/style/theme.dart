import 'style.dart';
import 'color.dart';

class CliTheme {
  final CliStyle plain;
  final CliStyle debug;
  final CliStyle info;
  final CliStyle warn;
  final CliStyle error;
  final CliStyle success;
  final CliStyle primary; // Primary color
  final CliStyle secondary; // Secondary color

  CliTheme({
    CliStyle? plain,
    CliStyle? debug,
    CliStyle? info,
    CliStyle? warn,
    CliStyle? error,
    CliStyle? success,
    CliStyle? primary,
    CliStyle? secondary,
  }) : plain = plain ?? CliStyle().withColor(CliColor.white),
       debug = debug ?? CliStyle().withColor(CliColor.gray),
       info = info ?? CliStyle().withColor(CliColor.cyan),
       warn = warn ?? CliStyle().withColor(CliColor.yellow).makeBold(),
       error = error ?? CliStyle().withColor(CliColor.red).makeBold(),
       success = success ?? CliStyle().withColor(CliColor.green),
       primary = primary ?? CliStyle().withColor(CliColor.primary),
       secondary = secondary ?? CliStyle().withColor(CliColor.secondary);

  factory CliTheme.defaultTheme() {
    return CliTheme(
      plain: CliStyle().withColor(CliColor.white),
      debug: CliStyle().withColor(CliColor.gray),
      info: CliStyle().withColor(CliColor.cyan),
      warn: CliStyle().withColor(CliColor.yellow).makeBold(),
      error: CliStyle().withColor(CliColor.red).makeBold(),
      success: CliStyle().withColor(CliColor.green),
      primary: CliStyle().withColor(CliColor.primary),
      secondary: CliStyle().withColor(CliColor.secondary),
    );
  }

  /// Get the primary color function for use in prompts and progress
  CliColor get primaryColor {
    return primary.color ?? CliColor.primary;
  }

  /// Get the secondary color function for use in highlights and accents
  CliColor get secondaryColor {
    return secondary.color ?? CliColor.secondary;
  }

  /// Apply primary styling to text
  String primaryText(String text) {
    return primary(text);
  }

  /// Apply secondary styling to text
  String secondaryText(String text) {
    return secondary(text);
  }
}
