import 'dart:convert';
import 'dart:io';

import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/services/authoring_recovery_service.dart';
import 'src/services/lifecycle_state_service.dart';

/// The recovery actions of the authoring transaction authority.
enum AuthoringAction { list, inspect, recover, cleanup }

/// The authoring transaction recovery commands.
///
/// Recovery never accepts a caller-selected direction: the protected
/// transaction document decides whether a transaction may be rolled back or
/// completed.
final class AuthoringActionCommand extends Command {
  AuthoringActionCommand(this._recovery, this._action)
    : super(
        mandatoryPositionals: [if (_action != AuthoringAction.list) _id],
        options: [
          _scope,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _stateDir,
          if (_action == AuthoringAction.recover ||
              _action == AuthoringAction.cleanup)
            _plan,
        ],
        flags: [
          if (_action == AuthoringAction.recover ||
              _action == AuthoringAction.cleanup) ...[
            _apply,
            _yes,
            _dryRun,
          ],
        ],
        conflicts: {
          if (_action == AuthoringAction.recover ||
              _action == AuthoringAction.cleanup)
            'apply': const ['dry-run'],
        },
        longDescription:
            'Offline transaction evidence only; no harness execution. '
            'Inspection and default recovery/cleanup planning write nothing. '
            'Apply requires --apply --yes --plan-id from a fresh review. '
            'The recovery direction is fixed by the protected transaction '
            'document. Completed inverse restore and the public authoring '
            'apply remain gated. '
            'Cleanup removes only the verified terminal private payload, '
            'retaining the audit receipt; it forfeits the payload based '
            'restore and it is not secure erasure.',
      );

  final AuthoringRecoveryService _recovery;
  final AuthoringAction _action;
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
    description: 'Exact fresh recovery/cleanup review identity.',
  );
  static const _apply = BooleanFlag('apply');
  static const _yes = BooleanFlag('yes');
  static const _dryRun = BooleanFlag('dry-run');

  @override
  String get name => _action.name;

  @override
  String get shortDescription => switch (_action) {
    AuthoringAction.list =>
      'List retained authoring transactions, including unresolved evidence.',
    AuthoringAction.inspect =>
      'Inspect current evidence and decision-bound recovery.',
    AuthoringAction.recover =>
      'Review or apply interruption recovery, not inverse restore.',
    AuthoringAction.cleanup =>
      'Review or delete verified terminal private payloads.',
  };

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final mutator =
        _action == AuthoringAction.recover ||
        _action == AuthoringAction.cleanup;
    final apply = mutator && valueOf(_apply);
    final options = LifecycleOptions(
      processWorkingDirectory: _recovery.state.io.fs.currentDirectory.path,
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
      AuthoringAction.list => await _recovery.inventory(options),
      AuthoringAction.inspect => await _recovery.inspect(options, valueOf(_id)),
      AuthoringAction.recover => await _recovery.recoverReviewed(
        options,
        valueOf(_id),
        planId: valueOf(_plan),
      ),
      AuthoringAction.cleanup => await _recovery.cleanupReviewed(
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
