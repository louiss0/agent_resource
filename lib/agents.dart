import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'pack_action.dart';
import 'source.dart';
import 'src/services/pack_lifecycle_service.dart';

final class AgentsCommand extends GroupCommand {
  new({
    PackLifecycleService? service,
    void Function(String)? warning,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : this._(
         service ?? PackLifecycleService(fileSystem: fileSystem),
         warning,
         fileSystem,
       );

  AgentsCommand._(
    PackLifecycleService service,
    void Function(String)? warning,
    fslib.FileSystem fileSystem,
  ) : super([
        ...packLifecycleCommands(
          PackResourceType.agent,
          service,
          warning: warning,
          fileSystem: fileSystem,
        ),
        PackSourceCommand(
          PackResourceType.agent,
          service,
          warning: warning,
          fileSystem: fileSystem,
        ),
      ]);

  @override
  String get name => 'agents';

  @override
  String get shortDescription => 'Deprecated: use pack --type agent.';
}
