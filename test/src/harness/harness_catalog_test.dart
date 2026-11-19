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

    test('reports supported Resource categories without a hooks facet', () {
      final catalog = HarnessCatalog.instance;
      const supported = <HarnessId>[
        HarnessId.claude,
        HarnessId.codex,
        HarnessId.pi,
        HarnessId.antigravity,
      ];
      const promptSupported = <HarnessId>[
        HarnessId.claude,
        HarnessId.codex,
        HarnessId.pi,
      ];

      expect(HarnessFacet.values.map((facet) => facet.wireName), <String>[
        'context',
        'mcp',
        'skill',
        'prompt',
        'agent',
      ]);
      expect(catalog.harnessesSupporting(HarnessFacet.context), supported);
      expect(catalog.harnessesSupporting(HarnessFacet.mcp), supported);
      expect(catalog.harnessesSupporting(HarnessFacet.skill), supported);
      expect(catalog.harnessesSupporting(HarnessFacet.prompt), promptSupported);
      expect(catalog.harnessesSupporting(HarnessFacet.agent), supported);
      expect(
        catalog.supports(HarnessId.antigravity, HarnessFacet.prompt),
        isFalse,
      );
      expect(catalog.facet(HarnessId.antigravity, HarnessFacet.prompt), isNull);
      expect(catalog.byId(HarnessId.antigravity).prompt, isNull);
      expect(
        catalog.facet(HarnessId.antigravity, HarnessFacet.agent)?.harness,
        HarnessId.antigravity,
      );
    });
  });
}
