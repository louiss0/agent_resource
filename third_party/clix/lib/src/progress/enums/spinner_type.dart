/// Types of animated symbols available for spinner animations
///
/// Provides various visual styles for indicating ongoing operations
/// with different animation patterns and character sets.
enum SpinnerType {
  /// Braille pattern dots animation
  ///
  /// Uses Unicode braille characters to create a smooth rotating
  /// animation effect. This is the most popular and smooth spinner.
  ///
  /// Animation: `⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`
  dots,

  /// Classic ASCII line spinner
  ///
  /// Traditional spinner using basic ASCII characters in a
  /// rotating line pattern. Compatible with all terminals.
  ///
  /// Animation: `- \ | /`
  line,

  /// Unicode pipe/box characters
  ///
  /// Uses box drawing Unicode characters to create a rotating
  /// frame effect around an invisible center.
  ///
  /// Animation: `┤ ┘ ┴ └ ├ ┌ ┬ ┐`
  pipe,

  /// Clock emoji animation
  ///
  /// Uses clock emojis to show time progression, creating
  /// a clock-like rotating effect. Best for longer operations.
  ///
  /// Animation: `🕛 🕧 🕐 🕜 🕑 🕝 ...`
  clock,

  /// Directional arrows
  ///
  /// Shows rotating arrows pointing in different directions,
  /// useful for indicating directional progress or movement.
  ///
  /// Animation: `← ↖ ↑ ↗ → ↘ ↓ ↙`
  arrow,

  /// Geometric triangles
  ///
  /// Uses filled triangular shapes in different orientations
  /// to create a rotating geometric pattern.
  ///
  /// Animation: `◢ ◣ ◤ ◥`
  triangle,

  /// Square pattern animation
  ///
  /// Alternates between filled and empty squares to create
  /// a blinking/pulsing effect.
  ///
  /// Animation: `■ □ ▪ ▫`
  square,

  /// Circular pattern animation
  ///
  /// Uses partial circles in different orientations to show
  /// a rotating circular progress effect.
  ///
  /// Animation: `◐ ◓ ◑ ◒`
  circle,
}
