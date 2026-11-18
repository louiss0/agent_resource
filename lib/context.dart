import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'context_inject.dart';
import 'context_read_commands.dart';
import 'src/services/context_injection_service.dart';
import 'src/services/context_template_service.dart';
import 'context_authoring_commands.dart';
import 'src/services/context_template_authoring_service.dart';
import 'context_delete_command.dart';
import 'components/installation_approval.dart';

/// The singular `context` group for reusable templates and injection.
final class ContextCommand extends GroupCommand {
  ContextCommand({
    ContextTemplateService? contextTemplates,
    ContextInjectionService? contextInjection,
    ContextInjectCommand? inject,
    ContextTemplateAuthoringService? contextAuthoring,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    InstallationApprovalComponent? deleteApproval,
  }) : super(
         _children(
           contextTemplates,
           contextInjection,
           inject,
           contextAuthoring,
           fileSystem,
           deleteApproval,
         ),
       );

  static List<Command> _children(
    ContextTemplateService? contextTemplates,
    ContextInjectionService? contextInjection,
    ContextInjectCommand? inject,
    ContextTemplateAuthoringService? contextAuthoring,
    fslib.FileSystem fileSystem,
    InstallationApprovalComponent? deleteApproval,
  ) {
    final service =
        contextTemplates ?? ContextTemplateService(fileSystem: fileSystem);
    final authoring =
        contextAuthoring ??
        ContextTemplateAuthoringService(
          fileSystem: fileSystem,
          templates: service,
        );
    return <Command>[
      ContextListCommand(service),
      ContextInspectCommand(service),
      ContextCreateCommand(authoring),
      ContextEditCommand(authoring),
      ContextDeleteCommand(service, approval: deleteApproval),
      inject ??
          ContextInjectCommand(
            contextInjection ?? ContextInjectionService(fileSystem: fileSystem),
            service,
          ),
    ];
  }

  @override
  String get name => 'context';

  @override
  String get shortDescription =>
      'Manage reusable context templates and inject context files.';
}
