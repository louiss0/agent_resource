enum PointStyle {
  bullet, // •
  dash, // -
  arrow, // →
  check, // ✓
  cross, // ✗
  star, // ★
  diamond, // ◆
  circle, // ○
  square, // ■
  triangle, // ▶
  dot, // ·
  plus, // +
}

extension PointStyleSymbol on PointStyle {
  String get symbol {
    switch (this) {
      case PointStyle.bullet:
        return '•';
      case PointStyle.dash:
        return '-';
      case PointStyle.arrow:
        return '→';
      case PointStyle.check:
        return '✓';
      case PointStyle.cross:
        return '✗';
      case PointStyle.star:
        return '★';
      case PointStyle.diamond:
        return '◆';
      case PointStyle.circle:
        return '○';
      case PointStyle.square:
        return '■';
      case PointStyle.triangle:
        return '▶';
      case PointStyle.dot:
        return '·';
      case PointStyle.plus:
        return '+';
    }
  }
}
