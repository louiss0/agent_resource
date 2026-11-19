import 'package:mamba/mamba.dart';

import 'harness_facet.dart';
import 'harness_id.dart';

/// The deterministic usage refusal for a harness without a category facet.
final class HarnessFacetRefusal {
  const HarnessFacetRefusal._({
    required this.harness,
    required this.facet,
    required this.exitCode,
  });

  factory HarnessFacetRefusal.unsupported(
    HarnessId harness,
    HarnessFacet facet, {
    required int exitCode,
  }) {
    if (exitCode != 2 && exitCode != 4) {
      throw ArgumentError.value(
        exitCode,
        'exitCode',
        'A category contract must refuse with exit code 2 or 4.',
      );
    }
    return HarnessFacetRefusal._(
      harness: harness,
      facet: facet,
      exitCode: exitCode,
    );
  }

  static const String _code = 'UNSUPPORTED_HARNESS_FACET';

  final HarnessId harness;
  final HarnessFacet facet;
  final int exitCode;

  String get code => _code;

  String get message =>
      '$_code: Harness "${harness.wireName}" does not support '
      'the "${facet.wireName}" Resource category.';

  MambaException toException() => MambaException(message, exitCode: exitCode);
}
