import 'dart:convert';
import 'dart:io' show FileSystemEntityType, FileSystemException;

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import '../harness/harness_catalog.dart';
import '../services/lifecycle_state_service.dart';
import '../services/parent_config_service.dart';
import 'mcp_native_location.dart';
import 'mcp_types.dart';

export 'mcp_native_location.dart';

const int maxMcpNativeBytes = 8 * 1024 * 1024;
const int maxMcpNativeDepth = 32;
const int maxMcpNativeNodes = 100000;

/// Maps requested harnesses and scopes to native configuration locations,
/// following the existing [LifecycleContext] path rules (home, codex home,
/// Pi agent directory, project root and their overrides).
final class _LifecycleMcpRoots implements McpHarnessRoots {
  const _LifecycleMcpRoots(this.context);

  final LifecycleContext context;

  @override
  String get projectRoot => context.projectRoot;

  @override
  p.Context get path => context.fs.path;

  @override
  String requireHome() => context.requireHome();

  @override
  String claudeConfigRoot() => context.claudeConfigRoot();

  @override
  String codexRoot() => context.codexRoot();

  @override
  String piAgentRoot() => context.piAgentRoot();

  @override
  String geminiConfigRoot() => context.geminiConfigRoot();
}

final class McpNativeResolver {
  const McpNativeResolver();

  /// Resolves the shared lifecycle context of one static MCP request.
  ///
  /// Every MCP service resolves the same path options with user scope;
  /// keeping that decision here prevents the services from drifting apart.
  static LifecycleContext resolveLifecycleContext(
    fslib.FileSystem fs, {
    required Map<String, String> environment,
    String? cwd,
    String? projectRoot,
    String? home,
    String? claudeConfigDir,
    String? codexHome,
    String? piAgentDir,
    String? geminiDir,
    String? stateDir,
  }) => LifecycleContext.resolve(
    LifecycleOptions(
      processWorkingDirectory: fs.currentDirectory.path,
      environment: environment,
      scope: LifecycleScope.user,
      cwd: cwd,
      projectRoot: projectRoot,
      home: home,
      claudeConfigDir: claudeConfigDir,
      codexHome: codexHome,
      piAgentDir: piAgentDir,
      geminiDir: geminiDir,
      stateDir: stateDir,
    ),
    fileSystem: fs,
  );

  /// Whether the selected harness facet publishes registrations at a scope.
  static bool supports(McpHarness harness, McpScope scope) =>
      HarnessCatalog.instance.mcpSpec(harness).supportedScopes.contains(scope);

  /// Resolves every supported location through the composed catalog facets.
  List<McpNativeLocation> resolve(
    LifecycleContext context, {
    McpHarness? harness,
    McpScope? scope,
  }) {
    final roots = _LifecycleMcpRoots(context);
    final catalog = HarnessCatalog.instance;
    final locations = <McpNativeLocation>[];
    for (final id in catalog.harnessesSupporting(HarnessFacet.mcp)) {
      final spec = catalog.mcpSpecById(id);
      if (harness != null && spec.mcpHarness != harness) continue;
      for (final location in spec.locations(roots)) {
        if (scope == null || location.scope == scope) {
          locations.add(location);
        }
      }
    }
    return locations;
  }
}

/// Bounded, link-aware, never-writing reader for native MCP configuration.
final class McpNativeReader {
  const McpNativeReader(this.fs);

  final fslib.FileSystem fs;

  /// Returns raw server entry maps keyed by server name. A missing file
  /// yields an empty map; links, oversize files, malformed/duplicate-key JSON,
  /// invalid TOML and invalid UTF-8 are operational failures (status 1).
  Map<String, Map<String, Object?>> read(McpNativeLocation location) {
    final text = readMcpNativeText(fs, location.path);
    if (text == null) return <String, Map<String, Object?>>{};
    final Map<String, Object?> document = switch (location.format) {
      McpNativeFormat.json => _strictJson(text, location.path),
      McpNativeFormat.toml => _toml(text, location.path),
    };
    final spec = HarnessCatalog.instance.mcpSpec(location.harness);
    return switch (location.section) {
      McpNativeSection.mcpServers => _entries(
        document[spec.sectionKey(McpNativeSection.mcpServers)],
        location.path,
      ),
      McpNativeSection.codexMcpServers => _entries(
        document[spec.sectionKey(McpNativeSection.codexMcpServers)],
        location.path,
      ),
      McpNativeSection.claudeLocalProjects => _claudeLocalEntries(
        document,
        location,
        spec,
      ),
    };
  }

  Map<String, Object?> _strictJson(String text, String path) {
    try {
      return parseStrictJsonObject(text);
    } on FormatException {
      throw MambaException(
        'MCP configuration is not valid strict JSON '
        '(malformed or duplicate keys): $path',
        exitCode: 1,
      );
    } on MambaException {
      throw MambaException(
        'MCP configuration is not a JSON object: $path',
        exitCode: 1,
      );
    }
  }

  Map<String, Object?> _toml(String text, String path) {
    final Map<String, dynamic> map;
    try {
      map = TomlDocument.parse(text).toMap();
    } catch (_) {
      throw MambaException(
        'MCP configuration is not valid TOML: $path',
        exitCode: 1,
      );
    }
    _chargeTomlBudget(map);
    return Map<String, Object?>.from(map);
  }

  void _chargeTomlBudget(Object? root) {
    var nodes = 0;
    void visit(Object? value, int depth) {
      if (++nodes > maxMcpNativeNodes || depth > maxMcpNativeDepth) {
        throw MambaException(
          'MCP TOML configuration exceeds the depth or node budget.',
          exitCode: 1,
        );
      }
      if (value is Map) {
        for (final child in value.values) {
          visit(child, depth + 1);
        }
      } else if (value is List) {
        for (final child in value) {
          visit(child, depth + 1);
        }
      }
    }

    visit(root, 0);
  }

  Map<String, Map<String, Object?>> _claudeLocalEntries(
    Map<String, Object?> document,
    McpNativeLocation location,
    McpHarnessSpec spec,
  ) {
    final projects =
        document[spec.sectionKey(McpNativeSection.claudeLocalProjects)];
    if (projects == null) return <String, Map<String, Object?>>{};
    if (projects is! Map) {
      throw MambaException(
        'Claude projects must be an object: ${location.path}',
        exitCode: 1,
      );
    }
    final wanted = fs.path.normalize(location.projectKey!);
    Object? selected;
    for (final entry in projects.entries) {
      if (fs.path.normalize(entry.key.toString()) == wanted) {
        selected = entry.value;
        break;
      }
    }
    if (selected == null) return <String, Map<String, Object?>>{};
    if (selected is! Map) {
      throw MambaException(
        'Claude project entry must be an object: ${location.path}',
        exitCode: 1,
      );
    }
    return _entries(
      selected[spec.sectionKey(McpNativeSection.mcpServers)],
      location.path,
    );
  }

  Map<String, Map<String, Object?>> _entries(Object? container, String path) {
    if (container == null) return <String, Map<String, Object?>>{};
    if (container is! Map) {
      throw MambaException(
        'MCP server map must be an object: $path',
        exitCode: 1,
      );
    }
    final result = <String, Map<String, Object?>>{};
    for (final entry in container.entries) {
      final value = entry.value;
      if (value is! Map) {
        throw MambaException(
          'MCP server entry must be an object: $path',
          exitCode: 1,
        );
      }
      result[entry.key.toString()] = <String, Object?>{
        for (final field in value.entries)
          field.key.toString(): _jsonSafe(field.value),
      };
    }
    return result;
  }
}

/// Reads a native/state text file with a bounded byte read. Rejects links,
/// non-regular files, oversize files and invalid UTF-8 as operational
/// failures. Returns null for an absent file. Never writes.
String? readMcpNativeText(fslib.FileSystem fs, String path) {
  final type = fs.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw MambaException(
      'Refusing to read MCP configuration through a link: $path',
      exitCode: 1,
    );
  }
  if (type == FileSystemEntityType.notFound) return null;
  if (type != FileSystemEntityType.file) {
    throw MambaException(
      'MCP configuration is not a regular file: $path',
      exitCode: 1,
    );
  }
  fslib.RandomAccessFile? handle;
  final List<int> bytes;
  try {
    handle = fs.file(path).openSync();
    bytes = handle.readSync(maxMcpNativeBytes + 1);
  } on FileSystemException catch (error) {
    throw MambaException(
      'Could not read MCP configuration $path: ${error.message}',
      exitCode: 1,
    );
  } finally {
    handle?.closeSync();
  }
  if (bytes.length > maxMcpNativeBytes) {
    throw MambaException('MCP configuration exceeds 8 MiB: $path', exitCode: 1);
  }
  try {
    return utf8.decode(bytes, allowMalformed: false);
  } on FormatException {
    throw MambaException(
      'MCP configuration is not valid UTF-8: $path',
      exitCode: 1,
    );
  }
}

/// Deterministic SHA-256 digest over canonical JSON of [value]. Map keys are
/// sorted so two equivalent entries hash identically regardless of source
/// key order. Used as the ownership baseline for drift detection.
String mcpCanonicalDigest(Object? value) {
  final canonical = _canonicalize(value);
  return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
}

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort((a, b) => a.key.toString().compareTo(b.key.toString()));
    return <String, Object?>{
      for (final entry in entries)
        entry.key.toString(): _canonicalize(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) _canonicalize(item)];
  }
  if (value is DateTime) return value.toUtc().toIso8601String();
  return value;
}

/// Coerce parser-specific values (for example TOML datetimes) to JSON-safe
/// types so raw fields can always be serialized and redacted safely.
Object? _jsonSafe(Object? value) {
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Map) {
    return <String, Object?>{
      for (final entry in value.entries)
        entry.key.toString(): _jsonSafe(entry.value),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) _jsonSafe(item)];
  }
  if (value is String || value is num || value is bool || value == null) {
    return value;
  }
  return value.toString();
}
