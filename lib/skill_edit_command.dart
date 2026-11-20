import 'package:mamba/mamba.dart';

import 'src/authoring/authoring_inputs.dart';
import 'src/authoring/guided_create_command.dart';

/// The `skill edit` route: a reviewed in-place Skill authoring operation.
final class SkillEditCommand extends GuidedCreateCommand {
  SkillEditCommand({required super.guided, super.terminal})
    : super(
        kind: AuthoringKind.skill,
        options: <Option<Object?>>[_source],
        longDescription:
            'Edit one native Skill through its reviewed authoring plan. '
            'Select the source Skill directory with --source and the native '
            'profile with --profile or --harness. A plan is read-only; '
            'publication requires --apply with the reviewed --plan-id and '
            '--yes, or an explicit interactive review.',
      );

  static final _source = StringOption(
    'source',
    description: 'The native Skill directory to edit.',
  );

  @override
  String get name => 'edit';

  @override
  String get commandPath => 'skill edit';

  @override
  AuthoringOperation get operation => AuthoringOperation.edit;

  @override
  List<AuthoringProfile> get supportedProfiles => const <AuthoringProfile>[
    AuthoringProfile.claude,
    AuthoringProfile.codex,
    AuthoringProfile.pi,
    AuthoringProfile.antigravity,
  ];

  @override
  String get shortDescription => 'Edit a native Skill through a reviewed plan.';

  @override
  String? sourcePath(ValueOf valueOf) => valueOf(_source);
}
