/// Indentation level enumeration for consistent text spacing
///
/// Provides structured indentation levels from 0 to 5 with consistent
/// spacing of 2 spaces per level. Used for hierarchical text formatting
/// and creating readable nested output structures.
///
/// Levels available:
/// - none: 0 spaces (no indentation)
/// - level1: 2 spaces
/// - level2: 4 spaces
/// - level3: 6 spaces
/// - level4: 8 spaces
/// - level5: 10 spaces
///
/// Usage:
/// ```dart
/// print('${IndentLevel.none.spacing}Root item');
/// print('${IndentLevel.level1.spacing}Nested item');
/// print('${IndentLevel.level2.spacing}Deeply nested item');
///
/// // Output:
/// // Root item
/// //   Nested item
/// //     Deeply nested item
/// ```
library;

enum IndentLevel {
  none,
  level1,
  level2,
  level3,
  level4,
  level5;

  /// Get level number
  int get level {
    switch (this) {
      case IndentLevel.none:
        return 0;
      case IndentLevel.level1:
        return 1;
      case IndentLevel.level2:
        return 2;
      case IndentLevel.level3:
        return 3;
      case IndentLevel.level4:
        return 4;
      case IndentLevel.level5:
        return 5;
    }
  }

  /// Two spaces per level
  String get spacing => '  ' * level;
}
