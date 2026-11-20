import 'src/authoring/authoring_inputs.dart';
import 'src/authoring/guided_create_command.dart';

/// The `skill create` command.
///
/// The command creates one native Skill from named native selections and a
/// plain-text instruction body. It never accepts a JSON operation request.
final class SkillCreateCommand extends GuidedCreateCommand {
  SkillCreateCommand({required super.guided, super.terminal})
    : super(
        kind: AuthoringKind.skill,
        longDescription:
            'Create one native Skill from named native selections and a '
            'plain-text instruction body. Select the native profile '
            'explicitly with --profile; it is never inferred from a file '
            'name. The instruction body comes from --body-file, '
            '--body-stdin or --body-text; on a usable terminal the guided '
            'flow opens the configured editor for the body when no body '
            'was supplied. The route buffers a piped standard input, and the '
            'buffer is used only when --body-stdin selects it; an '
            'interactive terminal is never read. A new output is author-only: '
            'no installation '
            'record is created unless --manage selects a supported managed '
            'form. The reviewed proposal names its target, its ownership '
            'and its changes before the publication is confirmed. '
            '--dry-run plans without an editor, without a draft and '
            'without a write. A published output removes the retained '
            'application-owned draft and never removes the original body '
            'file. No harness, provider or client is executed.',
      );

  @override
  String get name => 'create';

  @override
  String get commandPath => 'skill create';

  @override
  List<AuthoringProfile> get supportedProfiles => const <AuthoringProfile>[
    AuthoringProfile.claude,
    AuthoringProfile.codex,
    AuthoringProfile.pi,
    AuthoringProfile.antigravity,
  ];

  @override
  String get shortDescription => 'Create a native Skill from plain text.';
}
