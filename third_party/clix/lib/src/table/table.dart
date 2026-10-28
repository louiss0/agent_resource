import 'package:clix/src/core/style/style.dart';
import 'package:clix/src/core/style/color.dart';
import 'package:clix/src/core/style/theme.dart';
import 'enums/table_alignment.dart';

class TableColumn {
  final String header;
  final TableAlignment alignment;
  final int? width;

  const TableColumn(
    this.header, {
    this.alignment = TableAlignment.left,
    this.width,
  });
}

class Table {
  final List<TableColumn> columns;
  final List<List<String>> rows;
  final CliStyle? headerStyle;
  final CliStyle? borderStyle;
  final bool showBorders;

  Table({
    required this.columns,
    required this.rows,
    CliStyle? headerStyle,
    CliStyle? borderStyle,
    CliTheme? theme,
    this.showBorders = true,
  }) : headerStyle =
           headerStyle ??
           (theme != null
               ? CliStyle().withColor(theme.primaryColor).makeBold()
               : CliStyle().withColor(CliColor.primary).makeBold()),
       borderStyle =
           borderStyle ??
           (theme != null ? theme.debug : CliStyle().withColor(CliColor.gray));

  String render() {
    final buffer = StringBuffer();

    // Calculate column widths
    final widths = _calculateWidths();

    if (showBorders) {
      buffer.writeln(_renderBorder(widths, '┌', '┬', '┐'));
    }

    // Render header
    buffer.writeln(
      _renderRow(
        [for (final col in columns) col.header],
        widths,
        style: headerStyle,
      ),
    );

    if (showBorders) {
      buffer.writeln(_renderBorder(widths, '├', '┼', '┤'));
    }

    // Render rows
    for (final row in rows) {
      buffer.writeln(_renderRow(row, widths));
    }

    if (showBorders) {
      buffer.writeln(_renderBorder(widths, '└', '┴', '┘'));
    }

    return buffer.toString();
  }

  List<int> _calculateWidths() {
    final widths = <int>[];

    for (var i = 0; i < columns.length; i++) {
      if (columns[i].width != null) {
        widths.add(columns[i].width!);
        continue;
      }

      var maxWidth = columns[i].header.length;
      for (final row in rows) {
        if (i < row.length) {
          maxWidth = maxWidth > row[i].length ? maxWidth : row[i].length;
        }
      }
      widths.add(maxWidth);
    }

    return widths;
  }

  String _renderBorder(
    List<int> widths,
    String left,
    String middle,
    String right,
  ) {
    final border = widths.map((w) => '─' * (w + 2)).join(middle);
    final result = '$left$border$right';
    return borderStyle != null ? borderStyle!(result) : result;
  }

  String _renderRow(List<String> row, List<int> widths, {CliStyle? style}) {
    final cells = <String>[];

    for (var i = 0; i < columns.length; i++) {
      final value = i < row.length ? row[i] : '';
      final cell = _alignCell(value, widths[i], columns[i].alignment);
      cells.add(style != null ? style(cell) : cell);
    }

    final border = showBorders
        ? (borderStyle != null ? borderStyle!('│') : '│')
        : ' ';

    return '$border ${cells.join(' $border ')} $border';
  }

  String _alignCell(String value, int width, TableAlignment alignment) {
    final padding = width - value.length;

    return switch (alignment) {
      TableAlignment.left => value.padRight(width),
      TableAlignment.right => value.padLeft(width),
      TableAlignment.center =>
        ' ' * (padding ~/ 2) + value + ' ' * ((padding + 1) ~/ 2),
    };
  }
}
