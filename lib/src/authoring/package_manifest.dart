import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:mamba/mamba.dart';

import '../skill_files.dart';

/// The largest number of entries of a reviewed package manifest.
const int maxPackageManifestEntries = 256;

/// The largest nesting depth of a reviewed package manifest.
const int maxPackageManifestDepth = 8;

/// The largest ordinary file of a reviewed package manifest.
const int maxPackageManifestFileBytes = 1048576;

/// The reviewed manifest of one native package directory.
///
/// The manifest binds every owned member of the package by relative path,
/// type, length and content digest. It is the evidence that a clone copies
/// exactly the reviewed members, that an edit replaces exactly the reviewed
/// source and that a publication never copies an unowned entry.
final class PackageManifest {
  const PackageManifest(this.entries);

  /// The manifest of a package without reviewed members.
  static const PackageManifest empty = PackageManifest(
    <Map<String, Object?>>[],
  );

  /// The manifest entries, ordered by relative path.
  final List<Map<String, Object?>> entries;

  /// The digest that binds the manifest entries.
  String get digest =>
      sha256.convert(utf8.encode(jsonEncode(entries))).toString();
}

/// Reads the bounded manifest of one package directory.
///
/// The traversal never follows a link and refuses an unsupported entry. The
/// limits are part of the contract: an exhausted budget refuses the review
/// instead of publishing an unreviewed package.
PackageManifest readPackageManifest(
  fslib.FileSystem fs,
  String directory, {
  int maxEntries = maxPackageManifestEntries,
  int maxDepth = maxPackageManifestDepth,
  int maxFileBytes = maxPackageManifestFileBytes,
}) {
  final entries = <Map<String, Object?>>[];
  void walk(String current, String prefix, int depth) {
    if (depth > maxDepth) {
      throw MambaException(
        'The source package exceeds the manifest depth limit.',
        exitCode: 3,
      );
    }
    for (final child in listSkillDirectory(current, fs: fs)) {
      if (entries.length >= maxEntries) {
        throw MambaException(
          'The source package exceeds the manifest entry limit.',
          exitCode: 3,
        );
      }
      final name = fs.path.basename(child.path);
      final relative = prefix.isEmpty ? name : '$prefix/$name';
      final type = skillEntityType(child.path, followLinks: false, fs: fs);
      if (type == FileSystemEntityType.directory) {
        entries.add(<String, Object?>{
          'path': relative,
          'type': 'directory',
          'length': 0,
          'sha256': null,
        });
        walk(child.path, relative, depth + 1);
        continue;
      }
      if (type != FileSystemEntityType.file) {
        throw MambaException(
          'The source package contains an unsupported entry: ${child.path}',
          exitCode: 4,
        );
      }
      final bytes = readBoundedSkillMarker(
        child.path,
        maxBytes: maxFileBytes,
        fs: fs,
      );
      if (bytes.length > maxFileBytes) {
        throw MambaException(
          'The source package member exceeds the $maxFileBytes byte limit: '
          '${child.path}',
          exitCode: 3,
        );
      }
      entries.add(<String, Object?>{
        'path': relative,
        'type': 'file',
        'length': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
      });
    }
  }

  walk(directory, '', 0);
  entries.sort(
    (left, right) => '${left['path']}'.compareTo('${right['path']}'),
  );
  return PackageManifest(List<Map<String, Object?>>.unmodifiable(entries));
}
