/// Tree structure symbols for hierarchical display formatting
///
/// Provides Unicode box-drawing characters for creating tree-like structures
/// in CLI output. Supports up to 5 nested levels with proper branch and
/// continuation symbols for clear visual hierarchy.
///
/// Symbol types:
/// - root: No symbol (top level)
/// - level1/level1Last: ├─ / └─ (first level branches)
/// - level2/level2Last: │  ├─ / │  └─ (second level)
/// - level3/level3Last: │  │  ├─ / │  │  └─ (third level)
/// - level4/level4Last: │  │  │  ├─ / │  │  │  └─ (fourth level)
/// - level5/level5Last: │  │  │  │  ├─ / │  │  │  │  └─ (fifth level)
///
/// Usage:
/// ```dart
/// print('${TreeSymbol.root.symbol}Project');
/// print('${TreeSymbol.level1.symbol}src/');
/// print('${TreeSymbol.level2.symbol}main.dart');
/// print('${TreeSymbol.level2Last.symbol}utils.dart');
/// print('${TreeSymbol.level1Last.symbol}test/');
///
/// // Output:
/// // Project
/// // ├─ src/
/// // │  ├─ main.dart
/// // │  └─ utils.dart
/// // └─ test/
/// ```
library;

enum TreeSymbol {
  root,
  level1,
  level1Last,
  level2,
  level2Last,
  level3,
  level3Last,
  level4,
  level4Last,
  level5,
  level5Last;

  /// Get tree symbol
  String get symbol {
    switch (this) {
      case TreeSymbol.root:
        return '';
      case TreeSymbol.level1:
        return '├─ ';
      case TreeSymbol.level1Last:
        return '└─ ';
      case TreeSymbol.level2:
        return '│  ├─ ';
      case TreeSymbol.level2Last:
        return '│  └─ ';
      case TreeSymbol.level3:
        return '│  │  ├─ ';
      case TreeSymbol.level3Last:
        return '│  │  └─ ';
      case TreeSymbol.level4:
        return '│  │  │  ├─ ';
      case TreeSymbol.level4Last:
        return '│  │  │  └─ ';
      case TreeSymbol.level5:
        return '│  │  │  │  ├─ ';
      case TreeSymbol.level5Last:
        return '│  │  │  │  └─ ';
    }
  }

  @override
  String toString() => symbol;
}
