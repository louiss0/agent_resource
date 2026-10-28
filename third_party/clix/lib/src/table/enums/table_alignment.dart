/// Enum for table column text alignment options
///
/// This enum provides alignment options for table columns to control
/// how text is positioned within each cell.
///
/// Example usage:
/// ```dart
/// TableColumn('Name', alignment: TableAlignment.left);
/// TableColumn('Price', alignment: TableAlignment.right);
/// TableColumn('Status', alignment: TableAlignment.center);
/// ```
enum TableAlignment {
  /// Left-align text in the column
  left,

  /// Center-align text in the column
  center,

  /// Right-align text in the column
  right,
}
