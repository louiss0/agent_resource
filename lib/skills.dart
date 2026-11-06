import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'pack_action.dart';
import 'source.dart';
import 'src/services/pack_lifecycle_service.dart';

final class SkillsCommand extends GroupCommand {
  new({
    PackLifecycleService? service,
    void Function(String)? warning,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : this._(
         service ?? PackLifecycleService(fileSystem: fileSystem),
         warning,
         fileSystem,
       );

  SkillsCommand._(
    PackLifecycleService service,
    void Function(String)? warning,
    fslib.FileSystem fileSystem,
  ) : super([
        ...packLifecycleCommands(
          PackResourceType.skill,
          service,
          warning: warning,
          fileSystem: fileSystem,
        ),
        PackSourceCommand(
          PackResourceType.skill,
          service,
          warning: warning,
          fileSystem: fileSystem,
        ),
      ]);

  @override
  String get name => 'skills';

  @override
  String get shortDescription => 'Deprecated: use pack --type skill.';
}
