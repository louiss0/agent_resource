import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'context_read_commands.dart';
import 'src/services/context_template_service.dart';
import 'context_authoring_commands.dart';
import 'src/services/context_template_authoring_service.dart';

/// The singular `context` group for reusable templates and injection.
final class ContextCommand extends GroupCommand {
  ContextCommand({
    ContextTemplateService? contextTemplates,
    ContextTemplateAuthoringService? contextAuthoring,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : super(_children(contextTemplates, contextAuthoring, fileSystem));

  static List<Command> _children(
    ContextTemplateService? contextTemplates,
    ContextTemplateAuthoringService? contextAuthoring,
    fslib.FileSystem fileSystem,
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
    ];
  }

  @override
  String get name => 'context';

  @override
  String get shortDescription =>
      'Manage reusable context templates and inject context files.';
}
