import 'harness_id.dart';

/// One registered harness and the composed capabilities it supports.
final class HarnessDescriptor {
  const HarnessDescriptor({required this.id});

  final HarnessId id;

  String get wireName => id.wireName;
}
