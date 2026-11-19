/// The identity of a coding harness registered in the descriptor catalog.
enum HarnessId {
  claude('claude'),
  codex('codex'),
  pi('pi'),
  antigravity('antigravity');

  const HarnessId(this.wireName);

  /// Stable wire name used in requests and management state.
  final String wireName;

  String toJson() => wireName;

  static HarnessId fromWire(String value) => values.firstWhere(
    (id) => id.wireName == value,
    orElse: () => throw FormatException('Unknown harness: $value'),
  );
}
