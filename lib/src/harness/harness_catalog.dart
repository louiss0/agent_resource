import 'harness_descriptor.dart';
import 'harness_id.dart';

export 'harness_descriptor.dart';
export 'harness_id.dart';

/// The single registry of harness identities and their composed descriptors.
final class HarnessCatalog {
  const HarnessCatalog._(this._descriptors);

  static final HarnessCatalog instance = HarnessCatalog._(
    List<HarnessDescriptor>.unmodifiable(<HarnessDescriptor>[
      HarnessDescriptor(id: HarnessId.claude),
      HarnessDescriptor(id: HarnessId.codex),
      HarnessDescriptor(id: HarnessId.pi),
      HarnessDescriptor(id: HarnessId.antigravity),
    ]),
  );

  final List<HarnessDescriptor> _descriptors;

  List<HarnessDescriptor> get descriptors => _descriptors;

  HarnessDescriptor byId(HarnessId id) =>
      _descriptors.firstWhere((descriptor) => descriptor.id == id);

  HarnessDescriptor byWireName(String wireName) =>
      byId(HarnessId.fromWire(wireName));
}
