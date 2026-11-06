import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'pack_action.dart';
import 'source.dart';
import 'src/services/pack_lifecycle_service.dart';

final class PackCommand extends GroupCommand {
  new({
    PackLifecycleService? service,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : this._(
         service ?? PackLifecycleService(fileSystem: fileSystem),
         fileSystem,
       );

  PackCommand._(PackLifecycleService service, fslib.FileSystem fileSystem)
    : super([
        ...packLifecycleCommands(
          PackResourceType.skill,
          service,
          canonical: true,
          fileSystem: fileSystem,
        ),
        PackSourceCommand(
          PackResourceType.skill,
          service,
          canonical: true,
          fileSystem: fileSystem,
        ),
      ]);

  @override
  String get name => 'pack';

  @override
  String get shortDescription =>
      'Manage configured packs of skills and agents.';
}
