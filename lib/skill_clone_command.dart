import 'package:mamba/mamba.dart';

import 'src/authoring/authoring_inputs.dart';
import 'src/authoring/guided_create_command.dart';

/// The `skill clone` route: a reviewed copy of one native Skill.
final class SkillCloneCommand extends GuidedCreateCommand {
  SkillCloneCommand({required super.guided, super.terminal})
    : super(
        kind: AuthoringKind.skill,
        options: <Option<Object?>>[_source],
        longDescription:
            'Clone one native Skill into a separate reviewed output. '
            'The source instructions are preserved: no instruction body is '
            'collected or replaced. Select the source Skill directory with '
            '--source and the native profile with --profile or --harness. '
            'A plan is read-only; publication requires --apply with the '
            'reviewed --plan-id and --yes, or an explicit interactive review.',
      );

  static final _source = StringOption(
    'source',
    description: 'The native Skill directory to clone.',
  );

  @override
  String get name => 'clone';

  @override
  String get commandPath => 'skill clone';

  @override
  AuthoringOperation get operation => AuthoringOperation.clone;

  @override
  List<AuthoringProfile> get supportedProfiles => const <AuthoringProfile>[
    AuthoringProfile.claude,
    AuthoringProfile.codex,
    AuthoringProfile.pi,
    AuthoringProfile.antigravity,
  ];

  @override
  String get shortDescription =>
      'Clone a native Skill through a reviewed plan.';

  @override
  String? sourcePath(ValueOf valueOf) => valueOf(_source);
}
