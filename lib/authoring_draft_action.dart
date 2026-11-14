import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/authoring/instruction_draft.dart';
import 'src/services/instruction_draft_service.dart';
import 'src/services/lifecycle_state_service.dart';

enum AuthoringDraftAction { list, inspect, resume, discard }

/// Draft recovery never publishes or reuses an earlier publication approval.
final class AuthoringDraftActionCommand extends Command {
  AuthoringDraftActionCommand(
    this._drafts,
    this._action, {
    fslib.FileSystem? fileSystem,
  }) : _fileSystem = fileSystem ?? const local.LocalFileSystem(),
       super(
         mandatoryPositionals: [if (_action != AuthoringDraftAction.list) _id],
         options: [_scope, _format, _cwd, _projectRoot, _home, _stateDir],
         flags: [
           if (_action == AuthoringDraftAction.discard) ...[
             _apply,
             _yes,
             _dryRun,
           ],
         ],
         conflicts: {
           if (_action == AuthoringDraftAction.discard)
             'apply': const ['dry-run'],
         },
         longDescription:
             'Drafts are protected instruction text, not published resources or '
             'transaction recovery payloads. List/inspect and resume are '
             'read-only. Resume rebuilds a fresh plan against current source, '
             'destination and ownership observations; it never reuses consent '
             'or publishes. No instruction body is printed. Discard previews '
             'by default and requires --apply --yes to remove only a verified '
             'application-owned draft. Original body files are never removed. '
             'There is no automatic expiry or secure-erasure claim.',
       );

  final InstructionDraftService _drafts;
  final AuthoringDraftAction _action;
  final fslib.FileSystem _fileSystem;

  static final _id = NormalPositional('draft-id');
  static final _scope = ChoiceOption.withDefault(
    'scope',
    choices: const [LifecycleScope.project, LifecycleScope.user],
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
  static const _apply = BooleanFlag('apply');
  static const _yes = BooleanFlag('yes');
  static const _dryRun = BooleanFlag('dry-run');

  @override
  String get name => _action.name;

  @override
  String get shortDescription => switch (_action) {
    AuthoringDraftAction.list =>
      'Find retained drafts without instruction text.',
    AuthoringDraftAction.inspect => 'Inspect retained draft metadata.',
    AuthoringDraftAction.resume =>
      'Build a fresh read-only plan from a retained draft.',
    AuthoringDraftAction.discard =>
      'Review or explicitly discard one verified owned draft.',
  };

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final discarding = _action == AuthoringDraftAction.discard;
    final apply = discarding && valueOf(_apply);
    if (apply && !valueOf(_yes)) {
      throw MambaException(
        'Draft discard requires --apply --yes.',
        exitCode: 4,
      );
    }
    final options = LifecycleOptions(
      processWorkingDirectory: _fileSystem.currentDirectory.path,
      environment: Platform.environment,
      cwd: valueOf(_cwd),
      projectRoot: valueOf(_projectRoot),
      home: valueOf(_home),
      stateDir: valueOf(_stateDir),
      scope: valueOf(_scope),
      dryRun: !apply,
      approved: apply,
    );
    final Map<String, Object?> data;
    switch (_action) {
      case AuthoringDraftAction.list:
        final entries = await _drafts.list(options);
        data = {
          'drafts': [for (final entry in entries) _summary(entry)],
          'count': entries.length,
        };
      case AuthoringDraftAction.inspect:
        data = _metadata(await _drafts.inspect(options, valueOf(_id)));
      case AuthoringDraftAction.resume:
        final resumed = await _drafts.resume(options, valueOf(_id));
        data = {
          ..._metadata(resumed.draft),
          'plan': {
            'operation': resumed.plan.operation.name,
            'kind': resumed.plan.kind.name,
            'profile': resumed.plan.profile.name,
            'ownership': resumed.plan.ownership.name,
            'output': resumed.plan.output,
            'candidate': {
              'sha256': sha256
                  .convert(utf8.encode(resumed.plan.candidate ?? ''))
                  .toString(),
              'byteLength': utf8.encode(resumed.plan.candidate ?? '').length,
            },
            'body': {
              'sha256': resumed.body.sha256,
              'byteLength': resumed.body.byteLength,
              'edited': resumed.body.edited,
            },
          },
          'planId': resumed.plan.planId,
          'ready': resumed.plan.ready,
          'diagnostics': resumed.plan.diagnostics,
          'publicationApprovalRequired': true,
          'published': false,
        };
      case AuthoringDraftAction.discard:
        if (!apply) {
          data = {
            ..._metadata(await _drafts.inspect(options, valueOf(_id))),
            'applyRequired': true,
            'cleaned': false,
          };
        } else {
          final result = await _drafts.discard(options, valueOf(_id));
          if (!result.cleaned) {
            throw MambaException(
              'Draft retained: ${result.draftId}. ${result.reason ?? 'Cleanup failed.'}',
              exitCode: 6,
            );
          }
          data = {'draftId': result.draftId, 'cleaned': true};
        }
    }
    final result = LifecycleResult(
      command: 'authoring draft ${_action.name}',
      outcome: discarding && apply ? 'discarded' : 'reviewed',
      data: data,
    );
    return valueOf(_format) == LifecycleOutputFormat.json
        ? jsonEncode(result.envelope())
        : result.renderText();
  }

  Map<String, Object?> _metadata(InstructionDraft draft) => {
    'draftId': draft.draftId,
    'path': draft.path,
    'operation': draft.intent.operation.name,
    'kind': draft.intent.kind.name,
    'profile': draft.intent.profile.name,
    'scope': draft.intent.scope.name,
    'bodyOrigin': draft.bodyOrigin.name,
    'bodyByteLength': draft.bodyByteLength,
    'bodySha256': draft.bodySha256,
    'hasWorkingCopy': draft.hasWorkingCopy,
    'createdAt': draft.createdAt,
    'retained': true,
  };

  Map<String, Object?> _summary(InstructionDraftSummary draft) => {
    'draftId': draft.draftId,
    'operation': draft.operation,
    'kind': draft.kind,
    'profile': draft.profile,
    'scope': draft.scope,
    'bodyOrigin': draft.bodyOrigin?.name,
    'bodyByteLength': draft.bodyByteLength,
    'bodySha256': draft.bodySha256,
    'resolved': draft.resolved,
    'hasWorkingCopy': draft.hasWorkingCopy,
    if (draft.reason != null) 'reason': draft.reason,
  };
}
