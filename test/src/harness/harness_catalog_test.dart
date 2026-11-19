import 'package:agent_resource/src/harness/harness_catalog.dart';
import 'package:mamba/mamba.dart';
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

    test('refuses unsupported facets with the category exit code', () {
      final catalog = HarnessCatalog.instance;
      final refusal = catalog.refusal(
        HarnessId.antigravity,
        HarnessFacet.prompt,
        exitCode: 4,
      )!;
      final invalidInputRefusal = catalog.refusal(
        HarnessId.antigravity,
        HarnessFacet.prompt,
        exitCode: 2,
      )!;

      expect(refusal.harness, HarnessId.antigravity);
      expect(refusal.facet, HarnessFacet.prompt);
      expect(refusal.code, 'UNSUPPORTED_HARNESS_FACET');
      expect(
        refusal.message,
        'UNSUPPORTED_HARNESS_FACET: Harness "antigravity" does not support '
        'the "prompt" Resource category.',
      );
      expect(invalidInputRefusal.message, refusal.message);
      expect(refusal.toException().exitCode, 4);
      expect(invalidInputRefusal.toException().exitCode, 2);
      expect(
        () => catalog.requireFacet(
          HarnessId.antigravity,
          HarnessFacet.prompt,
          refusalExitCode: 2,
        ),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'exit code', 2)
              .having(
                (error) => error.message,
                'message',
                contains('UNSUPPORTED_HARNESS_FACET'),
              ),
        ),
      );
      expect(catalog.refusal(HarnessId.claude, HarnessFacet.prompt), isNull);
      expect(
        catalog.requireFacet(HarnessId.pi, HarnessFacet.agent).harness,
        HarnessId.pi,
      );
    });
  });
}
