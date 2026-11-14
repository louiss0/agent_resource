import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'authoring_draft_action.dart';
import 'src/services/instruction_draft_service.dart';

/// Retained instruction editing is distinct from native transaction recovery.
final class AuthoringDraftCommand extends GroupCommand {
  AuthoringDraftCommand(
    InstructionDraftService drafts, {
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : super([
         for (final action in AuthoringDraftAction.values)
           AuthoringDraftActionCommand(drafts, action, fileSystem: fileSystem),
       ]);

  @override
  String get name => 'draft';

  @override
  String get shortDescription =>
      'Find, inspect, resume, or explicitly discard retained instruction drafts.';
}
