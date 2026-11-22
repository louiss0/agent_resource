import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Shared route transaction layout. It is not a source of native authority.
final class RouteRecoveryPaths {
  const RouteRecoveryPaths(this.paths);

  final p.Context paths;

  ({String staged, String quarantine}) forLocation(
    String nativeRoot,
    String location,
    String transactionId,
  ) {
    if (!RegExp(r'^trx_[a-f0-9]{32}$').hasMatch(transactionId) ||
        !paths.isAbsolute(nativeRoot) ||
        paths.normalize(nativeRoot) != nativeRoot ||
        !paths.isAbsolute(location) ||
        paths.normalize(location) != location ||
        !paths.isWithin(nativeRoot, location)) {
      throw const FormatException('Invalid route transaction path identity.');
    }
    final name =
        '${sha256.convert(utf8.encode(location)).toString().substring(0, 16)}-${paths.basename(location)}';
    final root = paths.join(paths.dirname(nativeRoot), '.agent-resource');
    return (
      staged: paths.join(root, 'staging', transactionId, name),
      quarantine: paths.join(root, 'quarantine', transactionId, name),
    );
  }
}
