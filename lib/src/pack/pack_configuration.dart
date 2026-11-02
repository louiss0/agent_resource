import 'dart:io';

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';
import 'package:zema/zema.dart';

import '../installation/resource_catalog.dart'
    show CatalogResourceType, NativeAgentProfile;
import '../validation/validation_diagnostics.dart';

export '../installation/resource_catalog.dart' show NativeAgentProfile;

const packConfigurationFileName = 'agent-resources.toml';

enum PackConfigurationScope { project, user }

enum SkillInstallMethod { canonical, copy, sourceLink }

enum ReleaseBump { patch, minor, major }

enum ReleaseArtifact { archive, attachment }

final class PackConfigurationIssue {
  const PackConfigurationIssue(
    this.keyPath,
    this.message, [
    this.code = 'invalid_value',
  ]);

  final String keyPath;
  final String message;
  final String code;

  @override
  String toString() => ValidationDiagnostics.format(keyPath, code, message);
}

final class PackConfigurationException extends FormatException {
  PackConfigurationException(this.issues, {this.configPath})
    : super(
        ValidationDiagnostics.flatten(
          issues.map(
            (issue) =>
                (path: issue.keyPath, code: issue.code, message: issue.message),
          ),
        ).join('\n'),
      );

  final List<PackConfigurationIssue> issues;
  final String? configPath;
}

final class CliInstallPreferences {
  const CliInstallPreferences({required this.targets, this.skillMethod});

  final List<String> targets;
  final SkillInstallMethod? skillMethod;
}

final class CliRetentionPreferences {
  const CliRetentionPreferences({required this.snapshotDays});

  final int snapshotDays;
}

final class CliPreferences {
  const CliPreferences({required this.install, required this.retention});

  static const defaults = CliPreferences(
    install: CliInstallPreferences(targets: <String>[]),
    retention: CliRetentionPreferences(snapshotDays: 90),
  );

  final CliInstallPreferences install;
  final CliRetentionPreferences retention;
}

sealed class PackSource {
  const PackSource({this.subpath});

  final String? subpath;
}

final class GitHubPackSource extends PackSource {
  const GitHubPackSource({
    required this.host,
    required this.repository,
    super.subpath,
  });

  final String host;
  final String repository;
}

final class GitPackSource extends PackSource {
  const GitPackSource({required this.url, super.subpath});

  final String url;
}

final class LocalPackSource extends PackSource {
  const LocalPackSource({required this.path, super.subpath});

  /// Absolute and normalized. Relative declarations use the config directory.
  final String path;
}

final class DownloadPackSource extends PackSource {
  const DownloadPackSource({required this.url, super.subpath});

  final String url;
}

sealed class PackTrack {
  const PackTrack();
}

final class BranchTrack extends PackTrack {
  const BranchTrack(this.name);

  final String name;
}

final class TagTrack extends PackTrack {
  const TagTrack(this.name);

  final String name;
}

final class CommitTrack extends PackTrack {
  const CommitTrack(this.commit);

  final String commit;
}

final class ReleaseTrack extends PackTrack {
  const ReleaseTrack({required this.artifact, this.attachment});

  final ReleaseArtifact artifact;
  final String? attachment;
}

final class LocalTrack extends PackTrack {
  const LocalTrack();
}

final class DownloadTrack extends PackTrack {
  const DownloadTrack();
}

final class PackUpdate {
  const PackUpdate({
    required this.track,
    this.bump,
    this.includePrerelease = false,
  });

  final PackTrack track;
  final ReleaseBump? bump;
  final bool includePrerelease;
}

final class PackInstall {
  const PackInstall({required this.targets, this.skillMethod});

  final List<String> targets;
  final SkillInstallMethod? skillMethod;
}

final class ResourceOverride {
  const ResourceOverride({required this.name, required this.extraFolders});

  final String name;
  final List<String> extraFolders;
}

final class PackResourceRules {
  const PackResourceRules({required this.exclusions, required this.overrides});

  static const empty = PackResourceRules(
    exclusions: <String>[],
    overrides: <ResourceOverride>[],
  );

  final List<String> exclusions;
  final List<ResourceOverride> overrides;
}

final class PackResources {
  const PackResources({required this.skills, required this.agents});

  static const empty = PackResources(
    skills: PackResourceRules.empty,
    agents: PackResourceRules.empty,
  );

  final PackResourceRules skills;
  final PackResourceRules agents;
}

final class PackDefinition {
  const PackDefinition({
    required this.key,
    required this.source,
    required this.install,
    required this.update,
    required this.resources,
    this.discovery = PackDiscovery.defaults,
  });

  final String key;
  final PackSource source;
  final PackInstall install;
  final PackUpdate update;
  final PackResources resources;
  final PackDiscovery discovery;
}

final class SkillCatalogEntry {
  const SkillCatalogEntry(this.path);

  final String path;
}

final class AgentCatalogEntry {
  const AgentCatalogEntry({required this.path, required this.profile});

  final String path;
  final NativeAgentProfile profile;
}

final class SourceCatalog {
  const SourceCatalog({
    required this.skills,
    required this.agents,
    this.declared = false,
  });

  static const empty = SourceCatalog(
    skills: <SkillCatalogEntry>[],
    agents: <AgentCatalogEntry>[],
  );

  final List<SkillCatalogEntry> skills;
  final List<AgentCatalogEntry> agents;
  final bool declared;
}

final class PackConfiguration {
  const PackConfiguration._({
    required this.schemaVersion,
    required this.configPath,
    required this.scope,
    required this.cli,
    required this.packs,
    required this.catalog,
  });

  factory PackConfiguration.parse(
    String source, {
    String configPath = packConfigurationFileName,
    PackConfigurationScope scope = PackConfigurationScope.project,
    CatalogResourceType? catalogType,
  }) {
    return _parse(
      source,
      configPath: configPath,
      scope: scope,
      inheritedPreferences: CliPreferences.defaults,
      catalogType: catalogType,
    );
  }

  static PackConfiguration load({
    required PackConfigurationScope scope,
    String? projectRoot,
    String? explicitPath,
    String? workingDirectory,
    Map<String, String>? environment,
    String? operatingSystem,
    FileSystem? fileSystem,
  }) {
    final fs = fileSystem ?? LocalFileSystem();
    final path = fs.path;
    final cwd = workingDirectory ?? fs.currentDirectory.path;
    final configPath = explicitPath == null
        ? switch (scope) {
            PackConfigurationScope.project => path.join(
              _requiredProjectRoot(projectRoot, cwd, path),
              packConfigurationFileName,
            ),
            PackConfigurationScope.user => userConfigPath(
              environment: environment,
              operatingSystem: operatingSystem,
            ),
          }
        : _resolvePath(explicitPath, cwd, path);

    var inherited = CliPreferences.defaults;
    if (scope == PackConfigurationScope.project) {
      final userPath = userConfigPath(
        environment: environment,
        operatingSystem: operatingSystem,
      );
      if (path.equals(userPath, configPath)) {
        throw PackConfigurationException(const [
          PackConfigurationIssue(
            'config',
            'the explicit project config must differ from the user config',
          ),
        ], configPath: configPath);
      }
      if (fs.file(userPath).existsSync()) {
        inherited = _parse(
          _readConfig(fs, userPath),
          configPath: userPath,
          scope: PackConfigurationScope.user,
          inheritedPreferences: CliPreferences.defaults,
          pathContext: path,
        ).cli;
      }
    }

    return _parse(
      _readConfig(fs, configPath),
      configPath: configPath,
      scope: scope,
      inheritedPreferences: inherited,
      pathContext: path,
    );
  }

  static String userConfigPath({
    Map<String, String>? environment,
    String? operatingSystem,
  }) {
    final env = environment ?? Platform.environment;
    final platform = operatingSystem ?? Platform.operatingSystem;
    final pathContext = platform == 'windows' ? p.windows : p.posix;
    final String path;
    if (platform == 'windows') {
      final appData = env['APPDATA'];
      if (appData == null || !pathContext.isAbsolute(appData)) {
        throw PackConfigurationException(const [
          PackConfigurationIssue(
            'APPDATA',
            'must be an absolute path to discover user configuration',
          ),
        ]);
      }
      path = pathContext.join(
        appData,
        'AgentResource',
        packConfigurationFileName,
      );
    } else if (platform == 'macos') {
      path = pathContext.join(
        _absoluteHome(env, pathContext),
        'Library',
        'Application Support',
        'AgentResource',
        packConfigurationFileName,
      );
    } else {
      final xdg = env['XDG_CONFIG_HOME'];
      final base = xdg != null && pathContext.isAbsolute(xdg)
          ? xdg
          : pathContext.join(_absoluteHome(env, pathContext), '.config');
      path = pathContext.join(
        base,
        'agent-resource',
        packConfigurationFileName,
      );
    }
    return pathContext.normalize(path);
  }

  final int schemaVersion;
  final String configPath;
  final PackConfigurationScope scope;
  final CliPreferences cli;
  final List<PackDefinition> packs;
  final SourceCatalog catalog;

  PackDefinition? findPack(String key) {
    final normalized = _normalizePackKey(key);
    for (final pack in packs) {
      if (_normalizePackKey(pack.key) == normalized) return pack;
    }
    return null;
  }

  static String _requiredProjectRoot(
    String? projectRoot,
    String workingDirectory,
    p.Context pathContext,
  ) {
    if (projectRoot == null || projectRoot.trim().isEmpty) {
      throw PackConfigurationException(const [
        PackConfigurationIssue(
          'project_root',
          'is required for project configuration discovery',
        ),
      ]);
    }
    return _resolvePath(projectRoot, workingDirectory, pathContext);
  }

  static String _absoluteHome(
    Map<String, String> environment,
    p.Context pathContext,
  ) {
    final home = environment['HOME'];
    if (home == null || !pathContext.isAbsolute(home)) {
      throw PackConfigurationException(const [
        PackConfigurationIssue(
          'HOME',
          'must be an absolute path to discover user configuration',
        ),
      ]);
    }
    return home;
  }

  static PackConfiguration _parse(
    String source, {
    required String configPath,
    required PackConfigurationScope scope,
    required CliPreferences inheritedPreferences,
    CatalogResourceType? catalogType,
    p.Context? pathContext,
  }) {
    pathContext ??= p.Context();
    final Map<String, dynamic> document;
    try {
      document = TomlDocument.parse(source).toMap();
    } on TomlParserException catch (error) {
      throw PackConfigurationException([
        PackConfigurationIssue(
          'syntax',
          'invalid TOML at ${error.line}:${error.column}',
        ),
      ], configPath: configPath);
    } on TomlRedefinitionException catch (error) {
      throw PackConfigurationException([
        PackConfigurationIssue(
          error.name.toString(),
          'duplicate TOML key or table declaration',
        ),
      ], configPath: configPath);
    } on FormatException {
      throw PackConfigurationException([
        const PackConfigurationIssue('syntax', 'invalid TOML syntax'),
      ], configPath: configPath);
    } on TomlException {
      throw PackConfigurationException(const [
        PackConfigurationIssue('syntax', 'invalid TOML value'),
      ], configPath: configPath);
    }
    final parser = _Parser(configPath, inheritedPreferences, pathContext)
      ..issues.addAll(_shapeIssues(document, catalogType: catalogType));
    return parser.parse(document, scope, catalogType: catalogType);
  }

  static String _readConfig(FileSystem fileSystem, String path) {
    try {
      return fileSystem.file(path).readAsStringSync();
    } on FileSystemException catch (error) {
      throw PackConfigurationException([
        PackConfigurationIssue('file', error.message),
      ], configPath: path);
    } on FormatException {
      throw PackConfigurationException(const [
        PackConfigurationIssue('file', 'configuration must be UTF-8'),
      ], configPath: path);
    }
  }
}

final _stringArray = z.array(z.string()).min(1);
final _sourceSchema = z.union<Map<String, dynamic>>([
  z.object({
    'kind': z.literal('github'),
    'host': z.string().optional(),
    'repository': z.string(),
    'subpath': z.string().optional(),
  }).makeStrict(),
  z.object({
    'kind': z.literal('git'),
    'url': z.string(),
    'subpath': z.string().optional(),
  }).makeStrict(),
  z.object({
    'kind': z.literal('local'),
    'path': z.string(),
    'subpath': z.string().optional(),
  }).makeStrict(),
  z.object({
    'kind': z.literal('download'),
    'url': z.string(),
    'subpath': z.string().optional(),
  }).makeStrict(),
]);
final _trackSchema = z.union<Map<String, dynamic>>([
  z.object({'kind': z.literal('branch'), 'name': z.string()}).makeStrict(),
  z.object({'kind': z.literal('tag'), 'name': z.string()}).makeStrict(),
  z.object({'kind': z.literal('commit'), 'commit': z.string()}).makeStrict(),
  z.object({
    'kind': z.literal('release'),
    'artifact': z.string().oneOf(['archive', 'attachment']),
    'attachment': z.string().optional(),
  }).makeStrict(),
  z.object({'kind': z.literal('local')}).makeStrict(),
  z.object({'kind': z.literal('download')}).makeStrict(),
]);
final _installSchema = z.object({
  'targets': _stringArray.optional(),
  'skill_method': z.string().oneOf([
    'canonical',
    'copy',
    'source-link',
  ]).optional(),
}).makeStrict();
final _updateSchema = z.object({
  'track': _trackSchema.optional(),
  'bump': z.string().oneOf(['patch', 'minor', 'major']).optional(),
  'include_prerelease': z.boolean().optional(),
}).makeStrict();
final _rulesSchema = z.object({
  'exclude': z
      .array(z.object({'name': z.string()}).makeStrict())
      .min(1)
      .optional(),
  'overrides': z
      .array(
        z.object({
          'name': z.string(),
          'extra_folders': _stringArray.optional(),
        }).makeStrict(),
      )
      .min(1)
      .optional(),
}).makeStrict();
final _packSchema = z.object({
  'source': _sourceSchema.optional(),
  'install': _installSchema.optional(),
  'update': _updateSchema.optional(),
  'discovery': z
      .object({
        'skills_directory': z.string().optional(),
        'agents_directory': z.string().optional(),
      })
      .makeStrict()
      .optional(),
  'resources': z
      .object({
        'skills': _rulesSchema.optional(),
        'agents': _rulesSchema.optional(),
      })
      .makeStrict()
      .optional(),
}).makeStrict();
final _catalogSchema = z.object({
  'skills': z
      .array(z.object({'path': z.string()}).makeStrict())
      .min(1)
      .optional(),
  'agents': z
      .array(
        z.object({
          'path': z.string(),
          'profile': z.string().oneOf(['claude', 'codex', 'pi-common']),
        }).makeStrict(),
      )
      .min(1)
      .optional(),
}).makeStrict();
final _packConfigurationSchema = z.object({
  'schema_version': z.literal(1),
  'cli': z
      .object({
        'install': _installSchema.optional(),
        'retention': z
            .object({'snapshot_days': z.integer().gte(1).lte(36500).optional()})
            .makeStrict()
            .optional(),
      })
      .makeStrict()
      .optional(),
  'packs': z.map(z.string(), _packSchema).optional(),
  'catalog': _catalogSchema.optional(),
}).makeStrict();

/// Declarative shape gate. The semantic pass remains authoritative for
/// unknown fields, cross-field meaning, duplicates, credentials, and safe
/// paths so diagnostics stay aggregated and actionable.
List<PackConfigurationIssue> _shapeIssues(
  Object? document, {
  CatalogResourceType? catalogType,
}) {
  if (document is! Map<String, dynamic>) {
    return const [
      PackConfigurationIssue(
        'configuration',
        'must be a table',
        'invalid_type',
      ),
    ];
  }
  final nullPaths = <String>{};
  final issues = <PackConfigurationIssue>[];
  void findNulls(Object? value, List<Object?> path) {
    if (value is Map) {
      for (final entry in value.entries) {
        final next = [...path, entry.key];
        if (entry.value == null) {
          final keyPath = _schemaPath(next);
          nullPaths.add(keyPath);
          issues.add(
            PackConfigurationIssue(
              keyPath,
              'must not be null when present',
              'invalid_type',
            ),
          );
        } else {
          findNulls(entry.value, next);
        }
      }
    } else if (value is List) {
      for (var index = 0; index < value.length; index++) {
        findNulls(value[index], [...path, index]);
      }
    }
  }

  findNulls(document, const []);
  bool excluded(String path) => switch (catalogType) {
    CatalogResourceType.skill => path.startsWith('catalog.agents'),
    CatalogResourceType.agent => path.startsWith('catalog.skills'),
    null => false,
  };
  final retained = issues.where((issue) => !excluded(issue.keyPath)).toList();
  final result = _packConfigurationSchema.safeParse(document);
  if (result.isSuccess) return retained;
  for (final issue in result.errors) {
    // The semantic pass already reports unknown fields with its established
    // pack-aware paths. Strict Zema objects remain the recursive shape gate.
    if (issue.code == 'unknown_key') continue;
    final rawPath = issue.path;
    final keyPath = rawPath.isEmpty ? 'configuration' : _schemaPath(rawPath);
    if (excluded(keyPath) || nullPaths.contains(keyPath)) continue;
    // Source/track semantics report the discriminator and selected branch
    // precisely; Zema's root-level union summary would only duplicate them.
    if (issue.code == 'invalid_union') continue;
    final received = _valueAtPath(document, rawPath);
    issues.add(
      PackConfigurationIssue(
        keyPath,
        issue.code == 'too_small' && received is List
            ? 'Must contain at least one item when present.'
            : issue.message,
        issue.code,
      ),
    );
  }
  return issues;
}

Object? _valueAtPath(Object? document, Iterable<Object?> path) {
  var current = document;
  for (final segment in path) {
    if (segment is String && current is Map) {
      current = current[segment];
    } else if (segment is int && current is List && segment < current.length) {
      current = current[segment];
    } else {
      return null;
    }
  }
  return current;
}

String _schemaPath(Iterable<Object?> segments) {
  final path = StringBuffer();
  for (final segment in segments) {
    if (segment is int) {
      path.write('[$segment]');
      continue;
    }
    final key = segment.toString();
    if (path.isNotEmpty) path.write('.');
    final quote =
        key.isEmpty ||
        key.runes.any(
          (rune) =>
              rune < 0x20 ||
              rune == 0x7f ||
              rune == 0x2e ||
              rune == 0x2f ||
              rune == 0x22 ||
              rune == 0x5c,
        );
    path.write(quote ? ValidationDiagnostics.key(key) : key);
  }
  return path.toString();
}

final class _Parser {
  _Parser(this.configPath, this.inheritedPreferences, this.path);

  final p.Context path;

  final String configPath;
  final CliPreferences inheritedPreferences;
  final List<PackConfigurationIssue> issues = [];

  PackConfiguration parse(
    Map<String, dynamic> document,
    PackConfigurationScope scope, {
    CatalogResourceType? catalogType,
  }) {
    final root = _map(document, 'configuration');
    if (root == null) _throw();
    _unknown(root, 'configuration', const {
      'schema_version',
      'cli',
      'packs',
      'catalog',
    });
    final version = root['schema_version'];
    if (version is! int || version != 1) {
      _error('schema_version', 'must be the integer 1');
    }

    final cli = _parseCli(root['cli'], root.containsKey('cli'));
    final packs = _parsePacks(root['packs'], root.containsKey('packs'));
    final catalog = _parseCatalog(
      root['catalog'],
      root.containsKey('catalog'),
      catalogType: catalogType,
    );
    if (issues.isNotEmpty) _throw();
    return PackConfiguration._(
      schemaVersion: 1,
      configPath: configPath,
      scope: scope,
      cli: cli,
      packs: List.unmodifiable(packs),
      catalog: catalog,
    );
  }

  CliPreferences _parseCli(Object? value, bool present) {
    var result = inheritedPreferences;
    if (!present) return result;
    final cli = _map(value, 'cli');
    if (cli == null) return result;
    _unknown(cli, 'cli', const {'install', 'retention'});

    if (cli.containsKey('install')) {
      final install = _map(cli['install'], 'cli.install');
      if (install != null) {
        _unknown(install, 'cli.install', const {'targets', 'skill_method'});
        final targets = install.containsKey('targets')
            ? _stringList(install['targets'], 'cli.install.targets')
            : result.install.targets;
        final method = install.containsKey('skill_method')
            ? _method(install['skill_method'], 'cli.install.skill_method')
            : result.install.skillMethod;
        result = CliPreferences(
          install: CliInstallPreferences(
            targets: List.unmodifiable(targets),
            skillMethod: method,
          ),
          retention: result.retention,
        );
      }
    }
    if (cli.containsKey('retention')) {
      final retention = _map(cli['retention'], 'cli.retention');
      if (retention != null) {
        _unknown(retention, 'cli.retention', const {'snapshot_days'});
        var days = result.retention.snapshotDays;
        if (retention.containsKey('snapshot_days')) {
          final raw = retention['snapshot_days'];
          if (raw is! int) {
            _error('cli.retention.snapshot_days', 'must be an integer');
          } else {
            days = raw;
            if (days < 1 || days > 36500) {
              _error(
                'cli.retention.snapshot_days',
                'must be between 1 and 36500',
              );
            }
          }
        }
        result = CliPreferences(
          install: result.install,
          retention: CliRetentionPreferences(snapshotDays: days),
        );
      }
    }
    return result;
  }

  List<PackDefinition> _parsePacks(Object? value, bool present) {
    if (!present) return [];
    final packs = _map(value, 'packs');
    if (packs == null) return [];
    final result = <PackDefinition>[];
    final normalizedKeys = <String, String>{};
    final sourceAliases = <String, String>{};
    for (final entry in packs.entries) {
      final key = entry.key;
      final path = 'packs.${_quote(key)}';
      if (key.trim().isEmpty || _hasControl(key)) {
        _error(path, 'pack key must be a nonblank single-line string');
        continue;
      }
      final normalized = _normalizePackKey(key);
      final previousKey = normalizedKeys[normalized];
      if (previousKey != null) {
        _error(path, 'duplicates normalized pack key ${_quote(previousKey)}');
      } else {
        normalizedKeys[normalized] = key;
      }
      final body = _map(entry.value, path);
      if (body == null) continue;
      _unknown(body, path, const {
        'source',
        'install',
        'update',
        'resources',
        'discovery',
      });
      final source = _parseSource(body['source'], '$path.source', key);
      final install = _parseInstall(body['install'], '$path.install');
      final update = _parseUpdate(
        body['update'],
        body.containsKey('update'),
        '$path.update',
        source,
      );
      final resources = _parseResources(body['resources'], '$path.resources');
      final discovery = _parseDiscovery(body['discovery'], '$path.discovery');
      if (source == null || update == null) continue;
      if (install.skillMethod == SkillInstallMethod.sourceLink &&
          source is! LocalPackSource) {
        _error(
          '$path.install.skill_method',
          'source-link requires a local pack source',
        );
      }
      final alias = _sourceAlias(source);
      final previousSource = sourceAliases[alias];
      if (previousSource != null &&
          previousSource != key &&
          previousSource != previousKey) {
        _error(
          path,
          'duplicates the source declared by ${_quote(previousSource)}',
        );
      } else {
        sourceAliases[alias] = key;
      }
      result.add(
        PackDefinition(
          key: key,
          source: source,
          install: install,
          update: update,
          resources: resources,
          discovery: discovery,
        ),
      );
    }
    return result;
  }

  PackSource? _parseSource(Object? value, String path, String packKey) {
    final source = _map(value, path, required: true);
    if (source == null) return null;
    final kind = _string(source['kind'], '$path.kind', required: true);
    if (kind == null) return null;
    final allowed = switch (kind) {
      'github' => const {'kind', 'host', 'repository', 'subpath'},
      'git' || 'download' => const {'kind', 'url', 'subpath'},
      'local' => const {'kind', 'path', 'subpath'},
      _ => const <String>{},
    };
    if (allowed.isEmpty) {
      _error(
        '$path.kind',
        'must be github, git, local, or download',
        'invalid_discriminator',
      );
      return null;
    }
    _unknown(source, path, allowed);
    final subpath = source.containsKey('subpath')
        ? _safeRelativeString(source['subpath'], '$path.subpath')
        : null;
    switch (kind) {
      case 'github':
        final host = source.containsKey('host')
            ? _string(source['host'], '$path.host', required: true)
            : 'github.com';
        final repository = _string(
          source['repository'],
          '$path.repository',
          required: true,
        );
        if (host != null && !_validHost(host)) {
          _error(
            '$path.host',
            'must be a hostname without scheme or credentials',
          );
        }
        if (repository != null && !_validRepository(repository)) {
          _error('$path.repository', 'must have the form owner/repository');
        }
        if (host != null && repository != null) {
          final expected = host.toLowerCase() == 'github.com'
              ? repository
              : '$host/$repository';
          if (_normalizePackKey(expected) != _normalizePackKey(packKey)) {
            _error(path, 'source host and repository must match the pack key');
          }
        }
        if (host == null || repository == null) return null;
        return GitHubPackSource(
          host: host,
          repository: repository,
          subpath: subpath,
        );
      case 'git':
        final url = _url(source['url'], '$path.url', const {
          'http',
          'https',
          'ssh',
          'git',
        });
        return url == null ? null : GitPackSource(url: url, subpath: subpath);
      case 'download':
        final url = _url(source['url'], '$path.url', const {'http', 'https'});
        return url == null
            ? null
            : DownloadPackSource(url: url, subpath: subpath);
      case 'local':
        final localPath = _string(source['path'], '$path.path', required: true);
        if (localPath == null) return null;
        if (localPath.trim().isEmpty || localPath.contains('\u0000')) {
          _error('$path.path', 'must be a nonblank filesystem path');
          return null;
        }
        return LocalPackSource(
          path: _resolvePath(
            localPath,
            this.path.dirname(configPath),
            this.path,
          ),
          subpath: subpath,
        );
    }
    return null;
  }

  PackInstall _parseInstall(Object? value, String path) {
    if (value == null) return const PackInstall(targets: <String>[]);
    final install = _map(value, path);
    if (install == null) return const PackInstall(targets: <String>[]);
    _unknown(install, path, const {'targets', 'skill_method'});
    final targets = install.containsKey('targets')
        ? _stringList(install['targets'], '$path.targets')
        : <String>[];
    final method = install.containsKey('skill_method')
        ? _method(install['skill_method'], '$path.skill_method')
        : null;
    return PackInstall(
      targets: List.unmodifiable(targets),
      skillMethod: method,
    );
  }

  PackUpdate? _parseUpdate(
    Object? value,
    bool present,
    String path,
    PackSource? source,
  ) {
    if (source == null) return null;
    if (!present) {
      if (source is LocalPackSource) {
        return PackUpdate(track: const LocalTrack());
      }
      if (source is DownloadPackSource) {
        return PackUpdate(track: const DownloadTrack());
      }
      _error(path, 'is required for github and git sources');
      return null;
    }
    final update = _map(value, path);
    if (update == null) return null;
    _unknown(update, path, const {'track', 'bump', 'include_prerelease'});
    final track = _parseTrack(update['track'], '$path.track', source);
    ReleaseBump? bump;
    if (update.containsKey('bump')) {
      final raw = update['bump'];
      bump = switch (raw) {
        'patch' => ReleaseBump.patch,
        'minor' => ReleaseBump.minor,
        'major' => ReleaseBump.major,
        _ => null,
      };
      if (bump == null) _error('$path.bump', 'must be patch, minor, or major');
      if (track is! ReleaseTrack) {
        _error('$path.bump', 'applies only to a release track');
      }
    }
    var prerelease = false;
    if (update.containsKey('include_prerelease')) {
      final raw = update['include_prerelease'];
      if (raw is! bool) {
        _error('$path.include_prerelease', 'must be a boolean');
      } else {
        prerelease = raw;
      }
      if (track is! ReleaseTrack) {
        _error('$path.include_prerelease', 'applies only to a release track');
      }
    }
    return track == null
        ? null
        : PackUpdate(track: track, bump: bump, includePrerelease: prerelease);
  }

  PackTrack? _parseTrack(Object? value, String path, PackSource? source) {
    if (value == null && source is LocalPackSource) return const LocalTrack();
    if (value == null && source is DownloadPackSource) {
      return const DownloadTrack();
    }
    final track = _map(value, path, required: true);
    if (track == null) return null;
    final kind = _string(track['kind'], '$path.kind', required: true);
    if (kind == null) return null;
    final allowed = switch (kind) {
      'branch' || 'tag' => const {'kind', 'name'},
      'commit' => const {'kind', 'commit'},
      'release' => const {'kind', 'artifact', 'attachment'},
      'local' || 'download' => const {'kind'},
      _ => const <String>{},
    };
    if (allowed.isEmpty) {
      _error(
        '$path.kind',
        'has an unsupported track kind',
        'invalid_discriminator',
      );
      return null;
    }
    _unknown(track, path, allowed);
    final sourceKind = switch (source) {
      GitHubPackSource() => 'github',
      GitPackSource() => 'git',
      LocalPackSource() => 'local',
      DownloadPackSource() => 'download',
      null => 'unknown',
    };
    final compatible = switch (kind) {
      'branch' ||
      'tag' ||
      'commit' => sourceKind == 'github' || sourceKind == 'git',
      'release' => sourceKind == 'github',
      'local' => sourceKind == 'local',
      'download' => sourceKind == 'download',
      _ => false,
    };
    if (!compatible) {
      _error('$path.kind', 'is incompatible with the pack source');
      return null;
    }
    switch (kind) {
      case 'branch' || 'tag':
        final name = _string(track['name'], '$path.name', required: true);
        if (name == null) return null;
        if (name.trim().isEmpty || _hasControl(name)) {
          _error('$path.name', 'must be a nonblank single-line Git name');
          return null;
        }
        return kind == 'branch' ? BranchTrack(name) : TagTrack(name);
      case 'commit':
        final commit = _string(track['commit'], '$path.commit', required: true);
        if (commit == null) return null;
        if (!RegExp(r'^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$')
            .hasMatch(commit)) {
          _error('$path.commit', 'must be a full 40- or 64-digit Git commit');
          return null;
        }
        return CommitTrack(commit);
      case 'release':
        final artifact = track['artifact'];
        if (artifact != 'archive' && artifact != 'attachment') {
          _error('$path.artifact', 'must be archive or attachment');
          return null;
        }
        final attachment = track.containsKey('attachment')
            ? _string(track['attachment'], '$path.attachment', required: true)
            : null;
        if (artifact == 'attachment' &&
            (attachment == null || attachment.trim().isEmpty)) {
          _error(
            '$path.attachment',
            'is required and must be nonblank for an attachment release',
          );
          return null;
        }
        if (artifact == 'archive' && attachment != null) {
          _error('$path.attachment', 'is incompatible with an archive release');
          return null;
        }
        return ReleaseTrack(
          artifact: artifact == 'archive'
              ? ReleaseArtifact.archive
              : ReleaseArtifact.attachment,
          attachment: attachment,
        );
      case 'local':
        return const LocalTrack();
      case 'download':
        return const DownloadTrack();
    }
    return null;
  }

  PackDiscovery _parseDiscovery(Object? value, String path) {
    if (value == null) return PackDiscovery.defaults;
    final discovery = _map(value, path);
    if (discovery == null) return PackDiscovery.defaults;
    _unknown(discovery, path, const {'skills_directory', 'agents_directory'});
    return PackDiscovery(
      skillsDirectory: discovery.containsKey('skills_directory')
          ? _safeRelativeString(
                  discovery['skills_directory'],
                  '$path.skills_directory',
                  allowRoot: true,
                ) ??
                'skills'
          : 'skills',
      agentsDirectory: discovery.containsKey('agents_directory')
          ? _safeRelativeString(
                  discovery['agents_directory'],
                  '$path.agents_directory',
                  allowRoot: true,
                ) ??
                'agents'
          : 'agents',
    );
  }

  PackResources _parseResources(Object? value, String path) {
    if (value == null) return PackResources.empty;
    final resources = _map(value, path);
    if (resources == null) return PackResources.empty;
    _unknown(resources, path, const {'skills', 'agents'});
    return PackResources(
      skills: _parseRules(resources['skills'], '$path.skills', skills: true),
      agents: _parseRules(resources['agents'], '$path.agents', skills: false),
    );
  }

  PackResourceRules _parseRules(
    Object? value,
    String path, {
    required bool skills,
  }) {
    if (value == null) return PackResourceRules.empty;
    final rules = _map(value, path);
    if (rules == null) return PackResourceRules.empty;
    _unknown(rules, path, const {'exclude', 'overrides'});
    final exclusions = <String>[];
    if (rules.containsKey('exclude')) {
      final raw = rules['exclude'];
      if (raw is! List) {
        _error('$path.exclude', 'must be an array of name tables');
      } else {
        for (var index = 0; index < raw.length; index++) {
          final itemPath = '$path.exclude[$index]';
          final item = _map(raw[index], itemPath);
          if (item == null) continue;
          _unknown(item, itemPath, const {'name'});
          final name = _resourceName(item['name'], '$itemPath.name');
          if (name == null) continue;
          if (exclusions.contains(name)) {
            _error('$itemPath.name', 'duplicates exclusion ${_quote(name)}');
          } else {
            exclusions.add(name);
          }
        }
      }
    }

    final overrides = <ResourceOverride>[];
    if (rules.containsKey('overrides')) {
      final raw = rules['overrides'];
      if (raw is! List) {
        _error('$path.overrides', 'must be an array of override tables');
      } else {
        for (var index = 0; index < raw.length; index++) {
          final itemPath = '$path.overrides[$index]';
          final item = _map(raw[index], itemPath);
          if (item == null) continue;
          _unknown(
            item,
            itemPath,
            skills ? const {'name', 'extra_folders'} : const {'name'},
          );
          final name = _resourceName(item['name'], '$itemPath.name');
          if (name == null) continue;
          if (overrides.any((override) => override.name == name)) {
            _error('$itemPath.name', 'duplicates override ${_quote(name)}');
          }
          if (exclusions.contains(name)) {
            _error(
              '$itemPath.name',
              'conflicts with an exclusion for the same resource',
            );
          }
          final folders = <String>[];
          if (skills && item.containsKey('extra_folders')) {
            final rawFolders = item['extra_folders'];
            if (rawFolders is! List) {
              _error('$itemPath.extra_folders', 'must be an array of strings');
            } else {
              for (
                var folderIndex = 0;
                folderIndex < rawFolders.length;
                folderIndex++
              ) {
                final folderPath = '$itemPath.extra_folders[$folderIndex]';
                final folder = rawFolders[folderIndex];
                if (folder is! String || !_validRootFolder(folder)) {
                  _error(folderPath, 'must be one safe root-folder name');
                  continue;
                }
                if (const {
                  'references',
                  'scripts',
                  'assets',
                  'agents',
                  'SKILL.md',
                }.contains(folder)) {
                  _error(
                    folderPath,
                    'must name a non-native extra folder; native Skill roots need no approval',
                  );
                  continue;
                }
                if (folders.contains(folder)) {
                  _error(
                    folderPath,
                    'duplicates extra folder ${_quote(folder)}',
                  );
                } else {
                  folders.add(folder);
                }
              }
            }
          }
          overrides.add(
            ResourceOverride(
              name: name,
              extraFolders: List.unmodifiable(folders),
            ),
          );
        }
      }
    }
    return PackResourceRules(
      exclusions: List.unmodifiable(exclusions),
      overrides: List.unmodifiable(overrides),
    );
  }

  SourceCatalog _parseCatalog(
    Object? value,
    bool present, {
    CatalogResourceType? catalogType,
  }) {
    if (!present) return SourceCatalog.empty;
    final catalog = _map(value, 'catalog');
    if (catalog == null) return SourceCatalog.empty;
    _unknown(catalog, 'catalog', const {'skills', 'agents'});
    return SourceCatalog(
      declared: true,
      skills: catalogType == CatalogResourceType.agent
          ? const []
          : List.unmodifiable(_parseSkillCatalog(catalog['skills'])),
      agents: catalogType == CatalogResourceType.skill
          ? const []
          : List.unmodifiable(_parseAgentCatalog(catalog['agents'])),
    );
  }

  List<SkillCatalogEntry> _parseSkillCatalog(Object? value) {
    if (value == null) return [];
    if (value is! List) {
      _error('catalog.skills', 'must be an array of entry tables');
      return [];
    }
    final result = <SkillCatalogEntry>[];
    final paths = <String>{};
    for (var index = 0; index < value.length; index++) {
      final path = 'catalog.skills[$index]';
      final entry = _map(value[index], path);
      if (entry == null) continue;
      _unknown(entry, path, const {'path'});
      final entryPath = _safeRelativeString(
        entry['path'],
        '$path.path',
        allowRoot: true,
      );
      if (entryPath == null) continue;
      if (!paths.add(entryPath)) {
        _error('$path.path', 'duplicates a Skill catalog path');
      }
      result.add(SkillCatalogEntry(entryPath));
    }
    return result;
  }

  List<AgentCatalogEntry> _parseAgentCatalog(Object? value) {
    if (value == null) return [];
    if (value is! List) {
      _error('catalog.agents', 'must be an array of entry tables');
      return [];
    }
    final result = <AgentCatalogEntry>[];
    final paths = <String>{};
    for (var index = 0; index < value.length; index++) {
      final path = 'catalog.agents[$index]';
      final entry = _map(value[index], path);
      if (entry == null) continue;
      _unknown(entry, path, const {'path', 'profile'});
      final entryPath = _safeRelativeString(entry['path'], '$path.path');
      final profile = _string(
        entry['profile'],
        '$path.profile',
        required: true,
      );
      final nativeProfile = switch (profile) {
        'claude' => NativeAgentProfile.claude,
        'codex' => NativeAgentProfile.codex,
        'pi-common' => NativeAgentProfile.piCommon,
        _ => null,
      };
      if (profile != null && nativeProfile == null) {
        _error('$path.profile', 'must be claude, codex, or pi-common');
      }
      if (entryPath == null || nativeProfile == null) continue;
      if (!paths.add(entryPath)) {
        _error('$path.path', 'duplicates an Agent catalog path');
      }
      result.add(AgentCatalogEntry(path: entryPath, profile: nativeProfile));
    }
    return result;
  }

  Map<String, Object?>? _map(
    Object? value,
    String path, {
    bool required = false,
  }) {
    if (value == null) {
      if (required) _error(path, 'is required and must be a table');
      return null;
    }
    if (value is! Map) {
      _error(path, 'must be a table');
      return null;
    }
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      if (entry.key is! String) {
        _error(path, 'contains a non-string field name');
      } else {
        result[entry.key as String] = entry.value;
      }
    }
    return result;
  }

  String? _string(Object? value, String path, {bool required = false}) {
    if (value is String) return value;
    if (value != null || required) _error(path, 'must be a string');
    return null;
  }

  List<String> _stringList(Object? value, String path) {
    if (value is! List) {
      _error(path, 'must be an array of strings');
      return [];
    }
    final result = <String>[];
    for (var index = 0; index < value.length; index++) {
      final item = value[index];
      if (item is! String || !_validTarget(item)) {
        _error('$path[$index]', 'must be a lowercase kebab-case target name');
      } else if (result.contains(item)) {
        _error('$path[$index]', 'duplicates target ${_quote(item)}');
      } else {
        result.add(item);
      }
    }
    return result;
  }

  SkillInstallMethod? _method(Object? value, String path) {
    final method = switch (value) {
      'canonical' => SkillInstallMethod.canonical,
      'copy' => SkillInstallMethod.copy,
      'source-link' => SkillInstallMethod.sourceLink,
      _ => null,
    };
    if (method == null) {
      _error(path, 'must be canonical, copy, or source-link');
    }
    return method;
  }

  String? _resourceName(Object? value, String path) {
    final name = _string(value, path, required: true);
    if (name == null) return null;
    if (!RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(name) ||
        name.length > 64) {
      _error(path, 'must be 1-64 lowercase ASCII kebab-case characters');
      return null;
    }
    return name;
  }

  String? _safeRelativeString(
    Object? value,
    String path, {
    bool allowRoot = false,
  }) {
    final string = _string(value, path, required: true);
    if (string == null) return null;
    if (string.trim().isEmpty || !_safeRelative(string, allowRoot: allowRoot)) {
      _error(path, 'must be a safe forward-slash source-relative path');
      return null;
    }
    return string;
  }

  String? _url(Object? value, String path, Set<String> schemes) {
    final string = _string(value, path, required: true);
    if (string == null) return null;
    final uri = Uri.tryParse(string);
    if (uri == null ||
        !uri.hasAbsolutePath && !uri.isAbsolute ||
        !schemes.contains(uri.scheme.toLowerCase()) ||
        uri.host.isEmpty) {
      _error(path, 'must be an absolute URL with a supported scheme');
      return null;
    }
    if (uri.userInfo.isNotEmpty || _hasSensitiveQuery(uri)) {
      _error(path, 'must not contain embedded credentials or secrets');
      return null;
    }
    return string;
  }

  void _unknown(Map<String, Object?> map, String path, Set<String> allowed) {
    for (final key in map.keys) {
      if (!allowed.contains(key)) {
        _error(path.isEmpty ? key : '$path.$key', 'unknown field');
      }
    }
  }

  void _error(String path, String message, [String code = 'invalid_value']) {
    issues.add(PackConfigurationIssue(path, message, code));
  }

  Never _throw() {
    throw PackConfigurationException(
      List.unmodifiable(issues),
      configPath: configPath,
    );
  }
}

String _resolvePath(String path, String base, [p.Context? pathContext]) {
  pathContext ??= p.Context();
  return pathContext.normalize(
    pathContext.isAbsolute(path) ? path : pathContext.join(base, path),
  );
}

String _normalizePackKey(String key) => key.toLowerCase();

String _sourceAlias(PackSource source) {
  return switch (source) {
    GitHubPackSource() =>
      'github:${source.host.toLowerCase()}:${source.repository.toLowerCase()}',
    GitPackSource() => 'git:${_normalizedUriIdentity(source.url)}',
    DownloadPackSource() => 'download:${_normalizedUriIdentity(source.url)}',
    LocalPackSource() =>
      'local:${Platform.isWindows ? source.path.toLowerCase() : source.path}',
  };
}

String _normalizedUriIdentity(String value) {
  final uri = Uri.parse(value);
  return uri
      .replace(
        scheme: uri.scheme.toLowerCase(),
        host: uri.host.toLowerCase(),
        userInfo: '',
      )
      .toString();
}

bool _hasSensitiveQuery(Uri uri) {
  const sensitive = {
    'access_token',
    'auth',
    'authorization',
    'key',
    'password',
    'signature',
    'token',
    'x-amz-credential',
    'x-amz-signature',
  };
  return uri.queryParameters.keys.any(
    (key) => sensitive.contains(key.toLowerCase()),
  );
}

bool _validHost(String host) {
  return host.length <= 253 &&
      RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$').hasMatch(host) &&
      !host.contains('..');
}

bool _validRepository(String repository) {
  final parts = repository.split('/');
  return parts.length == 2 &&
      parts.every(
        (part) =>
            part.isNotEmpty &&
            part != '.' &&
            part != '..' &&
            RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(part),
      );
}

bool _validTarget(String target) =>
    RegExp(r'^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$').hasMatch(target);

bool _validRootFolder(String folder) =>
    _safeRelative(folder) && !folder.contains('/');

bool _safeRelative(String path, {bool allowRoot = false}) {
  if (allowRoot && path == '.') return true;
  if (path.isEmpty ||
      path.contains(r'\') ||
      path.endsWith('/') ||
      _hasControl(path) ||
      path.startsWith('/') ||
      RegExp(r'^[A-Za-z]:').hasMatch(path)) {
    return false;
  }
  return path
      .split('/')
      .every(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      );
}

bool _hasControl(String value) =>
    value.runes.any((rune) => rune < 0x20 || rune == 0x7f);

String _quote(String value) => '"${value.replaceAll('"', r'\"')}"';

final class PackDiscovery {
  const PackDiscovery({
    this.skillsDirectory = 'skills',
    this.agentsDirectory = 'agents',
  });

  static const defaults = PackDiscovery();

  final String skillsDirectory;
  final String agentsDirectory;
}
