import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import 'resource_catalog.dart';

final class SkillDiscoveryBudget {
  SkillDiscoveryBudget({this.maxEntries = 20000, this.maxDirectories = 2000});

  final int maxEntries;
  final int maxDirectories;
  int entries = 0;
  int directories = 0;
}

/// Discovers a root Skill, direct Skills, and Skills inside one group folder.
/// Discovery never follows source links or descends below a Skill package.
Future<List<SkillOffering>> discoverSkillSource({
  required String root,
  String? relativeRoot,
  bool refuseLinkedEntries = false,
  String subject = 'Skill',
  int budgetExitCode = 3,
  int linkExitCode = 4,
  SkillDiscoveryBudget? budget,
  fslib.FileSystem fileSystem = const local.LocalFileSystem(),
}) async {
  final sourceRoot = relativeRoot ?? '.';
  final offerings = <SkillOffering>[];
  final discoveryBudget = budget ?? SkillDiscoveryBudget();

  Future<List<fslib.FileSystemEntity>> children(
    String directory,
    int depth,
  ) async {
    if (depth > 16 ||
        ++discoveryBudget.directories > discoveryBudget.maxDirectories) {
      throw MambaException(
        '$subject discovery exceeded its depth-16 / 2,000-directory budget.',
        exitCode: budgetExitCode,
      );
    }
    final result = <fslib.FileSystemEntity>[];
    await for (final child
        in fileSystem.directory(directory).list(followLinks: false)) {
      if (++discoveryBudget.entries > discoveryBudget.maxEntries) {
        throw MambaException(
          '$subject discovery exceeded its 20,000-entry budget.',
          exitCode: budgetExitCode,
        );
      }
      result.add(child);
    }
    result.sort((left, right) => left.path.compareTo(right.path));
    return result;
  }

  void checkMarkerLink(String directory, String relative) {
    if (fileSystem.typeSync(
          fileSystem.path.join(directory, 'SKILL.md'),
          followLinks: false,
        ) ==
        FileSystemEntityType.link) {
      throw MambaException(
        '$subject discovery refuses linked source entries: '
        '${p.posix.join(relative, 'SKILL.md')}.',
        exitCode: linkExitCode,
      );
    }
  }

  void addSkill(String directory, String relative, String group) {
    checkMarkerLink(directory, relative);
    if (fileSystem.typeSync(
          fileSystem.path.join(directory, 'SKILL.md'),
          followLinks: false,
        ) !=
        FileSystemEntityType.file) {
      return;
    }
    offerings.add(
      SkillOffering(
        id: relative,
        path: relative,
        label: fileSystem.path.basename(directory),
        discoveryRoot: sourceRoot,
        discoveryGroup: group,
      ),
    );
    if (offerings.length > maxCatalogEntries) {
      throw MambaException(
        '$subject discovery exceeded its 1,000-resource budget.',
        exitCode: budgetExitCode,
      );
    }
  }

  bool ignored(String name) =>
      name.startsWith('.') || const {'node_modules', 'vendor'}.contains(name);

  try {
    checkMarkerLink(root, sourceRoot);
    if (fileSystem.typeSync(
          fileSystem.path.join(root, 'SKILL.md'),
          followLinks: false,
        ) ==
        FileSystemEntityType.file) {
      addSkill(root, sourceRoot, 'root');
      return List<SkillOffering>.unmodifiable(offerings);
    }

    final directChildren = await children(root, 0);
    for (final child in directChildren) {
      final name = fileSystem.path.basename(child.path);
      if (ignored(name)) continue;
      final childType = fileSystem.typeSync(child.path, followLinks: false);
      if (childType == FileSystemEntityType.link) {
        if (refuseLinkedEntries) {
          throw MambaException(
            '$subject discovery refuses linked source entries: '
            '${p.posix.join(sourceRoot, name)}.',
            exitCode: linkExitCode,
          );
        }
        continue;
      }
      if (childType != FileSystemEntityType.directory) continue;
      final childRelative = p.posix.join(sourceRoot, name);
      if (fileSystem.typeSync(
            fileSystem.path.join(child.path, 'SKILL.md'),
            followLinks: false,
          ) ==
          FileSystemEntityType.file) {
        addSkill(child.path, childRelative, 'root');
        continue;
      }
      checkMarkerLink(child.path, childRelative);
      final groupedChildren = await children(child.path, 1);
      for (final grouped in groupedChildren) {
        final groupedName = fileSystem.path.basename(grouped.path);
        if (ignored(groupedName)) continue;
        final groupedType = fileSystem.typeSync(
          grouped.path,
          followLinks: false,
        );
        if (groupedType == FileSystemEntityType.link) {
          if (refuseLinkedEntries) {
            throw MambaException(
              '$subject discovery refuses linked source entries: '
              '${p.posix.join(childRelative, groupedName)}.',
              exitCode: linkExitCode,
            );
          }
          continue;
        }
        if (groupedType != FileSystemEntityType.directory) continue;
        addSkill(grouped.path, p.posix.join(childRelative, groupedName), name);
      }
    }
  } on FileSystemException catch (error) {
    throw MambaException(
      '$subject discovery could not completely read the selected source: '
      '${error.message}',
      exitCode: budgetExitCode,
    );
  }

  offerings.sort((left, right) {
    final leftRoot = left.discoveryGroup == 'root';
    final rightRoot = right.discoveryGroup == 'root';
    if (leftRoot != rightRoot) return leftRoot ? -1 : 1;
    var comparison = (left.discoveryGroup ?? '').compareTo(
      right.discoveryGroup ?? '',
    );
    if (comparison != 0) return comparison;
    comparison = (left.discoveryRoot ?? '').compareTo(
      right.discoveryRoot ?? '',
    );
    if (comparison != 0) return comparison;
    comparison = (left.label ?? '').compareTo(right.label ?? '');
    if (comparison != 0) return comparison;
    return left.path.compareTo(right.path);
  });
  return List<SkillOffering>.unmodifiable(offerings);
}
