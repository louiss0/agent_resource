import 'dart:io' show FileSystemEntityType;

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../harness/harness_catalog.dart';
import '../mcp/mcp_native.dart';
import '../mcp/mcp_ownership_ledger.dart';
import '../mcp/mcp_types.dart';
import '../services/mcp_validation_service.dart';
import '../validation/validation_diagnostics.dart';
import 'pack_mcp_declaration.dart';
import 'pack_models.dart' show PackProcessStatus;

/// A request to admit the MCP selection of one pack for a set of target
/// harnesses. All inputs are bounded and read-only; no server is launched,
/// connected to, or authenticated.
final class PackMcpAdmissionRequest {
  const PackMcpAdmissionRequest({
    required this.declarations,
    required this.targetHarnesses,
    required this.sourceRoot,
    required this.stateRoot,
    this.reviewedResolutions = const <String>{},
  });

  final List<PackMcpDeclaration> declarations;
  final List<McpHarness> targetHarnesses;

  /// The acquired pack source root. Bounded native discovery reads only the
  /// fixed project-level files under this root.
  final String sourceRoot;

  /// The Agent Resource state root holding the MCP ownership ledger.
  final String stateRoot;

  /// Names whose collision was explicitly resolved after review.
  final Set<String> reviewedResolutions;
}

/// Where an existing registration that collides with a pack name was found.
enum PackMcpCollisionOrigin { nativeProject, managedLedger }

/// One deterministic, value-free collision observation.
final class PackMcpCollision {
  const PackMcpCollision({
    required this.name,
    required this.origin,
    required this.harness,
  });

  final String name;
  final PackMcpCollisionOrigin origin;
  final McpHarness? harness;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': ValidationDiagnostics.escape(name),
    'origin': origin.name,
    if (harness != null) 'harness': harness!.wireName,
  };
}

/// The successful, redacted account of an admitted MCP selection.
final class PackMcpAdmissionReport {
  const PackMcpAdmissionReport({
    required this.admittedNames,
    required this.discoveredNames,
    required this.managedNames,
    required this.collisions,
    required this.targetHarnesses,
  });

  final List<String> admittedNames;
  final Map<McpHarness, Set<String>> discoveredNames;
  final Set<String> managedNames;
  final List<PackMcpCollision> collisions;
  final List<McpHarness> targetHarnesses;

  /// A deterministic, value-free account. Server names and stable codes only;
  /// no registration field values or credential material are disclosed.
  Map<String, Object?> toJson() => <String, Object?>{
    'redaction': 'credential-and-value-data-omitted',
    'targets': <String>[for (final h in targetHarnesses) h.wireName],
    'admitted': admittedNames,
    'discovered': <String, Object?>{
      for (final entry in discoveredNames.entries)
        entry.key.wireName: (entry.value.toList()..sort()),
    },
    'managed': (managedNames.toList()..sort()),
    'collisions': <Object?>[for (final c in collisions) c.toJson()],
  };
}

/// The gate for an opt-in MCP pack selection (stories 36-38, 44).
///
/// It validates each inline declaration against every requested target
/// harness, refuses the whole selection when any target cannot support it,
/// reads only the bounded project-level native files inside the pack source,
/// and requires explicit reviewed resolution for any name collision. It never
/// writes a native file and never replaces a registration silently.
interface class PackMcpAdmissionService {
  PackMcpAdmissionService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    McpValidationService? validation,
    McpNativeReader? reader,
  }) : fileSystem = fileSystem,
       _validation = validation ?? McpValidationService(fileSystem: fileSystem),
       _reader = reader ?? McpNativeReader(fileSystem);

  final fslib.FileSystem fileSystem;
  final McpValidationService _validation;
  final McpNativeReader _reader;

  /// Runs the whole gate and returns a redacted account, or throws a
  /// value-free [MambaException] refusing the whole selection.
  PackMcpAdmissionReport admit(PackMcpAdmissionRequest request) {
    _requireSupportedSelection(request);
    final discovered = discoverNative(request.sourceRoot);
    final records = McpOwnershipLedger(
      fs: fileSystem,
      stateRoot: request.stateRoot,
    ).read();
    final managedNames = <String>{
      for (final record in records.values) record.identity.name,
    };
    final collisions = _collisions(request, discovered, records.values);
    final unreviewed =
        collisions
            .where((c) => !request.reviewedResolutions.contains(c.name))
            .toList()
          ..sort(_compareCollisions);
    if (unreviewed.isNotEmpty) {
      throw MambaException(
        _collisionAccount(unreviewed),
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    return PackMcpAdmissionReport(
      admittedNames: List<String>.unmodifiable(
        (request.declarations.map((d) => d.name).toList()..sort()),
      ),
      discoveredNames: discovered,
      managedNames: managedNames,
      collisions: collisions,
      targetHarnesses: request.targetHarnesses,
    );
  }

  /// Bounded, read-only native discovery (story 37). Only the fixed
  /// project-level files directly under [sourceRoot] are read; links are
  /// refused, and the shared reader enforces the byte/depth/node caps.
  Map<McpHarness, Set<String>> discoverNative(String sourceRoot) {
    final result = <McpHarness, Set<String>>{};
    for (final harness in McpHarness.values) {
      final spec = HarnessCatalog.instance.mcpSpec(harness);
      if (!spec.supportedScopes.contains(McpScope.project)) continue;
      final path = _boundedPath(sourceRoot, spec.projectSegments);
      final entries = _reader.read(
        McpNativeLocation(
          harness: harness,
          scope: McpScope.project,
          path: path,
          format: spec.nativeFormat,
          section: spec.nativeSection,
        ),
      );
      result.putIfAbsent(harness, () => <String>{}).addAll(entries.keys);
    }
    return result;
  }

  /// Per-requested-target validation with whole-selection refusal
  /// (stories 36, 44), mirroring PackPromptService.requireSupportedSelection.
  void _requireSupportedSelection(PackMcpAdmissionRequest request) {
    if (request.targetHarnesses.isEmpty) {
      throw MambaException(
        'An MCP pack selection requires at least one target harness.',
        exitCode: PackProcessStatus.invalidInput.code,
      );
    }
    for (final declaration in request.declarations) {
      for (final harness in request.targetHarnesses) {
        HarnessCatalog.instance.requireFacet(
          HarnessId.of(harness),
          HarnessFacet.mcp,
          refusalExitCode: PackProcessStatus.invalidInput.code,
        );
        final report = _validation.validate(
          harness: harness,
          fields: declaration.fields,
          scope: McpScope.project,
        );
        if (report.valid) continue;
        final codes = (report.diagnostics.map((d) => d.code).toSet().toList()
          ..sort());
        throw MambaException(
          '[$mcpPackTargetUnsupported] The MCP declaration '
          '${ValidationDiagnostics.escape(declaration.name)} is not supported '
          'by the ${harness.wireName} target (${codes.join(', ')}). The whole '
          'MCP selection is refused before any installation effect.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
    }
  }

  List<PackMcpCollision> _collisions(
    PackMcpAdmissionRequest request,
    Map<McpHarness, Set<String>> discovered,
    Iterable<McpRegistrationRecord> records,
  ) {
    final seen = <String>{};
    final result = <PackMcpCollision>[];
    void add(String name, PackMcpCollisionOrigin origin, McpHarness? harness) {
      if (seen.add('$name|${origin.name}|${harness?.wireName ?? ''}')) {
        result.add(
          PackMcpCollision(name: name, origin: origin, harness: harness),
        );
      }
    }

    for (final declaration in request.declarations) {
      for (final harness in request.targetHarnesses) {
        if (discovered[harness]?.contains(declaration.name) ?? false) {
          add(declaration.name, PackMcpCollisionOrigin.nativeProject, harness);
        }
      }
      for (final record in records) {
        if (record.identity.name == declaration.name) {
          add(
            declaration.name,
            PackMcpCollisionOrigin.managedLedger,
            record.identity.harness,
          );
        }
      }
    }
    return result..sort(_compareCollisions);
  }

  /// A bounded path join that refuses any linked segment. Discovery never
  /// follows an alias out of the pack source root.
  String _boundedPath(String sourceRoot, List<String> segments) {
    var current = sourceRoot;
    for (final segment in segments) {
      current = fileSystem.path.join(current, segment);
      if (fileSystem.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw MambaException(
          'Refusing to read MCP pack configuration through a link: '
          '${ValidationDiagnostics.escape(segment)}.',
          exitCode: 1,
        );
      }
    }
    return current;
  }

  /// A deterministic, redacted account of the unreviewed collisions. Only
  /// server names, origins and harnesses are printed - never a value.
  String _collisionAccount(List<PackMcpCollision> collisions) {
    final buffer = StringBuffer()
      ..writeln(
        '[$mcpPackCollisionReviewRequired] Pack MCP names collide with '
        'existing registrations; the selection is refused before any '
        'installation effect.',
      )
      ..writeln('redaction: credential-and-value-data-omitted');
    for (final collision in collisions) {
      final harness = collision.harness == null
          ? ''
          : ' (${collision.harness!.wireName})';
      buffer.writeln(
        '- ${ValidationDiagnostics.escape(collision.name)}: '
        '${collision.origin.name}$harness',
      );
    }
    buffer.writeln(
      'Explicit reviewed resolution is required for each colliding name; '
      'nothing is silently replaced.',
    );
    return buffer.toString();
  }

  int _compareCollisions(PackMcpCollision a, PackMcpCollision b) {
    final name = a.name.compareTo(b.name);
    if (name != 0) return name;
    final origin = a.origin.name.compareTo(b.origin.name);
    if (origin != 0) return origin;
    return (a.harness?.wireName ?? '').compareTo(b.harness?.wireName ?? '');
  }
}
