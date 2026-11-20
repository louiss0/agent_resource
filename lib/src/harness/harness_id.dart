/// A harness-named enum whose wire spelling can be translated once.
abstract interface class HarnessWireNamed {
  String get wireName;
}

/// The identity of a coding harness registered in the descriptor catalog.
enum HarnessId implements HarnessWireNamed {
  claude('claude'),
  codex('codex'),
  pi('pi'),
  antigravity('antigravity');

  const HarnessId(this.wireName);

  /// Stable wire name used in requests and management state.
  @override
  final String wireName;

  String toJson() => wireName;

  static HarnessId fromWire(String value) => values.firstWhere(
    (id) => id.wireName == value,
    orElse: () => throw FormatException('Unknown harness: $value'),
  );

  /// Translates any harness-named enum through its declared wire name.
  static HarnessId of(HarnessWireNamed value) => fromWire(value.wireName);
}
