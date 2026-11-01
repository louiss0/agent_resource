import 'package:mamba/mamba.dart';

import 'pack_action.dart';
import 'src/services/pack_lifecycle_service.dart';

final class PackSourceCommand extends GroupCommand {
  new(
    PackResourceType resourceType,
    PackLifecycleService service, {
    bool canonical = false,
    void Function(String)? warning,
  }) : super([
         PackActionCommand(
           resourceType,
           PackOperation.sourceAssociate,
           service,
           canonical: canonical,
           warning: warning,
         ),
         PackActionCommand(
           resourceType,
           PackOperation.sourceChange,
           service,
           canonical: canonical,
           warning: warning,
         ),
       ]);

  @override
  String get name => 'source';

  @override
  String get shortDescription =>
      'Review Resource origin association or change.';
}
