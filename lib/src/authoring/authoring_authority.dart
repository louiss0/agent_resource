import 'package:file/file.dart' as fslib;
import 'package:mamba/mamba.dart';

import '../services/lifecycle_state_service.dart';

/// The authority of one authoring publication.
///
/// The authority decides which user scope state root the host configures.
/// The publication and the recovery read the same authority: a host that
/// configures no user scope binds no user authority, and a recovery in such
/// a host is refused instead of adopting an unowned location.
interface class AuthoringAuthority {
  /// The authority of a host that derives its user scope from the platform.
  const AuthoringAuthority();

  /// The state root of the user scope that the host configures.
  ///
  /// The host configures the user scope with an explicit state root or with
  /// the platform state root of the host. It is null when the host
  /// configures no user scope: the scope is then never bound and it never
  /// blocks a mutation.
  String? userStateRoot(LifecycleContext context, fslib.FileSystem fileSystem) {
    final explicit = context.options.stateDir;
    if (explicit != null) return context.resolvePath(explicit);
    try {
      final user = LifecycleContext.resolve(
        context.options.copyWith(scope: LifecycleScope.user),
        fileSystem: fileSystem,
      );
      return user.stateRoot();
    } on MambaException {
      return null;
    }
  }
}
