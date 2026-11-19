import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/harness/harness_catalog.dart';
import 'package:mamba/mamba.dart';
import 'package:test/test.dart';

void main() {
  group('Skill and Prompt harness specs', () {
    test('declares Antigravity Skills with only name and description', () {
      final matrix = NativeFieldMatrix.forKind(
        AuthoringKind.skill,
        AuthoringProfile.antigravity,
      );
      expect(matrix.supportedNames, <String>['description', 'name']);
      for (final field in matrix.fields) {
        expect(field.required, isTrue);
      }
      final spec = HarnessCatalog.instance.requireFacet(
        HarnessId.antigravity,
        HarnessFacet.skill,
      );
      expect(spec.harness, HarnessId.antigravity);
    });

    test('has no Antigravity Prompt facet and explains the refusal', () {
      final catalog = HarnessCatalog.instance;
      expect(catalog.facet(HarnessId.antigravity, HarnessFacet.prompt), isNull);
      expect(
        catalog.supports(HarnessId.antigravity, HarnessFacet.prompt),
        isFalse,
      );
      expect(
        () => catalog.requirePromptFacet(HarnessId.antigravity),
        throwsA(
          isA<MambaException>()
              .having((error) => error.exitCode, 'exit code', 4)
              .having(
                (error) => error.message,
                'message',
                allOf(
                  contains('antigravity'),
                  contains('.agents/skills'),
                  contains('ordinary Skills'),
                ),
              ),
        ),
      );
    });
  });
}
