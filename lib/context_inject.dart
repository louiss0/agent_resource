import 'dart:io' show Platform;

import 'package:mamba/mamba.dart';

import 'components/installation_approval.dart';
import 'components/skill_target_selector.dart';
import 'src/context/context_types.dart';
import 'src/services/context_injection_service.dart';
import 'src/services/context_template_service.dart';
import 'src/services/lifecycle_state_service.dart';

import 'context_read_commands.dart';

final _nameOption = StringOption('name');
final _harnessOption = RepeatableChoiceOption<ContextHarness>(
  'harness',
  ContextHarness.values,
);
final _scopeOption = ChoiceOption.withDefault(
  'scope',
  choices: ContextScope.values,
  defaultValue: ContextScope.project,
);
final _folderOption = StringOption('folder');
final _variantOption = StringOption('variant');
final _planIdOption = StringOption('plan-id');
final _projectRootOption = FolderPathOption('project-root');
final _claudeConfigDirOption = FolderPathOption('claude-config-dir');
final _codexHomeOption = FolderPathOption('codex-home');
final _piAgentDirOption = FolderPathOption('pi-agent-dir');

const _replaceFlag = BooleanFlag('replace');
const _applyFlag = BooleanFlag('apply');
const _yesFlag = BooleanFlag('yes');
const _dryRunFlag = BooleanFlag('dry-run');
const _interactiveFlag = BooleanFlag('interactive');
const _unattendedFlag = BooleanFlag('unattended');
const _showInstructionsFlag = BooleanFlag('show-instructions');

/// Injects a stored context template into harness-recognized context files.
final class ContextInjectCommand extends Command {
  ContextInjectCommand(
    this._injection,
    this._templates, {
    Future<List<ContextHarness>?> Function()? selectHarnesses,
    ContextTemplateSelection? selectTemplate,
    Future<bool> Function()? confirm,
    bool Function()? hasTerminal,
    InstallationApprovalComponent? approval,
  }) : _approval =
           approval ??
           const InstallationApprovalComponent(
             label:
                 'Apply this reviewed context injection plan? '
                 '(Ctrl+C to cancel)',
           ),
       _explicitConfirm = confirm,
       _selectHarnesses = selectHarnesses ?? _defaultHarnessSelector,
       _selectTemplate = selectTemplate ?? selectStoredContextTemplate,
       _hasTerminal =
           hasTerminal ??
           (() =>
               approval?.hasTerminal?.call() ??
               contextHasInteractiveTerminal()),
       super(
         discretionaryPositionals: [_nameArgument],
         options: [
           _nameOption,
           _harnessOption,
           _scopeOption,
           _folderOption,
           _variantOption,
           _planIdOption,
           contextFormatOption,
           contextCwdOption,
           _projectRootOption,
           contextHomeOption,
           _claudeConfigDirOption,
           _codexHomeOption,
           _piAgentDirOption,
           contextStateDirOption,
         ],
         flags: [
           _replaceFlag,
           _applyFlag,
           _yesFlag,
           _dryRunFlag,
           _interactiveFlag,
           _unattendedFlag,
           _showInstructionsFlag,
         ],
         conflicts: <String, List<String>>{
           'interactive': <String>['unattended'],
         },
       );

  static final _nameArgument = NormalPositional.optional(
    'name',
    description: 'The context template name to inject.',
  );

  final ContextInjectionService _injection;
  final ContextTemplateService _templates;
  final Future<List<ContextHarness>?> Function() _selectHarnesses;
  final ContextTemplateSelection _selectTemplate;
  final InstallationApprovalComponent _approval;
  final Future<bool> Function()? _explicitConfirm;
  final bool Function() _hasTerminal;

  @override
  String get name => 'inject';

  @override
  String get shortDescription =>
      'Inject a context template into harness context files.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(contextFormatOption);
    requireContextInteractiveFormat(valueOf(_interactiveFlag), format);
    final options = _options(valueOf);
    final interactive =
        !valueOf(_unattendedFlag) &&
        format == ContextOutputFormat.text &&
        (valueOf(_interactiveFlag) || _hasTerminal());
    final name = await _resolveName(valueOf, options, interactive);
    final harnesses = await _resolveHarnesses(valueOf, interactive);
    final scope = valueOf(_scopeOption);
    final folder = valueOf(_folderOption);
    if (folder != null && scope == ContextScope.user) {
      throw _refusal(
        'FOLDER_SCOPE_CONFLICT',
        '--folder is only valid with --scope project.',
      );
    }
    if (folder != null && folder.trim().isEmpty) {
      throw _refusal('INVALID_FOLDER', '--folder must not be blank.');
    }
    final variant = _parseVariant(valueOf(_variantOption));
    final plan = _injection.plan(
      options: options,
      templateName: name,
      harnesses: harnesses,
      scope: scope,
      variant: variant,
      folder: folder,
      replace: valueOf(_replaceFlag),
      showInstructions: valueOf(_showInstructionsFlag),
    );
    final publish = valueOf(_applyFlag) && !valueOf(_dryRunFlag);
    final outcome = publish ? 'published' : 'planned';
    final reported = publish
        ? await _publish(
            options,
            plan,
            valueOf(_planIdOption),
            valueOf(_yesFlag),
            interactive,
          )
        : plan;
    final result = LifecycleResult(
      command: 'context inject',
      outcome: outcome,
      data: reported.toData(),
      diagnostics: _injection.diagnostics(plan),
    );
    return renderContextResult(result, format);
  }

  Future<ContextInjectionPlan> _publish(
    LifecycleOptions options,
    ContextInjectionPlan plan,
    String? planId,
    bool approved,
    bool interactive,
  ) async {
    if (!approved) {
      if (!interactive) {
        throw _refusal(
          'MISSING_APPROVAL',
          'Supply --yes to apply a plan in unattended mode.',
        );
      }
      if (!await _confirm()) {
        throw _cancelled();
      }
    }
    return _injection.publish(
      options: options,
      reviewed: plan,
      suppliedPlanId: planId,
    );
  }

  LifecycleOptions _options(ValueOf valueOf) => contextLifecycleOptions(
    fileSystem: _injection.fileSystem,
    environment: Map<String, String>.unmodifiable(Platform.environment),
    cwd: valueOf(contextCwdOption),
    projectRoot: valueOf(_projectRootOption),
    home: valueOf(contextHomeOption),
    claudeConfigDir: valueOf(_claudeConfigDirOption),
    codexHome: valueOf(_codexHomeOption),
    piAgentDir: valueOf(_piAgentDirOption),
    stateDir: valueOf(contextStateDirOption),
  );

  Future<String> _resolveName(
    ValueOf valueOf,
    LifecycleOptions options,
    bool interactive,
  ) async {
    return resolveContextTemplateName(
      positionalName: valueOf(_nameArgument),
      optionName: valueOf(_nameOption),
      interactive: interactive,
      options: options,
      templates: _templates,
      select: _selectTemplate,
    );
  }

  Future<List<ContextHarness>> _resolveHarnesses(
    ValueOf valueOf,
    bool interactive,
  ) async {
    final supplied = valueOf(_harnessOption);
    if (supplied != null && supplied.isNotEmpty) {
      return <ContextHarness>[
        for (final harness in ContextHarness.values)
          if (supplied.contains(harness)) harness,
      ];
    }
    if (!interactive) {
      throw _refusal(
        'MISSING_TARGET_HARNESS',
        'Supply at least one --harness in unattended mode.',
      );
    }
    final chosen = await _selectHarnesses();
    if (chosen == null || chosen.isEmpty) {
      throw _cancelled();
    }
    return <ContextHarness>[
      for (final harness in ContextHarness.values)
        if (chosen.contains(harness)) harness,
    ];
  }

  ContextVariant _parseVariant(String? raw) => switch (raw) {
    null || 'standard' => ContextVariant.standard,
    'local' => ContextVariant.local,
    'override' => ContextVariant.override,
    'dot-claude' => ContextVariant.dotClaude,
    _ => throw _refusal('INVALID_CONTEXT_VARIANT', 'Unknown variant "$raw".'),
  };

  static Future<List<ContextHarness>?> _defaultHarnessSelector() async {
    final choice = await const SkillTargetSelectorComponent(
      options: <String>['claude', 'codex', 'pi'],
    ).render();
    if (choice == null) return null;
    return <ContextHarness>[
      for (final index in choice) ContextHarness.values[index],
    ];
  }

  Future<bool> _confirm() => _explicitConfirm?.call() ?? _approval.render();

  MambaException _refusal(String code, String message) =>
      MambaException('$code: $message', exitCode: 4);

  MambaException _cancelled() => MambaException(
    'CANCELLED: Context injection was cancelled.',
    exitCode: 7,
  );
}
