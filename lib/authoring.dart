import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'authoring_action.dart';
import 'authoring_draft.dart';
import 'src/services/authoring_recovery_service.dart';
import 'src/services/instruction_draft_service.dart';

final class AuthoringCommand extends GroupCommand {
  AuthoringCommand(
    AuthoringRecoveryService recovery, {
    InstructionDraftService? drafts,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : super([
         for (final action in AuthoringAction.values)
           AuthoringActionCommand(recovery, action),
         AuthoringDraftCommand(
           drafts ?? InstructionDraftService(fileSystem: fileSystem),
           fileSystem: fileSystem,
         ),
       ]);

  @override
  String get name => 'authoring';

  @override
  String get shortDescription =>
      'Inspect authoring transactions and manage retained instruction drafts.';
}
