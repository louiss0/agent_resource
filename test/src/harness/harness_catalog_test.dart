import 'package:agent_resource/src/harness/harness_catalog.dart';
import 'package:test/test.dart';

void main() {
  group('HarnessCatalog', () {
    test('registers four harnesses by identity and wire name', () {
      final catalog = HarnessCatalog.instance;

      expect(
        catalog.descriptors.map((descriptor) => descriptor.id),
        <HarnessId>[
          HarnessId.claude,
          HarnessId.codex,
          HarnessId.pi,
          HarnessId.antigravity,
        ],
      );
      expect(catalog.byWireName('antigravity').id, HarnessId.antigravity);
      expect(catalog.byId(HarnessId.pi).wireName, 'pi');
      expect(HarnessId.fromWire('codex'), HarnessId.codex);
      expect(() => catalog.byWireName('Gemini'), throwsFormatException);
    });
  });
}
