import 'src/authoring/authoring_inputs.dart';
import 'src/authoring/guided_create_command.dart';

/// The `prompt create` command.
///
/// The command creates one native Prompt from named native selections and a
/// plain-text instruction body. It never accepts a JSON operation request.
final class PromptCreateCommand extends GuidedCreateCommand {
  PromptCreateCommand({required super.guided, super.terminal})
    : super(
        kind: AuthoringKind.prompt,
        longDescription:
            'Create one native Prompt from named native selections and a '
            'plain-text instruction body. Select the native profile '
            'explicitly with --profile (claude, codex, pi or global); it '
            'is never inferred from a file name. The instruction body '
            'comes from --body-file, --body-stdin or --body-text; on a '
            'usable terminal the guided flow opens the configured editor '
            'for the body when no body was supplied. The route buffers a '
            'piped standard input, and the buffer is used only when '
            '--body-stdin selects it; an interactive terminal is never read. '
            'A Prompt has no '
            'managed lifecycle: --manage is refused for every profile '
            'instead of falling back to an author-only output. The '
            'reviewed proposal names its target, its ownership and its '
            'changes before the publication is confirmed. --dry-run plans '
            'without an editor, without a draft and without a write. A '
            'published output removes the retained application-owned draft '
            'and never removes the original body file. No harness, '
            'provider or client is executed.',
      );

  @override
  String get name => 'create';

  @override
  String get commandPath => 'prompt create';

  @override
  List<AuthoringProfile> get supportedProfiles => const <AuthoringProfile>[
    AuthoringProfile.claude,
    AuthoringProfile.codex,
    AuthoringProfile.pi,
    AuthoringProfile.global,
  ];

  @override
  String get shortDescription => 'Create a native Prompt from plain text.';
}
