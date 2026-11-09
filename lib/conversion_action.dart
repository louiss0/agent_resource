import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/services/conversion_coordinator_service.dart';
import 'src/services/lifecycle_state_service.dart';

enum ConversionAction { list, inspect, recover, cleanup }

/// Recovery never accepts a caller-selected rollback/complete override.
final class ConversionActionCommand extends Command {
  ConversionActionCommand(this._coordinator, this._action)
    : super(
        mandatoryPositionals: [if (_action != ConversionAction.list) _id],
        options: [
          _scope,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _stateDir,
          if (_action == ConversionAction.recover ||
              _action == ConversionAction.cleanup)
            _plan,
        ],
        flags: [
          if (_action == ConversionAction.recover ||
              _action == ConversionAction.cleanup) ...[
            _apply,
            _yes,
            _dryRun,
          ],
        ],
        conflicts: {
          if (_action == ConversionAction.recover ||
              _action == ConversionAction.cleanup)
            'apply': const ['dry-run'],
        },
        longDescription:
            'Offline transaction evidence only; no harness execution. '
            'Inspection and default recovery/cleanup planning write nothing. '
            'Apply requires --apply --yes --plan-id from a fresh review. '
            'Recovery direction is fixed by the protected commit decision. '
            'Completed inverse restore and new public conversion apply remain gated. '
            'Cleanup removes only verified terminal private payloads, retaining '
            'the audit receipt; it forfeits payload-based restore and is not secure erasure.',
      );

  final ConversionCoordinator _coordinator;
  final ConversionAction _action;
  static final _id = NormalPositional('transaction-id');
  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: LifecycleScope.values,
    defaultValue: LifecycleScope.project,
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _stateDir = FolderPathOption('state-dir');
  static final _plan = StringOption(
    'plan-id',
    description: 'Exact fresh recovery/cleanup plan identity.',
  );
  static const _apply = BooleanFlag('apply');
  static const _yes = BooleanFlag('yes');
  static const _dryRun = BooleanFlag('dry-run');

  @override
  String get name => _action.name;

  @override
  String get shortDescription => switch (_action) {
    ConversionAction.list =>
      'List retained transactions, including unresolved evidence.',
    ConversionAction.inspect =>
      'Inspect current evidence and decision-bound recovery.',
    ConversionAction.recover =>
      'Review or apply interruption recovery, not inverse restore.',
    ConversionAction.cleanup =>
      'Review or delete verified terminal private payloads.',
  };

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final mutator =
        _action == ConversionAction.recover ||
        _action == ConversionAction.cleanup;
    final apply = mutator && valueOf(_apply);
    final options = LifecycleOptions(
      processWorkingDirectory: _coordinator.state.io.fs.currentDirectory.path,
      environment: Map<String, String>.unmodifiable(Platform.environment),
      scope: valueOf(_scope),
      cwd: valueOf(_cwd),
      projectRoot: valueOf(_projectRoot),
      home: valueOf(_home),
      stateDir: valueOf(_stateDir),
      approved: mutator && valueOf(_yes),
      dryRun: !apply,
    );
    final result = switch (_action) {
      ConversionAction.list => await _coordinator.inventory(options),
      ConversionAction.inspect => await _coordinator.inspectRecovery(
        options,
        valueOf(_id),
      ),
      ConversionAction.recover => await _coordinator.recoverReviewed(
        options,
        valueOf(_id),
        planId: valueOf(_plan),
      ),
      ConversionAction.cleanup => await _coordinator.cleanupReviewed(
        options,
        valueOf(_id),
        planId: valueOf(_plan),
      ),
    };
    return valueOf(_format) == LifecycleOutputFormat.json
        ? jsonEncode(result.envelope())
        : result.renderText();
  }
}
