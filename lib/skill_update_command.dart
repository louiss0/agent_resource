import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'src/services/lifecycle_state_service.dart';
import 'src/services/skill_lifecycle_service.dart';

/// Replays the recorded direct Skill installation route.
final class SkillUpdateCommand extends Command {
  SkillUpdateCommand(this._service)
    : super(
        mandatoryPositionals: [_id],
        options: [
          _scope,
          _cwd,
          _projectRoot,
          _home,
          _state,
          _claude,
          _codex,
          _gemini,
          _format,
        ],
        flags: [_dryRun, _yes],
      );

  final SkillLifecycleService _service;
  static final _id = NormalPositional('installation-id');
  static final _scope = ChoiceOption('scope', choices: LifecycleScope.values);
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _state = FolderPathOption('state-dir');
  static final _claude = FolderPathOption('claude-config-dir');
  static final _codex = FolderPathOption('codex-home');
  static final _gemini = FolderPathOption('gemini-dir');
  static final _format = StringOption.withDefault(
    'format',
    defaultValue: 'text',
  );
  static const _dryRun = BooleanFlag('dry-run');
  static const _yes = BooleanFlag('yes');

  @override
  String get name => 'update';
  @override
  String get shortDescription =>
      'Update a direct Skill from its recorded route.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final scope = valueOf(_scope);
    if (scope == null || scope == LifecycleScope.all) {
      throw MambaException('Skill update requires --scope project or user.');
    }
    final format = valueOf(_format);
    if (format != 'text' && format != 'json') {
      throw MambaException('Format must be text or json.');
    }
    final result = await _service.update(
      LifecycleIdInput(
        id: valueOf(_id),
        options: LifecycleOptions(
          processWorkingDirectory: _service.state.io.fs.currentDirectory.path,
          environment: Platform.environment,
          scope: scope,
          cwd: valueOf(_cwd),
          projectRoot: valueOf(_projectRoot),
          home: valueOf(_home),
          stateDir: valueOf(_state),
          claudeConfigDir: valueOf(_claude),
          codexHome: valueOf(_codex),
          geminiDir: valueOf(_gemini),
          dryRun: valueOf(_dryRun),
          approved: valueOf(_yes),
        ),
      ),
    );
    return format == 'json'
        ? jsonEncode(result.envelope())
        : result.renderText();
  }
}
