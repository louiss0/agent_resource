import 'package:agent_resource/src/authoring/authoring_inputs.dart';
import 'package:agent_resource/src/context/context_types.dart';
import 'package:agent_resource/src/harness/harness_catalog.dart';
import 'package:agent_resource/src/services/lifecycle_state_service.dart';
import 'package:file/memory.dart';
import 'package:test/test.dart';

void main() {
  group('composed harness facets own metadata and algorithms', () {
    final catalog = HarnessCatalog.instance;

    test('every registered harness supplies concrete category facets', () {
      for (final id in HarnessId.values) {
        final context = catalog.facet(id, HarnessFacet.context);
        final skill = catalog.facet(id, HarnessFacet.skill);
        final agent = catalog.facet(id, HarnessFacet.agent);
        expect(context, isA<ContextHarnessFacet>(), reason: id.wireName);
        expect(skill, isA<SkillHarnessFacet>(), reason: id.wireName);
        expect(agent, isA<AgentHarnessFacet>(), reason: id.wireName);
        expect(
          context,
          same(contextHarnessFacets[id]),
          reason: '${id.wireName} context facet',
        );
        expect(
          skill,
          same(skillHarnessFacets[id]),
          reason: '${id.wireName} skill facet',
        );
        expect(
          agent,
          same(agentHarnessFacets[id]),
          reason: '${id.wireName} agent facet',
        );
      }
    });

    test('facet metadata is registered per harness', () {
      expect(
        (catalog.agentSpecById(
          HarnessId.antigravity,
        ) as AgentHarnessFacet).nestedLayouts,
        isTrue,
      );
      expect(catalog.agentSpecById(HarnessId.pi).caseInsensitiveNames, isTrue);
      expect(catalog.agentSpecById(HarnessId.claude).effortKey, 'effort');
      expect(
        catalog.agentSpecById(HarnessId.codex).effortKey,
        'model_reasoning_effort',
      );
      expect(catalog.agentSpecById(HarnessId.antigravity).effortKey, isNull);
      expect(
        catalog.agentSpecById(HarnessId.antigravity).authoringProfile.name,
        'antigravity',
      );
      expect(
        (catalog.facet(
          HarnessId.antigravity,
          HarnessFacet.skill,
        ) as SkillHarnessFacet).unifiesSharedProjectRoot,
        isTrue,
      );
      expect(
        (catalog.facet(
          HarnessId.claude,
          HarnessFacet.context,
        ) as ContextHarnessFacet).targets.keys,
        contains((ContextScope.project, ContextVariant.local)),
      );
    });

    test(
      'a descriptor resolves a native path through its supplied facet',
      () async {
        final fs = MemoryFileSystem(style: FileSystemStyle.posix);
        final project = fs.directory('/project')..createSync();
        final home = fs.directory('/home')..createSync();
        final context = LifecycleContext.resolve(
          LifecycleOptions(
            processWorkingDirectory: project.path,
            cwd: project.path,
            projectRoot: project.path,
            home: home.path,
          ),
          fileSystem: fs,
        );
        final targets = <(ContextScope, ContextVariant), ContextTarget>{
          (ContextScope.project, ContextVariant.standard): const ContextTarget([
            'OWNED.md',
          ]),
        };
        final facet = ContextHarnessFacet(HarnessId.codex, targets);
        final descriptor = HarnessDescriptor.composed(
          HarnessId.codex,
          userRoot: (roots) => roots.codexRoot(),
          context: facet,
          skill: skillHarnessFacets[HarnessId.codex]!,
          agent: agentHarnessFacets[HarnessId.codex]!,
        );
        expect(descriptor.context, same(facet));
        expect(
          facet.resolveTargetPath(
            context: context,
            scope: ContextScope.project,
            variant: ContextVariant.standard,
            projectTargetDir: project.path,
          ),
          fs.path.join(project.path, 'OWNED.md'),
        );
        expect(
          () => facet.resolveTargetPath(
            context: context,
            scope: ContextScope.user,
            variant: ContextVariant.gemini,
            projectTargetDir: project.path,
          ),
          throwsA(isA<Exception>()),
        );
      },
    );

    test('the Skill facet owns its native field matrix', () {
      final facet =
          catalog.facet(HarnessId.antigravity, HarnessFacet.skill)!
              as SkillHarnessSpec;
      final matrix = facet.nativeSkillFields(AuthoringProfile.antigravity);
      expect(
        matrix.fields.map((field) => field.name),
        unorderedEquals(<String>['name', 'description']),
      );
      final claude =
          catalog.facet(HarnessId.claude, HarnessFacet.skill)!
              as SkillHarnessSpec;
      expect(
        claude
            .nativeSkillFields(AuthoringProfile.claude)
            .fields
            .map((field) => field.name),
        contains('disallowed-tools'),
      );
    });
  });
}
