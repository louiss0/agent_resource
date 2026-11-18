import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The identity of a reviewed context authoring proposal.
///
/// The identifier binds every byte that publication may change and the
/// observed state of an edited template. A changed input therefore produces
/// a different identifier and invalidates a stale apply.
final class const ContextAuthoringPlan({
  required final String operation,
  required final String name,
  required final String targetPath,
  required final bool empty,
  required final String bodySha256,
  required final int bodyByteLength,
  final String? existingSha256,
  final int? existingByteLength,
}) {
  /// The prefix required of every context plan identifier.
  static const String idPrefix = 'pln_';

  /// The plan identity over the canonical, sorted JSON binding.
  String get planId {
    final identity = <String, Object?>{
      'operation': operation,
      'name': name,
      'targetPath': targetPath,
      'empty': empty,
      'body': <String, Object?>{
        'sha256': bodySha256,
        'byteLength': bodyByteLength,
      },
      if (operation == 'edit')
        'existing': <String, Object?>{
          'sha256': existingSha256,
          'byteLength': existingByteLength,
        },
    };
    final canonical = jsonEncode(_sorted(identity));
    return '$idPrefix${sha256.convert(utf8.encode(canonical))}';
  }

  /// Whether [value] can name a context plan.
  static bool isPlanId(String value) =>
      RegExp(r'^pln_[a-f0-9]{64}$').hasMatch(value);

  static Object? _sorted(Object? value) => switch (value) {
    final Map<String, Object?> map => SplayTreeMap<String, Object?>.from(
      map,
      (left, right) => left.compareTo(right),
    )..updateAll((_, item) => _sorted(item)),
    final List<Object?> list => list.map(_sorted).toList(),
    _ => value,
  };
}
