import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

/// Returns a link-aware filesystem type, refusing to treat an ambiguous
/// `notFound` result as proof that a path is absent.
///
/// Dart's [FileSystemEntity.typeSync] reports [FileSystemEntityType.notFound]
/// for lookup failures as well as for missing paths. When that happens, the
/// containing directories are checked by non-recursive listings. A listed
/// entry that still cannot be classified is an operational failure, not an
/// absent entry.
FileSystemEntityType skillEntityType(String path, {required bool followLinks}) {
  final normalizedPath = _absoluteNormalized(path);
  final observed = _rawEntityType(normalizedPath, followLinks: followLinks);
  if (observed != FileSystemEntityType.notFound) {
    return observed;
  }
  return _confirmAbsence(normalizedPath, followLinks: followLinks);
}

/// Reads at most [maxBytes] + 1 bytes from a marker and always closes it.
///
/// The extra byte lets callers distinguish an exact-size file from an
/// oversized one without an unbounded read. Decode and size diagnostics remain
/// the responsibility of the caller so inspect and validation retain their
/// distinct semantics.
List<int> readBoundedSkillMarker(String path, {required int maxBytes}) {
  RandomAccessFile? file;
  List<int>? bytes;
  try {
    file = File(path).openSync();
    bytes = file.readSync(maxBytes + 1);
  } on FileSystemException catch (error) {
    throw MambaException('Could not read skill marker $path: ${error.message}');
  } finally {
    if (file != null) {
      try {
        file.closeSync();
      } on FileSystemException catch (error) {
        throw MambaException(
          'Could not close skill marker $path: ${error.message}',
        );
      }
    }
  }
  return bytes;
}

List<FileSystemEntity> listSkillDirectory(String path) {
  try {
    return Directory(path).listSync(followLinks: false);
  } on FileSystemException catch (error) {
    throw MambaException(
      'Could not read skills directory $path: ${error.message}',
    );
  }
}

FileSystemEntityType _confirmAbsence(String path, {required bool followLinks}) {
  final parent = p.dirname(path);
  if (p.equals(parent, path)) {
    throw MambaException(
      'Could not confirm whether filesystem path $path exists: '
      'its parent could not be inspected.',
    );
  }

  // Ancestors are resolved as the original lookup would resolve them. The
  // requested final entry still uses its caller-selected followLinks policy.
  final parentType = _rawEntityType(parent, followLinks: true);
  if (parentType == FileSystemEntityType.notFound) {
    // A missing ancestor is absence only after its own parent listing proves
    // that the ancestor name is not present. An inaccessible ancestor is
    // surfaced by the same recursion when it is listed but unclassifiable.
    _confirmAbsence(parent, followLinks: true);
    return FileSystemEntityType.notFound;
  }

  if (parentType != FileSystemEntityType.directory) {
    // A non-directory parent cannot contain the requested final entry.
    return FileSystemEntityType.notFound;
  }

  final entries = _listForAbsenceConfirmation(parent);
  for (final entry in entries) {
    if (!_samePath(entry.path, path)) {
      continue;
    }

    final listedType = _rawEntityType(path, followLinks: followLinks);
    if (listedType == FileSystemEntityType.notFound) {
      throw MambaException(
        'Could not classify filesystem path $path after it was listed; '
        'the lookup may be inaccessible or unstable.',
      );
    }
    return listedType;
  }

  return FileSystemEntityType.notFound;
}

List<FileSystemEntity> _listForAbsenceConfirmation(String parent) {
  try {
    // No recursion: this listing establishes only whether the immediate name
    // is present and does not traverse linked descendants.
    return Directory(parent).listSync(followLinks: false);
  } on FileSystemException catch (error) {
    throw MambaException(
      'Could not inspect parent directory $parent: ${error.message}',
    );
  }
}

FileSystemEntityType _rawEntityType(String path, {required bool followLinks}) {
  try {
    return FileSystemEntity.typeSync(path, followLinks: followLinks);
  } on FileSystemException catch (error) {
    throw MambaException(
      'Could not inspect filesystem path $path: ${error.message}',
    );
  }
}

String _absoluteNormalized(String path) => p.normalize(p.absolute(path));

bool _samePath(String left, String right) =>
    p.equals(_absoluteNormalized(left), _absoluteNormalized(right));

/// The lexical components below the common ancestor of [base] and [path].
/// The explicit base itself is trusted (as for an explicit working directory),
/// but derived descendants, including intermediate directories, are not.
Iterable<String> skillPathComponents(
  String path, {
  required String base,
}) sync* {
  final target = _absoluteNormalized(path);
  var common = _absoluteNormalized(base);
  while (!p.equals(common, target) && !p.isWithin(common, target)) {
    final parent = p.dirname(common);
    if (p.equals(parent, common)) break;
    common = parent;
  }
  var current = common;
  final relative = p.relative(target, from: common);
  if (relative == '.') return;
  for (final part in p.split(relative)) {
    current = p.join(current, part);
    yield current;
  }
}

/// The fail-closed observation contract of [skillEntityType], with streaming
/// parent checks that retain no directory entries. These checks establish
/// absence only; they do not enumerate native inventory candidates.
Future<FileSystemEntityType> skillEntityTypeAsync(
  String path, {
  required bool followLinks,
}) async {
  final normalized = _absoluteNormalized(path);
  final observed = _rawEntityType(normalized, followLinks: followLinks);
  if (observed != FileSystemEntityType.notFound) return observed;

  Future<FileSystemEntityType> confirm(String path, bool follow) async {
    final parent = p.dirname(path);
    if (p.equals(parent, path)) {
      throw MambaException(
        'Could not confirm whether filesystem path $path exists: '
        'its parent could not be inspected.',
      );
    }
    final parentType = _rawEntityType(parent, followLinks: true);
    if (parentType == FileSystemEntityType.notFound) {
      await confirm(parent, true);
      return FileSystemEntityType.notFound;
    }
    if (parentType != FileSystemEntityType.directory) {
      return FileSystemEntityType.notFound;
    }
    await for (final entry in Directory(parent).list(followLinks: false)) {
      if (!_samePath(entry.path, path)) continue;
      final type = _rawEntityType(path, followLinks: follow);
      if (type == FileSystemEntityType.notFound) {
        throw MambaException(
          'Could not classify filesystem path $path after it was listed; '
          'the lookup may be inaccessible or unstable.',
        );
      }
      return type;
    }
    return FileSystemEntityType.notFound;
  }

  try {
    return await confirm(normalized, followLinks);
  } on FileSystemException catch (error) {
    throw MambaException(
      'Could not inspect parent directory of $path: ${error.message}',
    );
  }
}
