import 'dart:convert';

import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/authoring/authoring_inputs.dart';
import 'src/authoring/bound_role_authoring_inputs.dart';
import 'src/authoring/guided_create_command.dart';
import 'src/authoring/guided_create_fields.dart';
import 'src/services/bound_role_authoring_service.dart';
import 'src/services/bound_role_service.dart' show BoundOwnership;
import 'src/services/lifecycle_state_service.dart';

/// The guidance that replaces the retired JSON operation request.
const String agentCreateMigrationGuidance =
    'JSON operation-request authoring is retired. Use the named native '
    'selections instead: --profile claude|codex|pi, --name, --description, '
    '--model, --tools, --skills, --argument-hint, --license, '
    '--compatibility, --body-file, --body-stdin or --body-text, --output, '
    '--manage, --scope, --apply, --yes and --plan-id. For a Codex bound role '
    'use --role-key, --config-file, --ownership, --definition-source, '
    '--definition-output and --ack-clients-stopped.';

/// The `agent create` command.
///
/// The command owns two routes that are switched together: the standalone
/// creation of one native Agent and the explicit creation of a Codex
/// bound-role Agent. The retired JSON operation request is refused with
/// migration guidance; there is no compatibility escape.
final class AgentCreateCommand extends GuidedCreateCommand {
  AgentCreateCommand({
    required super.guided,
    BoundRoleAuthoringService? boundRole,
    super.terminal,
  }) : _boundRole =
           boundRole ??
           BoundRoleAuthoringService(fileSystem: guided.fileSystem),
       super(
         kind: AuthoringKind.agent,
         positionals: <DiscretionaryPositional<Object?>>[_retiredRequest],
         options: [
           _retiredRequestOption,
           _roleKey,
           _configFile,
           _ownership,
           _definitionSource,
           _definitionOutput,
         ],
         flags: const [_ackClientsStopped],
         longDescription:
             'Create one native Agent, or one explicit Codex bound-role '
             'Agent, from named native selections and a plain-text '
             'instruction body. Select the native profile explicitly with '
             '--profile; it is never inferred from a file name. The '
             'instruction body comes from --body-file, --body-stdin or '
             '--body-text; on a usable terminal the guided flow opens the '
             'configured editor for the body when no body was supplied. The '
             'route buffers a piped standard input, and the buffer is used '
             'only when --body-stdin selects it; an interactive terminal is '
             'never read. A new output is author-only: no installation '
             'record is created '
             'unless --manage selects a supported managed form. The '
             'reviewed proposal names its target, its ownership and its '
             'changes before the publication is confirmed. --dry-run plans '
             'without an editor, without a draft and without a write. A '
             'published output removes the retained application-owned draft '
             'and never removes the original body file. The bound-role '
             'route publishes the reviewed Codex definition of '
             '--definition-source and registers the role in the declaring '
             'config only when --ownership selects it; a registration '
             'requires --ack-clients-stopped and a separate approval. No '
             'harness, provider or client is executed. The retired JSON '
             'operation request is refused: $agentCreateMigrationGuidance',
       );

  final BoundRoleAuthoringService _boundRole;

  static final _retiredRequest = FilePathPositional.optional(
    'operation-request',
    suffixes: const ['.json'],
    description:
        'Retired. A JSON operation request is refused with migration '
        'guidance.',
  );

  static final _retiredRequestOption = FilePathOption(
    'request',
    suffixes: const ['.json'],
    description:
        'Retired. A JSON operation request is refused with migration '
        'guidance.',
  );

  static final _roleKey = StringOption(
    BoundRoleAuthoringFlags.roleKey,
    description: 'The Codex role key of the created bound role.',
  );
  static final _configFile = StringOption(
    BoundRoleAuthoringFlags.configFile,
    description: 'The declaring Codex config that owns the role registration.',
  );
  static final _ownership = ChoiceOption(
    BoundRoleAuthoringFlags.ownership,
    choices: BoundOwnership.values,
    description:
        'The ownership the bound-role operation claims: the definition, '
        'the definition and its registration, or the registration alone.',
  );
  static final _definitionSource = StringOption(
    BoundRoleAuthoringFlags.definitionSource,
    description:
        'The reviewed native Codex definition that the bound role '
        'publishes.',
  );
  static final _definitionOutput = StringOption(
    BoundRoleAuthoringFlags.definitionOutput,
    description: 'The explicit placement of the published definition.',
  );
  static const _ackClientsStopped = BooleanFlag(
    BoundRoleAuthoringFlags.ackClientsStopped,
    description:
        'Acknowledge that the native clients are stopped for the parent '
        'write.',
  );

  @override
  String get name => 'create';

  @override
  String get commandPath => 'agent create';

  @override
  List<AuthoringProfile> get supportedProfiles => const <AuthoringProfile>[
    AuthoringProfile.claude,
    AuthoringProfile.codex,
    AuthoringProfile.pi,
  ];

  @override
  String get shortDescription =>
      'Create a native Agent, or an explicit Codex bound role.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    if (valueOf(_retiredRequest) != null ||
        valueOf(_retiredRequestOption) != null) {
      throw MambaException(agentCreateMigrationGuidance, exitCode: 4);
    }
    if (_boundRoleSelected(valueOf)) {
      return _runBoundRole(valueOf);
    }
    return super.run(valueOf, args);
  }

  /// Whether the operator selected the bound-role route.
  bool _boundRoleSelected(ValueOf valueOf) =>
      valueOf(_roleKey) != null ||
      valueOf(_configFile) != null ||
      valueOf(_ownership) != null ||
      valueOf(_definitionSource) != null ||
      valueOf(_definitionOutput) != null ||
      valueOf(_ackClientsStopped);

  /// The explicit bound-role route.
  Future<String> _runBoundRole(ValueOf valueOf) async {
    final format = valueOf(GuidedCreateFields.format);
    final interactive = resolveInteractive(valueOf, format);
    final options = buildOptions(valueOf);
    final inputs = parseBoundRoleAuthoringInputs(
      roleKey: valueOf(_roleKey),
      configFile: valueOf(_configFile),
      ownership: valueOf(_ownership)?.name,
      definitionSource: valueOf(_definitionSource),
      definitionOutput: valueOf(_definitionOutput),
      clientsStopped: valueOf(_ackClientsStopped),
    );
    if (valueOf(GuidedCreateFields.profile) != null ||
        valueOf(GuidedCreateFields.name) != null ||
        valueOf(GuidedCreateFields.description) != null ||
        valueOf(GuidedCreateFields.model) != null ||
        valueOf(GuidedCreateFields.tools) != null ||
        valueOf(GuidedCreateFields.skills) != null ||
        valueOf(GuidedCreateFields.allowedTools) != null ||
        valueOf(GuidedCreateFields.disallowedTools) != null ||
        valueOf(GuidedCreateFields.metadata) != null ||
        valueOf(GuidedCreateFields.argumentHint) != null ||
        valueOf(GuidedCreateFields.license) != null ||
        valueOf(GuidedCreateFields.compatibility) != null ||
        valueOf(GuidedCreateFields.editor) != null ||
        valueOf(GuidedCreateFields.showInstructions) ||
        valueOf(GuidedCreateFields.bodyFile) != null ||
        valueOf(GuidedCreateFields.bodyStdin) ||
        valueOf(GuidedCreateFields.bodyText) != null ||
        valueOf(GuidedCreateFields.output) != null ||
        valueOf(GuidedCreateFields.manage)) {
      throw MambaException(
        'The bound-role route does not accept the standalone authoring '
        'selections; publish the standalone Agent first and name it with '
        '--${BoundRoleAuthoringFlags.definitionSource}.',
        exitCode: 4,
      );
    }
    final planned = await _boundRole.plan(inputs, options);
    final planId = planned.data['planId'] as String?;
    final requested = valueOf(GuidedCreateFields.planId);
    if (requested != null && requested != planId) {
      throw MambaException(
        'The supplied plan ID is stale; the current proposal is $planId.',
        exitCode: 4,
      );
    }
    final apply = valueOf(GuidedCreateFields.apply);
    if (!apply) {
      return _renderResult(planned, format);
    }
    if (interactive && !options.approved) {
      final confirmed = await confirmation(
        'Publish the reviewed bound role ${inputs.roleKey} and register it '
        'in ${inputs.configFile}?',
      );
      if (!confirmed) {
        throw MambaException(
          'The publication was cancelled; no output was written.',
          exitCode: 7,
        );
      }
    } else if (!options.approved) {
      throw MambaException(
        'Publication requires --yes in an unattended session.',
        exitCode: 4,
      );
    }
    final published = await _boundRole.apply(
      inputs,
      options.copyWith(approved: true),
      planId: planId!,
    );
    return _renderResult(published, format);
  }

  /// The rendered result of the bound-role route.
  String _renderResult(LifecycleResult result, LifecycleOutputFormat format) =>
      format == LifecycleOutputFormat.json
      ? jsonEncode(result.envelope())
      : result.renderText();
}
