/// Different styles for displaying progress bars
///
/// Provides various display formats for showing progress information
/// to users, ranging from minimal to detailed representations.
enum ProgressStyle {
  /// Basic progress bar with percentage
  ///
  /// Shows a simple progress bar with filled/empty indicators
  /// and percentage completion.
  ///
  /// Example: `████████░░ 80.0%`
  basic,

  /// Detailed progress bar with current/total count
  ///
  /// Shows progress bar, percentage, and numerical progress
  /// in format: current/total items.
  ///
  /// Example: `████████░░ 80.0% (8/10)`
  detailed,

  /// Minimal progress display showing only percentage
  ///
  /// Shows just the percentage without the visual bar,
  /// useful for compact displays or when space is limited.
  ///
  /// Example: `80%`
  minimal,

  /// Clean progress bar without text
  ///
  /// Shows only the visual progress bar without any
  /// percentage or numerical indicators for a pure visual experience.
  ///
  /// Example: `████████████████████████████████████████`
  clean,
}
