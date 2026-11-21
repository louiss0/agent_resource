import 'dart:io' show FileSystemEntityType;

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../harness/harness_catalog.dart';
import '../mcp/mcp_native.dart';
import '../mcp/mcp_types.dart';
import '../mcp/mcp_validation_contract.dart';
import 'lifecycle_state_service.dart';

/// A bounded, read-only request to select one native MCP registration.
final class McpValidationSelectionRequest {
  McpValidationSelectionRequest({
    required this.environment,
    required this.harness,
    required this.scope,
    required this.name,
    this.cwd,
    this.projectRoot,
    this.home,
    this.claudeConfigDir,
    this.codexHome,
    this.piAgentDir,
    this.geminiDir,
    this.stateDir,
    LifecycleRootOverrides? roots,
  }) : roots =
           roots ??
           LifecycleRootOverrides(
             cwd: cwd,
             projectRoot: projectRoot,
             home: home,
             claudeConfigDir: claudeConfigDir,
             codexHome: codexHome,
             piAgentDir: piAgentDir,
             geminiDir: geminiDir,
             stateDir: stateDir,
           );

  final Map<String, String> environment;
  final McpHarness harness;
  final McpScope scope;
  final String name;
  final String? cwd;
  final String? projectRoot;
  final String? home;
  final String? claudeConfigDir;
  final String? codexHome;
  final String? piAgentDir;
  final String? geminiDir;
  final String? stateDir;

  /// The same overrides as one value for services that thread them onward.
  final LifecycleRootOverrides roots;
}

/// The one shared, static per-harness MCP contract.
///
/// Later pack admission and conversion waves must call [validate] with the
/// target harness, the native fields, and the requested scope. The command
/// layer adds bounded native selection; it does not define another contract.
interface class McpValidationService {
  McpValidationService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    McpNativeResolver? resolver,
    McpNativeReader? reader,
  }) : fileSystem = fileSystem,
       _resolver = resolver ?? const McpNativeResolver(),
       _reader = reader ?? McpNativeReader(fileSystem);

  final fslib.FileSystem fileSystem;
  final McpNativeResolver _resolver;
  final McpNativeReader _reader;

  McpValidationReport validate({
    required McpHarness harness,
    required Map<String, Object?> fields,
    McpScope? scope,
  }) => HarnessCatalog.instance
      .mcpSpec(harness)
      .validation
      .validate(harness: harness, fields: fields, scope: scope);

  /// Reads one selected native entry and applies the same static contract.
  /// Missing files, unreadable files, malformed documents, and missing entries
  /// are operational failures, not completed-invalid reports.
  McpValidationReport validateSelection(McpValidationSelectionRequest request) {
    if (!McpNativeResolver.supports(request.harness, request.scope)) {
      throw MambaException(
        'The ${request.harness.wireName} harness has no '
        '${request.scope.wireName} MCP scope.',
        exitCode: 2,
      );
    }
    final context = McpNativeResolver.resolveLifecycleContext(
      fileSystem,
      environment: request.environment,
      cwd: request.roots.cwd,
      projectRoot: request.roots.projectRoot,
      home: request.roots.home,
      claudeConfigDir: request.roots.claudeConfigDir,
      codexHome: request.roots.codexHome,
      piAgentDir: request.roots.piAgentDir,
      geminiDir: request.roots.geminiDir,
      stateDir: request.roots.stateDir,
    );
    final locations = _resolver.resolve(
      context,
      harness: request.harness,
      scope: request.scope,
    );
    for (final location in locations) {
      if (fileSystem.typeSync(location.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        throw MambaException(
          'MCP configuration file was not found for the selected harness '
          'and scope.',
          exitCode: 1,
        );
      }
      final fields = _reader.read(location)[request.name];
      if (fields != null) {
        return validate(
          harness: request.harness,
          fields: fields,
          scope: request.scope,
        );
      }
    }
    throw MambaException(
      'No MCP registration was found for the selected harness, scope, '
      'and name.',
      exitCode: 1,
    );
  }
}
