import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../mcp/mcp_envelope.dart';
import '../mcp/mcp_native.dart';
import '../mcp/mcp_ownership_ledger.dart';
import '../mcp/mcp_selected_entry.dart';
import '../mcp/mcp_types.dart';
import 'lifecycle_state_service.dart';

/// A read-only MCP discovery/selection request.
final class McpInspectionRequest {
  const McpInspectionRequest({
    required this.environment,
    this.harness,
    this.scope,
    this.name,
    this.cwd,
    this.projectRoot,
    this.home,
    this.claudeConfigDir,
    this.codexHome,
    this.piAgentDir,
    this.stateDir,
    this.verify = false,
  });

  final Map<String, String> environment;
  final McpHarness? harness;
  final McpScope? scope;
  final String? name;
  final String? cwd;
  final String? projectRoot;
  final String? home;
  final String? claudeConfigDir;
  final String? codexHome;
  final String? piAgentDir;
  final String? stateDir;
  final bool verify;
}

/// Passive MCP discovery (stories 1-4, 42, 43, 45).
///
/// It reads native configuration only: it never launches, connects to, or
/// authenticates against a server and never claims runtime activation.
/// Ownership is classified from the versioned management ledger:
/// unmanaged (no record), managed (baseline digest matches), and
/// ownership-unverified (record present but native entry missing or drifted).
interface class McpInspectionService {
  McpInspectionService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    McpNativeResolver? resolver,
    McpNativeReader? reader,
  }) : fileSystem = fileSystem,
       _resolver = resolver ?? const McpNativeResolver(),
       _reader = reader ?? McpNativeReader(fileSystem);

  final fslib.FileSystem fileSystem;
  final McpNativeResolver _resolver;
  final McpNativeReader _reader;

  LifecycleContext _context(McpInspectionRequest request) =>
      LifecycleContext.resolve(
        LifecycleOptions(
          processWorkingDirectory: fileSystem.currentDirectory.path,
          environment: request.environment,
          scope: LifecycleScope.user,
          cwd: request.cwd,
          projectRoot: request.projectRoot,
          home: request.home,
          claudeConfigDir: request.claudeConfigDir,
          codexHome: request.codexHome,
          piAgentDir: request.piAgentDir,
          stateDir: request.stateDir,
        ),
        fileSystem: fileSystem,
      );

  McpOwnershipLedger _ledger(LifecycleContext context) => McpOwnershipLedger(
    fs: fileSystem,
    stateRoot: context.stateRoot(LifecycleScope.user),
  );

  void _validateFilters(McpInspectionRequest request) {
    if (request.harness != null &&
        request.scope != null &&
        !McpNativeResolver.supports(request.harness!, request.scope!)) {
      throw MambaException(
        'The ${request.harness!.wireName} harness has no '
        '${request.scope!.wireName} MCP scope.',
        exitCode: 2,
      );
    }
  }

  /// Reports every observed registration across the three harnesses and the
  /// requested scopes with ownership classification and no activation claim.
  Future<McpEnvelope> list(McpInspectionRequest request) async {
    _validateFilters(request);
    final context = _context(request);
    final locations = _resolver.resolve(
      context,
      harness: request.harness,
      scope: request.scope,
    );
    final records = _ledger(context).read();
    final observed = <McpSelectedEntry>[];
    final observedKeys = <String>{};

    for (final location in locations) {
      for (final entry in _reader.read(location).entries) {
        final identity = McpRegistrationIdentity(
          harness: location.harness,
          scope: location.scope,
          location: location.path,
          name: entry.key,
        );
        final digest = mcpCanonicalDigest(entry.value);
        observed.add(_classify(identity, entry.value, digest, records));
        observedKeys.add(identity.storageKey);
      }
    }

    // Ledger records whose native entry is missing are reported as
    // ownership-unverified observations, without claiming activation.
    for (final record in records.values) {
      final identity = record.identity;
      if (observedKeys.contains(identity.storageKey)) continue;
      if (request.harness != null && identity.harness != request.harness) {
        continue;
      }
      if (request.scope != null && identity.scope != request.scope) continue;
      observed.add(
        McpSelectedEntry(
          identity: identity,
          rawFields: const <String, Object?>{},
          digest: record.baselineDigest,
          ownership: McpOwnership.ownershipUnverified,
          present: false,
        ),
      );
    }

    observed.sort(_compare);
    final data = <String, Object?>{
      'claim': 'configuration-only; runtime activation is not verified',
      'verified': request.verify,
      'count': observed.length,
      'registrations': <Object?>[
        for (final entry in observed)
          entry.toJson(discloseDigest: request.verify),
      ],
    };
    return McpEnvelope(
      command: 'mcp.list',
      outcome: 'listed',
      data: data,
      diagnostics: _staticDiagnostics(),
    );
  }

  /// Selects one registration by name plus explicit harness and scope and
  /// renders its native shape with central redaction.
  Future<McpEnvelope> inspect(McpInspectionRequest request) async {
    final name = request.name;
    if (name == null || name.trim().isEmpty) {
      throw MambaException('mcp inspect requires --name.', exitCode: 2);
    }
    if (request.harness == null) {
      throw MambaException(
        'mcp inspect requires an explicit --harness.',
        exitCode: 2,
      );
    }
    if (request.scope == null) {
      throw MambaException(
        'mcp inspect requires an explicit --scope.',
        exitCode: 2,
      );
    }
    _validateFilters(request);
    final context = _context(request);
    final locations = _resolver.resolve(
      context,
      harness: request.harness,
      scope: request.scope,
    );
    final records = _ledger(context).read();
    for (final location in locations) {
      final raw = _reader.read(location)[name];
      if (raw != null) {
        final identity = McpRegistrationIdentity(
          harness: location.harness,
          scope: location.scope,
          location: location.path,
          name: name,
        );
        final digest = mcpCanonicalDigest(raw);
        final entry = _classify(identity, raw, digest, records);
        return McpEnvelope(
          command: 'mcp.inspect',
          outcome: 'inspected',
          data: <String, Object?>{
            'claim': 'configuration-only; runtime activation is not verified',
            'registration': entry.toJson(discloseDigest: true),
          },
          diagnostics: _staticDiagnostics(),
        );
      }
    }
    throw MambaException(
      'No MCP registration was found for the selected harness, scope, '
      'and name.',
      exitCode: 2,
    );
  }

  McpSelectedEntry _classify(
    McpRegistrationIdentity identity,
    Map<String, Object?> raw,
    String digest,
    Map<String, McpRegistrationRecord> records,
  ) {
    final record = records[identity.storageKey];
    final McpOwnership ownership;
    if (record == null) {
      ownership = McpOwnership.unmanaged;
    } else if (record.baselineDigest != digest) {
      ownership = McpOwnership.ownershipUnverified;
    } else {
      ownership = McpOwnership.managed;
    }
    return McpSelectedEntry(
      identity: identity,
      rawFields: raw,
      digest: digest,
      ownership: ownership,
      transport: _transport(raw),
    );
  }

  McpTransport? _transport(Map<String, Object?> fields) {
    if (fields['url'] != null) return McpTransport.http;
    if (fields['command'] != null) return McpTransport.stdio;
    final type = fields['type'];
    if (type == 'http' ||
        type == 'streamable-http' ||
        type == 'sse' ||
        type == 'ws') {
      return McpTransport.http;
    }
    if (type == 'stdio') return McpTransport.stdio;
    return null;
  }

  List<Map<String, Object?>> _staticDiagnostics() =>
      const <Map<String, Object?>>[
        <String, Object?>{
          'code': 'STATIC_CONFIGURATION_ONLY',
          'severity': 'info',
          'message':
              'Native configuration was read only; no server was launched, '
              'connected to, or authenticated, and runtime activation '
              'is not verified.',
        },
      ];

  int _compare(McpSelectedEntry a, McpSelectedEntry b) {
    final harness = a.harness.wireName.compareTo(b.harness.wireName);
    if (harness != 0) return harness;
    final scope = a.scope.wireName.compareTo(b.scope.wireName);
    if (scope != 0) return scope;
    final location = a.location.compareTo(b.location);
    if (location != 0) return location;
    return a.name.compareTo(b.name);
  }
}
