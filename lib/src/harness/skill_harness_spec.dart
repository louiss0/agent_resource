import '../authoring/native_field_matrix.dart';
import '../services/lifecycle_state_service.dart';
import 'harness_facet.dart';
import 'harness_id.dart';

/// The native user root that holds one harness's Skills.
enum SkillUserRoot { claude, codex, pi, gemini, geminiConfig }

/// The Skill capability declared by one harness.
///
/// The facet carries its roots, discovery roots and native field matrix. The
/// Skill services call these members instead of translating harness enums in
/// another switch.
abstract interface class SkillHarnessSpec implements HarnessFacetSpec {
  SkillUserRoot get userRoot;
  List<SkillUserRoot> get userDiscoveryRoots;
  bool get unifiesSharedProjectRoot;
  List<NativeFieldSpec> get additionalFields;

  String root(LifecycleContext context, {required bool userScope});

  List<String> discoveryRoots(LifecycleContext context);

  NativeFieldMatrix nativeSkillFields(AuthoringProfile profile);
}

/// The registered Skill facets, one per harness identity.
final class SkillHarnessFacet implements SkillHarnessSpec {
  const SkillHarnessFacet({
    required this.harness,
    required this.userRoot,
    this.userDiscoveryRoots = const <SkillUserRoot>[],
    this.unifiesSharedProjectRoot = false,
    this.additionalFields = const <NativeFieldSpec>[],
  });

  @override
  final HarnessId harness;

  @override
  HarnessFacet get facet => HarnessFacet.skill;

  @override
  final SkillUserRoot userRoot;

  @override
  final List<SkillUserRoot> userDiscoveryRoots;

  @override
  final bool unifiesSharedProjectRoot;

  @override
  final List<NativeFieldSpec> additionalFields;

  static const _license = NativeFieldSpec(
    name: 'license',
    valueKind: NativeFieldValueKind.text,
    description: 'Declared license of the skill.',
  );
  static const _compatibility = NativeFieldSpec(
    name: 'compatibility',
    valueKind: NativeFieldValueKind.text,
    description: 'Declared harness compatibility of the skill.',
  );
  static const _metadata = NativeFieldSpec(
    name: 'metadata',
    valueKind: NativeFieldValueKind.map,
    description: 'Additional string metadata entries.',
  );
  static const _allowedTools = NativeFieldSpec(
    name: 'allowed-tools',
    valueKind: NativeFieldValueKind.list,
    clearable: true,
    inheritable: true,
    listForm: NativeListForm.scalar,
    description: 'Complete tool list; a supplied list replaces the field.',
  );
  static const _disallowedTools = NativeFieldSpec(
    name: 'disallowed-tools',
    valueKind: NativeFieldValueKind.list,
    clearable: true,
    inheritable: true,
    listForm: NativeListForm.scalar,
    description: 'Complete denied tool list.',
  );

  String _rootFor(SkillUserRoot root, LifecycleContext context) {
    final p = context.fs.path;
    return switch (root) {
      SkillUserRoot.claude => context.claudeSkillsRoot(),
      SkillUserRoot.codex => context.codexSkillsRoot(),
      SkillUserRoot.pi => p.join(context.piAgentRoot(), 'skills'),
      SkillUserRoot.gemini => p.join(context.geminiRoot(), 'skills'),
      SkillUserRoot.geminiConfig => p.join(
        context.geminiConfigRoot(),
        'skills',
      ),
    };
  }

  @override
  String root(LifecycleContext context, {required bool userScope}) {
    if (!userScope && unifiesSharedProjectRoot) {
      return context.sharedSkillsRoot();
    }
    return _rootFor(userRoot, context);
  }

  @override
  List<String> discoveryRoots(LifecycleContext context) =>
      switch (userDiscoveryRoots.isEmpty) {
        true => <String>[root(context, userScope: true)],
        false => List<String>.unmodifiable(<String>[
          for (final root in userDiscoveryRoots) _rootFor(root, context),
        ]),
      };

  @override
  NativeFieldMatrix nativeSkillFields(AuthoringProfile profile) =>
      NativeFieldMatrix(
        kind: AuthoringKind.skill,
        profile: profile,
        fields: <NativeFieldSpec>[
          const NativeFieldSpec(
            name: 'name',
            valueKind: NativeFieldValueKind.text,
            required: true,
            description: 'Native skill name; it must match the directory name.',
          ),
          const NativeFieldSpec(
            name: 'description',
            valueKind: NativeFieldValueKind.text,
            required: true,
            description: 'When the harness should offer this skill.',
          ),
          ...additionalFields,
        ],
      );
}

const _commonSkillFields = <NativeFieldSpec>[
  SkillHarnessFacet._license,
  SkillHarnessFacet._compatibility,
  SkillHarnessFacet._metadata,
  SkillHarnessFacet._allowedTools,
];

/// The registered Skill facets, one per harness identity.
const skillHarnessFacets = <HarnessId, SkillHarnessSpec>{
  HarnessId.claude: SkillHarnessFacet(
    harness: HarnessId.claude,
    userRoot: SkillUserRoot.claude,
    additionalFields: <NativeFieldSpec>[
      ..._commonSkillFields,
      SkillHarnessFacet._disallowedTools,
    ],
  ),
  HarnessId.codex: SkillHarnessFacet(
    harness: HarnessId.codex,
    userRoot: SkillUserRoot.codex,
    additionalFields: _commonSkillFields,
  ),
  HarnessId.pi: SkillHarnessFacet(
    harness: HarnessId.pi,
    userRoot: SkillUserRoot.pi,
    additionalFields: _commonSkillFields,
  ),
  HarnessId.antigravity: SkillHarnessFacet(
    harness: HarnessId.antigravity,
    userRoot: SkillUserRoot.geminiConfig,
    userDiscoveryRoots: <SkillUserRoot>[
      SkillUserRoot.geminiConfig,
      SkillUserRoot.gemini,
    ],
    unifiesSharedProjectRoot: true,
  ),
};
