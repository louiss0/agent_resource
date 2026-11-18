import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'context_inject.dart';
import 'context_read_commands.dart';
import 'src/services/context_injection_service.dart';
import 'src/services/context_template_service.dart';

/// The singular `context` group for reusable templates and injection.
final class ContextCommand extends GroupCommand {
  ContextCommand({
    ContextTemplateService? contextTemplates,
    ContextInjectionService? contextInjection,
    ContextInjectCommand? inject,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : super(_children(contextTemplates, contextInjection, inject, fileSystem));

  static List<Command> _children(
    ContextTemplateService? contextTemplates,
    ContextInjectionService? contextInjection,
    ContextInjectCommand? inject,
    fslib.FileSystem fileSystem,
  ) {
    final service =
        contextTemplates ?? ContextTemplateService(fileSystem: fileSystem);
    return <Command>[
      ContextListCommand(service),
      ContextInspectCommand(service),
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
