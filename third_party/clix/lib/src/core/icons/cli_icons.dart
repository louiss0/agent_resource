/// Collection of predefined icons for CLI applications.
///
/// Each icon has a visual symbol that can be used with logger methods
/// or directly accessed via the `symbol` getter.
///
/// Example usage:
/// ```dart
/// logger.withIcon('Success!', icon: CliIcons.success);
/// logger.withIcon('Building...', icon: CliIcons.build);
/// ```
enum CliIcons {
  // Basic status icons

  /// ✅ Success/completion icon
  success,

  /// ❌ Error/failure icon
  error,

  /// ⚠️  Warning/caution icon
  warning,

  /// ℹ️  Information icon
  info,

  /// ... Loading/progress icon
  loading,

  /// 💡 Idea/tip/suggestion icon
  idea,

  // File and folder icons

  /// 📄 Document/file icon
  file,

  /// 📁 Directory/folder icon
  folder,

  /// ⬇ Download/pull icon
  download,

  /// ⬆ Upload/push icon
  upload,

  // Development and operations icons

  /// 🚀 Launch/rocket icon
  rocket,

  /// ⚙ Configuration/settings icon
  gear,

  /// ★ Star/favorite icon
  star,

  /// ♥ Heart/like icon
  heart,

  /// 🔨 Build/compile icon
  build,

  /// 🧪 Test/experiment icon
  test,

  /// 📦 Deploy/package icon
  deploy,

  // Direction arrows

  /// → General arrow
  arrow,

  /// ↑ Up arrow
  arrowUp,

  /// ↓ Down arrow
  arrowDown,

  /// ← Left arrow
  arrowLeft,

  /// → Right arrow
  arrowRight,

  // General symbols

  /// • Bullet point
  bullet,

  /// ✓ Check mark
  check,

  /// ✗ Cross/cancel mark
  cross,

  /// + Plus symbol
  plus,

  /// - Minus symbol
  minus,

  /// ● Circle symbol
  circle,

  /// ■ Square symbol
  square;

  /// Returns the visual symbol for this icon.
  ///
  /// Example:
  /// ```dart
  /// print(CliIcons.success.symbol); // prints: ✅
  /// print(CliIcons.rocket.symbol);  // prints: 🚀
  /// ```
  String get symbol {
    switch (this) {
      case CliIcons.success:
        return "✅";
      case CliIcons.error:
        return "❌";
      case CliIcons.warning:
        return "⚠️ ";
      case CliIcons.info:
        return "ℹ️ ";
      case CliIcons.idea:
        return "💡";
      case CliIcons.loading:
        return "...";
      case CliIcons.file:
        return "📄";
      case CliIcons.folder:
        return "📁";
      case CliIcons.download:
        return "⬇";
      case CliIcons.upload:
        return "⬆";
      case CliIcons.rocket:
        return "🚀";
      case CliIcons.gear:
        return "⚙";
      case CliIcons.star:
        return "★";
      case CliIcons.heart:
        return "♥";
      case CliIcons.build:
        return "🔨";
      case CliIcons.test:
        return "🧪";
      case CliIcons.deploy:
        return "📦";
      case CliIcons.arrow:
        return "→";
      case CliIcons.arrowUp:
        return "↑";
      case CliIcons.arrowDown:
        return "↓";
      case CliIcons.arrowLeft:
        return "←";
      case CliIcons.arrowRight:
        return "→";
      case CliIcons.bullet:
        return "•";
      case CliIcons.check:
        return "✓";
      case CliIcons.cross:
        return "✗";
      case CliIcons.plus:
        return "+";
      case CliIcons.minus:
        return "-";
      case CliIcons.circle:
        return "●";
      case CliIcons.square:
        return "■";
    }
  }

  @override
  String toString() => symbol;
}
