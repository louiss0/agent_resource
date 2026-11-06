import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import 'pack_action.dart';
import 'src/services/pack_lifecycle_service.dart';

final class PackSourceCommand extends GroupCommand {
  new(
    PackResourceType resourceType,
    PackLifecycleService service, {
    bool canonical = false,
    void Function(String)? warning,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : super([
         PackActionCommand(
           resourceType,
           PackOperation.sourceAssociate,
           service,
           canonical: canonical,
           warning: warning,
           fileSystem: fileSystem,
         ),
         PackActionCommand(
           resourceType,
           PackOperation.sourceChange,
           service,
           canonical: canonical,
           warning: warning,
           fileSystem: fileSystem,
         ),
       ]);

  @override
  String get name => 'source';

  @override
  String get shortDescription =>
      'Review Resource origin association or change.';
}
