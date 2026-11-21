import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'conversion.dart';
import 'lifecycle.dart' show LifecycleOutputFormat;
import 'prompt_create_command.dart';
import 'src/prompt/prompt_native_view.dart';
import 'src/prompt/prompt_validation_failure.dart';
import 'src/services/conversion_coordinator_service.dart';
import 'src/services/guided_authoring_service.dart';
import 'src/services/conversion_restore_service.dart';
import 'src/harness/harness_catalog.dart';
import 'src/services/lifecycle_state_service.dart';
import 'src/services/prompt_read_service.dart';
import 'src/services/prompt_inspection_service.dart';

final class PromptCommand extends GroupCommand {
  PromptCommand(
    ConversionCoordinator coordinator, {
    PromptReadService? read,
    GuidedAuthoringService? guided,
    ConversionRestoreService? restore,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : super([
         PromptCreateCommand(
           guided: guided ?? GuidedAuthoringService(fileSystem: fileSystem),
         ),
         ConversionCommand(coordinator, restore: restore),
         PromptInspectCommand(
           read ?? PromptReadService(fileSystem: fileSystem),
         ),
         PromptValidateCommand(
           read ?? PromptReadService(fileSystem: fileSystem),
         ),
         PromptListCommand(
           read ?? PromptReadService(fileSystem: fileSystem),
           fileSystem: fileSystem,
           guided: guided,
         ),
       ]);

  @override
  String get name => 'prompt';

  @override
  String get shortDescription =>
      'Create, inspect, and recover native Prompts and Prompt transactions.';
}

/// The consuming harness of a read-only Prompt report.
final ChoiceOption _promptTarget = ChoiceOption(
  'target',
  choices: const [
    PromptConsumer.claude,
    PromptConsumer.codex,
    PromptConsumer.pi,
    PromptConsumer.antigravity,
  ],
  description:
      'The consuming harness of the report. Without it the report shows the '
      'differing native-control views of every consumer.',
);

final _promptPath = StringOption.required(
  'path',
  regex: RegExp(r'^\s*\S[\s\S]*$'),
  description: 'Native Prompt package directory or template file.',
);
final _promptFormat = ChoiceOption.withDefault(
  'format',
  choices: LifecycleOutputFormat.values,
  defaultValue: LifecycleOutputFormat.text,
);

void _requirePromptTarget(PromptConsumer? target) {
  if (target == PromptConsumer.antigravity) {
    HarnessCatalog.instance.requirePromptFacet(HarnessId.antigravity);
  }
}

final class PromptInspectCommand extends Command {
  PromptInspectCommand(this._read)
    : super(
        options: [_path, _target, _format],
        longDescription:
            'Reads one explicit native source and reports its per-consumer '
            'Prompt views. A directory is inspected as a skill-backed Prompt '
            'package and a Markdown file as a standalone native template. '
            'The report distinguishes the native form from the observed '
            'placement and it never claims one universal classification. '
            'The report never discloses an instruction body, never creates a '
            'management artifact and never installs a resource.',
      );

  final PromptReadService _read;

  static final _path = _promptPath;
  static final _target = _promptTarget;
  static final _format = _promptFormat;

  @override
  String get name => 'inspect';

  @override
  String get shortDescription => 'Inspect one explicit native Prompt source.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final target = valueOf(_target) as PromptConsumer?;
    _requirePromptTarget(target);
    final views = await _read.inspect(valueOf(_path), consumer: target);
    return _renderPromptViews(views, valueOf(_format), 'prompt inspect');
  }
}

/// The body-free rendering of a completed inspection or validation report.
String _renderPromptViews(
  PromptNativeViews views,
  LifecycleOutputFormat format,
  String command,
) {
  if (format == LifecycleOutputFormat.json) return jsonEncode(views.toJson());
  final lines = <String>[
    '$command: ${views.path}',
    '  form: ${views.form.name}',
    '  global: ${views.globalCompatibility.name}',
    '  placement: ${views.placement.name}',
  ];
  for (final consumer in PromptConsumer.inspectable) {
    final view = views.views[consumer];
    if (view == null) continue;
    lines.add(
      '  ${consumer.name}: ${view.classification.name}'
      '${view.valid ? '' : ' (invalid)'}'
      '${view.installationSupported ? ' install=supported' : ' install=unsupported'}',
    );
    for (final diagnostic in view.diagnostics) {
      lines.add('    [${diagnostic.code}]: ${diagnostic.message}');
    }
  }
  return lines.join('\n');
}

final class PromptValidateCommand extends Command {
  PromptValidateCommand(this._read)
    : super(
        options: [_path, _target, _format],
        longDescription:
            'Validates one explicit native source against the selected '
            'consuming harness. An invalid or unclassified view fails with '
            'status 2. Without a selected harness every consumer view is '
            'reported and every failing view fails the validation. The '
            'validation is read-only: it never installs, never writes a '
            'management artifact and never discloses an instruction body.',
      );

  final PromptReadService _read;

  static final _path = _promptPath;
  static final _target = _promptTarget;
  static final _format = _promptFormat;

  @override
  String get name => 'validate';

  @override
  String get shortDescription => 'Validate one explicit native Prompt source.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final target = valueOf(_target) as PromptConsumer?;
    _requirePromptTarget(target);
    try {
      final views = await _read.validate(valueOf(_path), consumer: target);
      return _renderPromptViews(views, valueOf(_format), 'prompt validate');
    } on PromptValidationFailure catch (failure) {
      throw MambaException(
        _renderPromptViews(failure.report, valueOf(_format), 'prompt validate'),
        exitCode: 2,
      );
    }
  }
}

final class PromptListCommand extends Command {
  PromptListCommand(
    this._read, {
    this._fileSystem = const local.LocalFileSystem(),
    GuidedAuthoringService? guided,
  }) : _guided = guided ?? GuidedAuthoringService(fileSystem: _fileSystem),
       super(
         options: [
           _scope,
           _target,
           _format,
           _cwd,
           _projectRoot,
           _home,
           _stateDir,
           _claudeConfigDir,
           _codexHome,
           _piAgentDir,
         ],
         longDescription:
             'Read-only inventory of the native Prompt surfaces: the Claude, '
             'Codex, shared and Pi Skill roots and the Pi native template '
             'root. Every occurrence is reported once with its per-consumer '
             'Prompt views and its management state. The inventory creates no '
             'management artifact, enrolls no membership and discloses no '
             'instruction body.',
       );

  final fslib.FileSystem _fileSystem;
  final PromptReadService _read;
  final GuidedAuthoringService _guided;

  static final _scope = ChoiceOption('scope', choices: LifecycleScope.values);
  static final _target = _promptTarget;
  static final _format = _promptFormat;
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _stateDir = FolderPathOption('state-dir');
  static final _claudeConfigDir = FolderPathOption('claude-config-dir');
  static final _codexHome = FolderPathOption('codex-home');
  static final _piAgentDir = FolderPathOption('pi-agent-dir');

  @override
  String get name => 'list';

  @override
  String get shortDescription => 'Inventory the native Prompt surfaces.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final target = valueOf(_target) as PromptConsumer?;
    _requirePromptTarget(target);
    final options = await resolveInteractiveUserScope(
      fileSystem: _fileSystem,
      interactive:
          valueOf(_format) == LifecycleOutputFormat.text && _guided.hasTerminal,
      scopeExplicit: valueOf(_scope) != null,
      offerUserScope: () async =>
          (await _guided.valueQuestion?.call(
            'Project context is unavailable. Type user to inventory user scope:',
          ))?.trim() ==
          'user',
      options: LifecycleOptions(
        processWorkingDirectory: _fileSystem.currentDirectory.path,
        environment: Platform.environment,
        scope: valueOf(_scope) ?? LifecycleScope.project,
        cwd: valueOf(_cwd),
        projectRoot: valueOf(_projectRoot),
        home: valueOf(_home),
        stateDir: valueOf(_stateDir),
        claudeConfigDir: valueOf(_claudeConfigDir),
        codexHome: valueOf(_codexHome),
        piAgentDir: valueOf(_piAgentDir),
      ),
    );
    final inventory = await _read.list(options, consumer: target);
    return switch (valueOf(_format)) {
      LifecycleOutputFormat.json => jsonEncode(inventory.toJson()),
      LifecycleOutputFormat.text => inventory.renderText(),
    };
  }
}
