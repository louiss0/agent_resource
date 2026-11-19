import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../agent_inspection.dart';
import '../harness/harness_catalog.dart';
import '../native_references.dart';
import '../skill_files.dart';
import 'agent_authoring_service.dart';
import 'agent_graph_service.dart';
import 'agent_lifecycle_service.dart';
import 'lifecycle_state_service.dart';
import 'parent_config_service.dart' show parseStrictJsonObject;

final class ConversionRequest {
  const ConversionRequest({
    required this.source,
    required this.target,
    required this.context,
    required this.definition,
    required this.decisions,
    required this.references,
  });

  final Map<String, Object?> source;
  final Map<String, Object?> target;
  final String context;
  final Map<String, Object?> definition;
  final Set<String> decisions;
  final Map<String, String> references;
}

ConversionRequest parseConversionRequest(
  String requestFile,
  String workingDirectory, {
  fslib.FileSystem fileSystem = const local.LocalFileSystem(),
}) {
  final path = fileSystem.path.normalize(
    fileSystem.path.isAbsolute(requestFile)
        ? requestFile
        : fileSystem.path.join(workingDirectory, requestFile),
  );
  if (skillEntityType(path, followLinks: false, fs: fileSystem) !=
      FileSystemEntityType.file) {
    throw MambaException(
      'The conversion request must be a regular file: $path',
    );
  }
  final bytes = readBoundedSkillMarker(
    path,
    maxBytes: maxManagementDocumentBytes,
    fs: fileSystem,
  );
  if (bytes.length > maxManagementDocumentBytes) {
    throw MambaException('The conversion request exceeds 8 MiB.', exitCode: 3);
  }
  final Map<String, Object?> map;
  try {
    map = parseStrictJsonObject(utf8.decode(bytes, allowMalformed: false));
  } on FormatException catch (error) {
    throw MambaException('Invalid conversion request: ${error.message}');
  }
  _known(map, const {
    'schemaVersion',
    'operation',
    'source',
    'target',
    'context',
    'definition',
    'decisions',
    'references',
  }, 'conversion request');
  if (map['schemaVersion'] != 1 || map['operation'] != 'convert') {
    throw MambaException(
      'Conversion requests require schemaVersion 1 and operation convert.',
    );
  }
  final source = _map(map['source'], 'source');
  final kind = source['kind'];
  if (kind == 'native-file') {
    _known(source, const {'kind', 'path', 'harness'}, 'native-file source');
    if (!_nonblankString(source['path']) ||
        !_nonblankString(source['harness']) ||
        AgentHarness.values.every((value) => value.name != source['harness'])) {
      throw MambaException(
        'A native-file conversion source requires a nonblank path and a '
        'supported claude, codex, pi, or antigravity harness.',
      );
    }
  } else if (kind == 'codex-role') {
    _known(source, const {
      'kind',
      'configFile',
      'roleKey',
    }, 'Codex role source');
    if (!_nonblankString(source['configFile']) ||
        !_nonblankString(source['roleKey'])) {
      throw MambaException(
        'A Codex role conversion source requires nonblank configFile and roleKey.',
      );
    }
  } else if (kind == 'managed-agent') {
    _known(source, const {'kind', 'installationId'}, 'managed Agent source');
    if (!_nonblankString(source['installationId'])) {
      throw MambaException(
        'A managed conversion source requires a nonblank installationId.',
      );
    }
  } else {
    throw MambaException('Unsupported conversion source kind: $kind');
  }
  final target = _map(map['target'], 'target');
  _known(target, const {
    'harness',
    'output',
    'destination',
    'installationId',
  }, 'conversion target');
  if (target['harness'] is! String ||
      AgentHarness.values.every((value) => value.name != target['harness'])) {
    throw MambaException(
      'Conversion target harness must be claude, codex, pi, or antigravity.',
    );
  }
  for (final key in const ['output', 'installationId']) {
    final value = target[key];
    if (value != null && !_nonblankString(value)) {
      throw MambaException('Conversion target $key must be a nonblank string.');
    }
  }
  final destination = target['destination'];
  if (destination != null &&
      destination != 'native' &&
      destination != 'shared') {
    throw MambaException(
      'Conversion target destination must be native or shared.',
    );
  }
  final context = _map(map['context'], 'context');
  _known(context, const {'workingDirectory'}, 'conversion context');
  if (context['workingDirectory'] is! String ||
      (context['workingDirectory']! as String).trim().isEmpty) {
    throw MambaException(
      'Conversion context workingDirectory must be nonblank.',
    );
  }
  final definition = _map(
    map['definition'] ?? const <String, Object?>{},
    'definition',
  );
  for (final key in definition.keys) {
    if (key.trim().isEmpty) {
      throw MambaException(
        'Conversion definition field names must not be blank.',
      );
    }
  }
  final rawDecisions = map['decisions'] ?? const <Object?>[];
  if (rawDecisions is! List<Object?> ||
      rawDecisions.any((value) => value is! String || (value).trim().isEmpty)) {
    throw MambaException(
      'Conversion decisions must be nonblank field-specific strings.',
    );
  }
  final decisions = rawDecisions.cast<String>().toSet();
  if (decisions.length != rawDecisions.length) {
    throw MambaException('Conversion decisions must not contain duplicates.');
  }
  final rawReferences = _map(
    map['references'] ?? const <String, Object?>{},
    'references',
  );
  final references = <String, String>{};
  for (final entry in rawReferences.entries) {
    if (entry.value is! String || (entry.value! as String).trim().isEmpty) {
      throw MambaException(
        'Conversion reference mappings require nonblank strings.',
      );
    }
    references[entry.key] = entry.value! as String;
  }
  _rejectCredentials(definition);
  return ConversionRequest(
    source: source,
    target: target,
    context: context['workingDirectory']! as String,
    definition: definition,
    decisions: decisions,
    references: references,
  );
}

bool _nonblankString(Object? value) =>
    value is String && value.trim().isNotEmpty;

Map<String, Object?> _map(Object? value, String label) {
  if (value is! Map<String, Object?>) {
    throw MambaException('$label must be an object.');
  }
  return value;
}

void _known(Map<String, Object?> map, Set<String> allowed, String label) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw MambaException('Unknown $label field: $key');
    }
  }
}

void _rejectCredentials(Object? value, [String path = 'definition']) {
  if (value is Map<String, Object?>) {
    for (final entry in value.entries) {
      final key = entry.key.toLowerCase();
      if (entry.value is String &&
          (key.contains('secret') ||
              key.contains('password') ||
              key.contains('token') ||
              key.contains('credential')) &&
          !key.endsWith('_env') &&
          !key.endsWith('reference')) {
        throw MambaException(
          'New credential literals are forbidden at $path.${entry.key}.',
          exitCode: 4,
        );
      }
      _rejectCredentials(entry.value, '$path.${entry.key}');
    }
  } else if (value is List<Object?>) {
    for (var index = 0; index < value.length; index++) {
      _rejectCredentials(value[index], '$path[$index]');
    }
  }
}

/// Native association kinds that conversion must map, replace, or remove
/// explicitly; a model is accounted through `map:model` instead.
const _associationKinds = <String>{'skill', 'mcp-server', 'hook'};

/// Whether the proposed target still declares the source association [key].
///
/// A removal decision only authorizes omission; it must not publish a target
/// that keeps the association through another field value.
bool _targetDeclaresAssociation(
  Map<String, Object?> fields,
  String key,
  AgentHarness harness,
) {
  final separator = key.indexOf(':');
  if (separator <= 0) return false;
  final kind = key.substring(0, separator);
  final name = key.substring(separator + 1);
  final field = switch ((kind, harness)) {
    ('skill', AgentHarness.claude || AgentHarness.codex) => 'skills',
    ('mcp-server', AgentHarness.claude) => 'mcpServers',
    ('mcp-server', AgentHarness.codex) => 'mcp_servers',
    ('hook', AgentHarness.claude) => 'hooks',
    _ => null,
  };
  return field != null && containsNativeReference(fields[field], name);
}

final class ConversionPlan {
  const ConversionPlan({required this.result, required this.authoring});
  final LifecycleResult result;
  final AuthoringPlan authoring;
}

interface class AgentConversionService {
  AgentConversionService({
    AgentAuthoringService? authoring,
    AgentGraphService? graph,
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
  }) : _fileSystem = fileSystem,
       authoring = authoring ?? AgentAuthoringService(fileSystem: fileSystem),
       _graph = graph ?? AgentGraphService(fileSystem: fileSystem);

  fslib.FileSystem get fileSystem => _fileSystem;

  final fslib.FileSystem _fileSystem;
  final AgentAuthoringService authoring;
  final AgentGraphService _graph;

  Future<ConversionPlan> plan(
    ConversionRequest request,
    LifecycleOptions options, {
    bool showInstructions = false,
  }) async {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    if (!_fileSystem.path.equals(
      context.resolvePath(request.context),
      context.cwd,
    )) {
      throw MambaException(
        'Conversion workingDirectory must agree with --cwd.',
      );
    }
    final source = _inspectSource(request.source, options);
    final targetHarness = AgentHarness.values.singleWhere(
      (value) => value.name == request.target['harness'],
    );
    final sourceHarness = switch (source.form) {
      'claude-agent-file' => AgentHarness.claude,
      'codex-agent-file' || 'codex-config-bound-role' => AgentHarness.codex,
      'pi-agent-file' => AgentHarness.pi,
      'antigravity-agent-file' => AgentHarness.antigravity,
      _ => throw MambaException('Unsupported native source form.', exitCode: 4),
    };
    final catalog = HarnessCatalog.instance;
    final sourceSpec = catalog.agentSpecById(
      HarnessId.fromWire(sourceHarness.name),
    );
    final targetSpec = catalog.agentSpecById(
      HarnessId.fromWire(targetHarness.name),
    );
    if (sourceHarness == targetHarness) {
      throw MambaException(
        'Conversion requires different source and target profiles; use clone or edit.',
      );
    }
    final targetFields = <String, Object?>{...request.definition};
    final fieldResults = <Map<String, Object?>>[];
    final diagnostics = <Map<String, Object?>>[];
    final sourceName =
        (source.identity['name']! as Map<String, Object?>)['resolved'];
    final sourceDescription =
        (source.identity['description']! as Map<String, Object?>)['resolved'];
    targetFields['name'] = request.definition['name'] ?? sourceName;
    targetFields['description'] =
        request.definition['description'] ?? sourceDescription;
    fieldResults.add(
      _identityField(
        'name',
        overridden: request.definition.containsKey('name'),
        accepted: request.decisions.contains('map:name'),
        sourceValue: sourceName,
        targetValue: targetFields['name'],
        profile: source.profile,
      ),
    );
    fieldResults.add(
      _identityField(
        'description',
        overridden: request.definition.containsKey('description'),
        accepted: request.decisions.contains('map:description'),
        sourceValue: sourceDescription,
        targetValue: targetFields['description'],
        profile: source.profile,
      ),
    );
    final instructions = source.instructionText;
    final targetInstructionPath = targetHarness == AgentHarness.codex
        ? 'developer_instructions'
        : 'body';
    fieldResults.add(<String, Object?>{
      ..._field(
        'instructions',
        targetInstructionPath,
        'altered',
        source.profile,
      ),
      'evidence':
          'Instruction text is preserved, but ${source.form} authority changes to '
          '${targetHarness.name} $targetInstructionPath assembly; runtime equivalence is not claimed.',
      'textSha256': instructions == null
          ? null
          : sha256.convert(utf8.encode(instructions)).toString(),
    });

    final exported = targetSpec.exportCanonicalAgent(
      AgentExportRequest(
        canonical: sourceSpec.importNativeAgent(
          AgentImportRequest(
            fields: source.nativeFields,
            sourceForm: source.form,
            sourceProfile: source.profile,
            instructions: instructions,
          ),
        ),
        definition: request.definition,
        decisions: request.decisions,
        sourceProfile: source.profile,
      ),
    );
    fieldResults.addAll(exported.fields);
    diagnostics.addAll(exported.diagnostics);
    final referenceErrors = applyNativeReferenceMappings(
      targetFields,
      request.references,
      targetHarness,
    );
    final referenceEntries = request.references.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    final sourceAssociations = <String, Map<String, Object?>>{
      for (final reference in source.references)
        if (_associationKinds.contains(reference['kind']))
          '${reference['kind']}:${reference['name']}': reference,
    };
    final referenceKeys = <String>{
      ...sourceAssociations.keys,
      ...referenceEntries.map((entry) => entry.key),
    }.toList()..sort();
    for (final key in referenceKeys) {
      final mapping = request.references[key];
      final disclosed = sourceAssociations.containsKey(key);
      final removed = request.decisions.contains('reference:$key:remove');
      final error = mapping == null
          ? null
          : referenceErrors
                .where((candidate) => candidate.startsWith('$key:'))
                .firstOrNull;
      final removalConflict =
          removed &&
          mapping == null &&
          _targetDeclaresAssociation(targetFields, key, targetHarness);
      final outcome = !disclosed
          ? 'unresolved'
          : removalConflict
          ? 'unresolved'
          : mapping == null && removed
          ? 'omitted'
          : mapping == null || error != null
          ? 'unresolved'
          : 'altered';
      final separator = key.indexOf(':');
      final kind = separator <= 0 ? key : key.substring(0, separator);
      fieldResults.add(<String, Object?>{
        ..._field(
          'reference:$key',
          mapping == null ? null : 'reference:$kind:$mapping',
          outcome,
          source.profile,
        ),
        'evidence': !disclosed
            ? 'No disclosed source association $key; a mapping must bind to a '
                  'source declaration, not a guessed kind or name.'
            : removalConflict
            ? 'The removal decision conflicts with a target declaration that '
                  'still carries $key.'
            : mapping == null && removed
            ? 'Explicit association removal; the target does not carry the '
                  '$key source declaration.'
            : error ??
                  'Explicit reference mapping; equal names do not establish '
                      'equivalent content or enforcement.',
        'decision': mapping != null
            ? 'reference:$key'
            : removed
            ? 'reference:$key:remove'
            : null,
      });
    }
    for (final field in fieldResults.where(
      (field) =>
          field['outcome'] == 'unresolved' ||
          field['outcome'] == 'unrepresentable',
    )) {
      diagnostics.add(<String, Object?>{
        'code': 'CONVERSION_DECISION_REQUIRED',
        'category': 'product',
        'severity': 'error',
        'field': field['sourcePath'],
        'message':
            'Conversion requires an explicit mapping or field-specific omission for ${field['sourcePath']}.',
      });
    }
    if (source.hasErrors) {
      diagnostics.add(<String, Object?>{
        'code': 'SOURCE_VALIDATION_FAILED',
        'category': 'specification',
        'severity': 'error',
        'field': null,
        'message': 'The source must pass native inspection before conversion.',
      });
    }
    final authoringRequest = AuthoringRequest(
      operation: AuthoringOperation.compose,
      source: null,
      base: null,
      target: request.target,
      definition: targetFields,
      instructions: [?instructions],
      baseInstructions: 'replace',
      decisions: request.decisions,
      references: request.references,
      context: request.context,
    );
    final candidate = await authoring.plan(
      authoringRequest,
      options,
      showInstructions: showInstructions,
      allowManagedReplacement: true,
    );
    final unresolved = fieldResults.any(
      (field) =>
          field['outcome'] == 'unresolved' ||
          field['outcome'] == 'unrepresentable',
    );
    final planId =
        'agent-convert-${sha256.convert(utf8.encode(jsonEncode(canonicalJsonForHash(<String, Object?>{
          'candidatePlanId': candidate.result.data['planId'],
          'source': <String, Object?>{'profile': source.profile, 'form': source.form, 'definitionFile': source.definitionFile, 'binding': source.binding, 'nativeFields': source.nativeFields, 'instructionSha256': instructions == null ? null : sha256.convert(utf8.encode(instructions)).toString()},
          'target': request.target,
          'fields': fieldResults,
          'decisions': request.decisions.toList()..sort(),
          'references': request.references,
        }))))}';
    final data = <String, Object?>{
      ...candidate.result.data,
      'planId': planId,
      'ready':
          candidate.result.data['ready'] == true &&
          !unresolved &&
          !source.hasErrors,
      'sourceProfile': source.profile,
      'targetProfile': exported.targetProfile,
      'sourceForm': source.form,
      'targetForm': '${targetHarness.name}-agent-file',
      'sourceBinding': source.binding,
      'sourcePreserved': true,
      'fields': fieldResults,
      'parentPrerequisites': source.parentRequirements,
      'registration': 'separate-explicit-plan-required',
      'runtimeEquivalence': 'notVerified',
    };
    return ConversionPlan(
      result: LifecycleResult(
        command: 'agent convert',
        outcome: 'planned',
        data: data,
        diagnostics: <Map<String, Object?>>[
          ...diagnostics,
          ...candidate.result.diagnostics,
        ],
      ),
      authoring: candidate,
    );
  }

  Future<LifecycleResult> run(
    ConversionRequest request,
    LifecycleOptions options, {
    required bool apply,
    required String? planId,
    bool showInstructions = false,
  }) async {
    if (apply && options.dryRun) {
      throw MambaException('--apply and --dry-run conflict.');
    }
    final planned = await plan(
      request,
      options,
      showInstructions: showInstructions,
    );
    if (!apply || options.dryRun) return planned.result;
    if (planned.result.data['ready'] != true) {
      throw MambaException(
        'Conversion has unresolved fields or incomplete native readiness.',
        exitCode: 4,
      );
    }
    if (planId == null || planId != planned.result.data['planId']) {
      throw MambaException(
        'Conversion apply requires the current source-bound --plan-id.',
        exitCode: 4,
      );
    }
    if (!options.approved) {
      throw MambaException('Conversion apply requires --yes.', exitCode: 4);
    }
    // Publish the exact reconstructed candidate through protected staging and
    // the ordinary lifecycle engine instead of rebuilding a different proposal.
    final lifecycle = authoring.lifecycle;
    return lifecycle.withStagedCandidate(
      options: options,
      harness: planned.authoring.harness,
      destination: planned.authoring.destination,
      output: planned.authoring.output,
      content: planned.authoring.content,
      body: (candidate) async {
        if (base64Encode(_fileSystem.file(candidate).readAsBytesSync()) !=
            base64Encode(utf8.encode(planned.authoring.content))) {
          throw MambaException(
            'The staged conversion candidate changed before publication.',
            exitCode: 4,
          );
        }
        final inspection = inspectNativeAgentContent(
          content: planned.authoring.content,
          harness: planned.authoring.harness,
          definitionFile: planned.authoring.output,
        );
        if (inspection.hasErrors ||
            !_graph.analyzeInspection(inspection).ready) {
          throw MambaException(
            inspection.renderText(AgentOperation.validate),
            exitCode: 2,
          );
        }
        final applied = request.target['installationId'] == null
            ? await lifecycle.install(
                AgentInstallInput(
                  options: options,
                  source: candidate,
                  harness: planned.authoring.harness,
                  destination: planned.authoring.destination,
                  output: planned.authoring.output,
                ),
              )
            : await lifecycle.replace(
                LifecycleReplaceInput(
                  options: options,
                  installationId: request.target['installationId']! as String,
                  source: candidate,
                ),
                harness: planned.authoring.harness,
              );
        return LifecycleResult(
          command: 'agent convert',
          outcome: 'converted',
          data: <String, Object?>{
            ...applied.data,
            'planId': planned.result.data['planId'],
            'lifecycleOutcome': applied.outcome,
            'sourcePreserved': true,
          },
          diagnostics: applied.diagnostics,
        );
      },
    );
  }

  AgentInspectionReport _inspectSource(
    Map<String, Object?> source,
    LifecycleOptions options,
  ) {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    switch (source['kind']) {
      case 'native-file':
        return inspectNativeAgent(
          AgentInspectionInput(
            nativeFile: context.resolvePath(source['path']! as String),
            harness: AgentHarness.values.singleWhere(
              (value) => value.name == source['harness'],
            ),
            cwd: context.cwd,
          ),
          operation: AgentOperation.inspect,
          fileSystem: _fileSystem,
        );
      case 'codex-role':
        return CodexBindingInspection.read(
          configFile: context.resolvePath(source['configFile']! as String),
          workingDirectory: context.cwd,
          fileSystem: _fileSystem,
        ).inspectRole(source['roleKey']! as String);
      case 'managed-agent':
        return authoring.lifecycle.inspectManagedSource(
          options: options,
          installationId: source['installationId']! as String,
        );
    }
    throw StateError('Validated conversion source kind.');
  }

  Map<String, Object?> _identityField(
    String path, {
    required bool overridden,
    required bool accepted,
    required Object? sourceValue,
    required Object? targetValue,
    required String profile,
  }) {
    final changed = overridden && targetValue != sourceValue;
    return _field(
      path,
      path,
      !changed
          ? 'represented'
          : accepted
          ? 'altered'
          : 'unresolved',
      profile,
      decision: changed ? 'map:$path' : null,
    );
  }

  Map<String, Object?> _field(
    String? sourcePath,
    String? targetPath,
    String outcome,
    String profile, {
    String? decision,
  }) => <String, Object?>{
    'sourcePath': sourcePath,
    'targetPath': targetPath,
    'sourceProfile': profile,
    'outcome': outcome,
    'decision': decision,
  };
}
