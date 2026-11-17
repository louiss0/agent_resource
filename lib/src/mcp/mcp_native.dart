import 'dart:convert';
import 'dart:io' show FileSystemEntityType, FileSystemException;

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:mamba/mamba.dart';
import 'package:toml/toml.dart';

import '../services/lifecycle_state_service.dart';
import '../services/parent_config_service.dart';
import 'mcp_types.dart';

const int maxMcpNativeBytes = 8 * 1024 * 1024;
const int maxMcpNativeDepth = 32;
const int maxMcpNativeNodes = 100000;

/// The parser used for a native configuration file.
enum McpNativeFormat { json, toml }

/// Which part of a parsed document holds the named server entries.
enum McpNativeSection { mcpServers, claudeLocalProjects, codexMcpServers }

/// One bounded, read-only native configuration location.
final class McpNativeLocation {
  const McpNativeLocation({
    required this.harness,
    required this.scope,
    required this.path,
    required this.format,
    required this.section,
    this.projectKey,
  });

  final McpHarness harness;
  final McpScope scope;
  final String path;
  final McpNativeFormat format;
  final McpNativeSection section;

  /// The `projects` map key for Claude local scope.
  final String? projectKey;
}

/// Maps requested harnesses and scopes to native configuration locations,
/// following the existing [LifecycleContext] path rules (home, codex home,
/// Pi agent directory, project root and their overrides).
final class McpNativeResolver {
  const McpNativeResolver();

  /// Whether a harness publishes registrations at a given scope. Claude has
  /// a local scope in the home file; Codex and Pi have only project/user.
  static bool supports(McpHarness harness, McpScope scope) {
    if (scope == McpScope.local) return harness == McpHarness.claude;
    return true;
  }

  List<McpNativeLocation> resolve(
    LifecycleContext context, {
    McpHarness? harness,
    McpScope? scope,
  }) {
    final fs = context.fs;
    final root = context.projectRoot;
    final locations = <McpNativeLocation>[];

    bool wants(McpHarness candidate, McpScope candidateScope) =>
        (harness == null || harness == candidate) &&
        (scope == null || scope == candidateScope);

    if (wants(McpHarness.claude, McpScope.project)) {
      locations.add(
        McpNativeLocation(
          harness: McpHarness.claude,
          scope: McpScope.project,
          path: fs.path.join(root, '.mcp.json'),
          format: McpNativeFormat.json,
          section: McpNativeSection.mcpServers,
        ),
      );
    }
    if (wants(McpHarness.claude, McpScope.user)) {
      locations.add(
        McpNativeLocation(
          harness: McpHarness.claude,
          scope: McpScope.user,
          path: fs.path.join(context.requireHome(), '.claude.json'),
          format: McpNativeFormat.json,
          section: McpNativeSection.mcpServers,
        ),
      );
    }
    if (wants(McpHarness.claude, McpScope.local)) {
      locations.add(
        McpNativeLocation(
          harness: McpHarness.claude,
          scope: McpScope.local,
          path: fs.path.join(context.requireHome(), '.claude.json'),
          format: McpNativeFormat.json,
          section: McpNativeSection.claudeLocalProjects,
          projectKey: root,
        ),
      );
    }
    if (wants(McpHarness.codex, McpScope.user)) {
      locations.add(
        McpNativeLocation(
          harness: McpHarness.codex,
          scope: McpScope.user,
          path: fs.path.join(context.codexRoot(), 'config.toml'),
          format: McpNativeFormat.toml,
          section: McpNativeSection.codexMcpServers,
        ),
      );
    }
    if (wants(McpHarness.codex, McpScope.project)) {
      locations.add(
        McpNativeLocation(
          harness: McpHarness.codex,
          scope: McpScope.project,
          path: fs.path.join(root, '.codex', 'config.toml'),
          format: McpNativeFormat.toml,
          section: McpNativeSection.codexMcpServers,
        ),
      );
    }
    if (wants(McpHarness.pi, McpScope.user)) {
      locations.add(
        McpNativeLocation(
          harness: McpHarness.pi,
          scope: McpScope.user,
          path: fs.path.join(context.piAgentRoot(), 'mcp.json'),
          format: McpNativeFormat.json,
          section: McpNativeSection.mcpServers,
        ),
      );
    }
    if (wants(McpHarness.pi, McpScope.project)) {
      locations.add(
        McpNativeLocation(
          harness: McpHarness.pi,
          scope: McpScope.project,
          path: fs.path.join(root, '.pi', 'mcp.json'),
          format: McpNativeFormat.json,
          section: McpNativeSection.mcpServers,
        ),
      );
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
    return switch (location.section) {
      McpNativeSection.mcpServers => _entries(
        document['mcpServers'],
        location.path,
      ),
      McpNativeSection.codexMcpServers => _entries(
        document['mcp_servers'],
        location.path,
      ),
      McpNativeSection.claudeLocalProjects => _claudeLocalEntries(
        document,
        location,
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
  ) {
    final projects = document['projects'];
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
    return _entries(selected['mcpServers'], location.path);
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
