import '../authoring/native_field_matrix.dart';
import '../services/lifecycle_state_service.dart';
import 'harness_facet.dart';
import 'harness_id.dart';

/// The Skill capability declared by one harness.
abstract interface class SkillHarnessSpec implements HarnessFacetSpec {}

/// The Skill rules owned by the harness capability.
///
/// The native field matrix is the authority for named Skill authoring fields.
/// A field that a harness does not declare is refused by the shared authoring
/// input parser rather than silently carried into a native marker. The same
/// facet resolves native roots, so a project Antigravity Skill is the Shared
/// destination rather than a second copy.
extension SkillHarnessFields on SkillHarnessSpec {
  String root(LifecycleContext context, {required bool userScope}) {
    final p = context.fs.path;
    return switch (harness) {
      HarnessId.claude => context.claudeSkillsRoot(),
      HarnessId.codex => context.codexSkillsRoot(),
      HarnessId.pi => p.join(context.piAgentRoot(), 'skills'),
      HarnessId.antigravity =>
        userScope
            ? p.join(context.geminiConfigRoot(), 'skills')
            : context.sharedSkillsRoot(),
    };
  }

  /// The user-scope locations where the harness may expose Skills.
  List<String> userDiscoveryRoots(LifecycleContext context) {
    final p = context.fs.path;
    return switch (harness) {
      HarnessId.antigravity => List<String>.unmodifiable(<String>[
        p.join(context.geminiConfigRoot(), 'skills'),
        p.join(context.geminiRoot(), 'skills'),
      ]),
      _ => <String>[root(context, userScope: true)],
    };
  }

  bool get unifiesSharedProjectRoot => harness == HarnessId.antigravity;

  NativeFieldMatrix nativeSkillFields(AuthoringProfile profile) {
    return NativeFieldMatrix(
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
        if (harness == HarnessId.antigravity)
          ...const <NativeFieldSpec>[]
        else ...<NativeFieldSpec>[
          const NativeFieldSpec(
            name: 'license',
            valueKind: NativeFieldValueKind.text,
            description: 'Declared license of the skill.',
          ),
          const NativeFieldSpec(
            name: 'compatibility',
            valueKind: NativeFieldValueKind.text,
            description: 'Declared harness compatibility of the skill.',
          ),
          const NativeFieldSpec(
            name: 'metadata',
            valueKind: NativeFieldValueKind.map,
            description: 'Additional string metadata entries.',
          ),
          const NativeFieldSpec(
            name: 'allowed-tools',
            valueKind: NativeFieldValueKind.list,
            clearable: true,
            inheritable: true,
            listForm: NativeListForm.scalar,
            description:
                'Complete tool list; a supplied list replaces the field.',
          ),
          if (harness == HarnessId.claude)
            const NativeFieldSpec(
              name: 'disallowed-tools',
              valueKind: NativeFieldValueKind.list,
              clearable: true,
              inheritable: true,
              listForm: NativeListForm.scalar,
              description: 'Complete denied tool list.',
            ),
        ],
      ],
    );
  }
}
