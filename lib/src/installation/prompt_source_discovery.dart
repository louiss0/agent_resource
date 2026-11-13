import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

/// The bounded budget of one Prompt source discovery.
final class PromptDiscoveryBudget {
  PromptDiscoveryBudget({this.maxEntries = 20000, this.maxDirectories = 2000});

  final int maxEntries;
  final int maxDirectories;
  int entries = 0;
  int directories = 0;
}

/// One discovered Prompt source of a pack.
final class PromptSourceOffering {
  const PromptSourceOffering({
    required this.id,
    required this.path,
    required this.label,
    required this.template,
    this.discoveryRoot,
    this.discoveryGroup,
  });

  /// The source-relative identity of the source.
  final String id;

  /// The source-relative path of the source.
  final String path;

  /// The native label of the source.
  final String label;

  /// Whether the source is a standalone native template.
  final bool template;

  /// The discovery root the source was found under.
  final String? discoveryRoot;

  /// The discovery group the source was found in.
  final String? discoveryGroup;
}

/// Discovers a root Prompt, direct Prompts, and Prompts inside one group.
///
/// A skill-backed Prompt is a directory with a SKILL.md marker. A standalone
/// template is a Markdown file. Discovery never follows source links and never
/// descends below a Prompt package.
Future<List<PromptSourceOffering>> discoverPromptSource({
  required String root,
  String? relativeRoot,
  bool refuseLinkedEntries = false,
  String subject = 'Prompt',
  int budgetExitCode = 3,
  int linkExitCode = 4,
  PromptDiscoveryBudget? budget,
  fslib.FileSystem fileSystem = const local.LocalFileSystem(),
}) async {
  final sourceRoot = relativeRoot ?? '.';
  final offerings = <PromptSourceOffering>[];
  final discoveryBudget = budget ?? PromptDiscoveryBudget();

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

  void addPackage(String directory, String relative, String group) {
    final marker = fileSystem.path.join(directory, 'SKILL.md');
    if (fileSystem.typeSync(marker, followLinks: false) ==
        FileSystemEntityType.link) {
      throw MambaException(
        '$subject discovery refuses linked source entries: '
        '${p.posix.join(relative, 'SKILL.md')}.',
        exitCode: linkExitCode,
      );
    }
    if (fileSystem.typeSync(marker, followLinks: false) !=
        FileSystemEntityType.file) {
      return;
    }
    offerings.add(
      PromptSourceOffering(
        id: relative,
        path: relative,
        label: fileSystem.path.basename(directory),
        template: false,
        discoveryRoot: sourceRoot,
        discoveryGroup: group,
      ),
    );
    if (offerings.length > 1000) {
      throw MambaException(
        '$subject discovery exceeded its 1,000-resource budget.',
        exitCode: budgetExitCode,
      );
    }
  }

  void addTemplate(String file, String relative, String group) {
    if (fileSystem.path.extension(file).toLowerCase() != '.md') return;
    offerings.add(
      PromptSourceOffering(
        id: relative,
        path: relative,
        label: fileSystem.path.basename(file),
        template: true,
        discoveryRoot: sourceRoot,
        discoveryGroup: group,
      ),
    );
    if (offerings.length > 1000) {
      throw MambaException(
        '$subject discovery exceeded its 1,000-resource budget.',
        exitCode: budgetExitCode,
      );
    }
  }

  bool ignored(String name) =>
      name.startsWith('.') || const {'node_modules', 'vendor'}.contains(name);

  try {
    if (fileSystem.typeSync(
          fileSystem.path.join(root, 'SKILL.md'),
          followLinks: false,
        ) ==
        FileSystemEntityType.file) {
      addPackage(root, sourceRoot, 'root');
      return List<PromptSourceOffering>.unmodifiable(offerings);
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
      final childRelative = p.posix.join(sourceRoot, name);
      if (childType == FileSystemEntityType.directory) {
        if (fileSystem.typeSync(
              fileSystem.path.join(child.path, 'SKILL.md'),
              followLinks: false,
            ) ==
            FileSystemEntityType.file) {
          addPackage(child.path, childRelative, 'root');
          continue;
        }
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
          final groupedRelative = p.posix.join(childRelative, groupedName);
          if (groupedType == FileSystemEntityType.directory) {
            addPackage(grouped.path, groupedRelative, name);
          } else if (groupedType == FileSystemEntityType.file) {
            addTemplate(grouped.path, groupedRelative, name);
          }
        }
        continue;
      }
      if (childType == FileSystemEntityType.file) {
        addTemplate(child.path, childRelative, 'root');
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
    comparison = left.label.compareTo(right.label);
    if (comparison != 0) return comparison;
    return left.path.compareTo(right.path);
  });
  return List<PromptSourceOffering>.unmodifiable(offerings);
}
