import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import '../agent_inspection.dart';
import '../native_references.dart';
import '../skill_files.dart';
import 'agent_graph_service.dart';
import 'agent_lifecycle_service.dart';
import 'lifecycle_state_service.dart';
import 'parent_config_service.dart' show parseStrictJsonObject;

enum AuthoringOperation { create, clone, edit, compose }

final class AuthoringRequest {
  const AuthoringRequest({
    required this.operation,
    required this.source,
    required this.base,
    required this.target,
    required this.definition,
    required this.instructions,
    required this.baseInstructions,
    required this.decisions,
    required this.references,
    required this.context,
  });

  final AuthoringOperation operation;
  final Map<String, Object?>? source;
  final Map<String, Object?>? base;
  final Map<String, Object?> target;
  final Map<String, Object?> definition;
  final List<String> instructions;
  final String baseInstructions;
  final Set<String> decisions;
  final Map<String, String> references;
  final String context;
}

AuthoringRequest parseAuthoringRequest(
  String requestFile,
  String workingDirectory,
) {
  final path = p.normalize(
    p.isAbsolute(requestFile)
        ? requestFile
        : p.join(workingDirectory, requestFile),
  );
  if (skillEntityType(path, followLinks: false) != FileSystemEntityType.file) {
    throw MambaException('The operation request must be a regular file: $path');
  }
  final bytes = readBoundedSkillMarker(
    path,
    maxBytes: maxManagementDocumentBytes,
  );
  if (bytes.length > maxManagementDocumentBytes) {
    throw MambaException('The operation request exceeds 8 MiB.', exitCode: 3);
  }
  final Map<String, Object?> map;
  try {
    map = parseStrictJsonObject(utf8.decode(bytes, allowMalformed: false));
  } on FormatException catch (error) {
    throw MambaException('Invalid operation request: ${error.message}');
  }
  const envelopeKeys = <String>{
    'schemaVersion',
    'operation',
    'source',
    'base',
    'target',
    'context',
    'definition',
    'instructions',
    'baseInstructions',
    'decisions',
    'references',
  };
  _knownKeys(map, envelopeKeys, 'operation request');
  if (map['schemaVersion'] != 1) {
    throw MambaException('Operation request schemaVersion must be 1.');
  }
  final operation = AuthoringOperation.values.where(
    (value) => value.name == map['operation'],
  );
  if (operation.length != 1) {
    throw MambaException(
      'Unsupported authoring operation: ${map['operation']}',
    );
  }
  final target = _object(map['target'], 'target');
  _knownKeys(target, const {
    'harness',
    'output',
    'destination',
    'installationId',
  }, 'target');
  final harness = target['harness'];
  if (harness is! String ||
      AgentHarness.values.every((value) => value.name != harness)) {
    throw MambaException('Target harness must be claude, codex, or pi.');
  }
  for (final key in const ['output', 'installationId']) {
    final value = target[key];
    if (value != null && (value is! String || value.trim().isEmpty)) {
      throw MambaException('Target $key must be a nonblank string.');
    }
  }
  final destination = target['destination'];
  if (destination != null &&
      destination != 'native' &&
      destination != 'shared') {
    throw MambaException('Target destination must be native or shared.');
  }
  final context = _object(map['context'], 'context');
  _knownKeys(context, const {'workingDirectory'}, 'context');
  final working = context['workingDirectory'];
  if (working is! String || working.trim().isEmpty) {
    throw MambaException('Context workingDirectory must be a nonblank string.');
  }
  final definition = _object(
    map['definition'] ?? const <String, Object?>{},
    'definition',
  );
  for (final key in definition.keys) {
    if (key.trim().isEmpty) {
      throw MambaException('Definition field names must not be blank.');
    }
  }
  final rawInstructions = map['instructions'] ?? const <Object?>[];
  if (rawInstructions is! List<Object?>) {
    throw MambaException('instructions must be an ordered list of strings.');
  }
  final instructions = <String>[];
  for (final part in rawInstructions) {
    if (part is! String || part.isEmpty) {
      throw MambaException('Every instruction part must be a nonempty string.');
    }
    instructions.add(part);
  }
  final baseInstructions = map['baseInstructions'] ?? 'include';
  if (baseInstructions is! String ||
      !const {'include', 'retain', 'replace'}.contains(baseInstructions)) {
    throw MambaException(
      'baseInstructions must be include, retain, or replace.',
    );
  }
  if (baseInstructions == 'retain' && instructions.isNotEmpty) {
    throw MambaException(
      'baseInstructions retain cannot be combined with explicit parts.',
    );
  }
  final rawDecisions = map['decisions'] ?? const <Object?>[];
  if (rawDecisions is! List<Object?> ||
      rawDecisions.any((value) => value is! String || (value).trim().isEmpty)) {
    throw MambaException(
      'decisions must be a list of nonblank field-specific identifiers.',
    );
  }
  final decisions = rawDecisions.cast<String>().toSet();
  if (decisions.length != rawDecisions.length) {
    throw MambaException('decisions must not contain duplicates.');
  }
  final rawReferences = _object(
    map['references'] ?? const <String, Object?>{},
    'references',
  );
  final references = <String, String>{};
  for (final entry in rawReferences.entries) {
    if (entry.value is! String || (entry.value! as String).trim().isEmpty) {
      throw MambaException(
        'Reference mappings must have nonblank string targets.',
      );
    }
    references[entry.key] = entry.value! as String;
  }
  final source = map['source'] == null ? null : _source(map['source']);
  final base = map['base'] == null ? null : _source(map['base']);
  if (operation.single == AuthoringOperation.compose &&
      source != null &&
      base != null) {
    throw MambaException(
      'Compose accepts one optional source or base, not both.',
    );
  }
  if (operation.single == AuthoringOperation.create &&
      (source != null || base != null)) {
    throw MambaException(
      'Create uses explicit definition fields, not source or base.',
    );
  }
  if (operation.single != AuthoringOperation.create &&
      operation.single != AuthoringOperation.compose &&
      source == null) {
    throw MambaException('${operation.single.name} requires a source.');
  }
  _rejectCredentialLiterals(definition);
  return AuthoringRequest(
    operation: operation.single,
    source: source,
    base: base,
    target: target,
    definition: definition,
    instructions: instructions,
    baseInstructions: baseInstructions,
    decisions: decisions,
    references: references,
    context: working,
  );
}

Map<String, Object?> _source(Object? value) {
  final source = _object(value, 'source');
  _knownKeys(source, const {
    'kind',
    'path',
    'harness',
    'configFile',
    'roleKey',
    'installationId',
  }, 'source');
  final kind = source['kind'];
  if (kind != 'native-file' &&
      kind != 'codex-role' &&
      kind != 'managed-agent') {
    throw MambaException(
      'Source kind must be native-file, codex-role, or managed-agent.',
    );
  }
  if (kind == 'native-file') {
    if (source['path'] is! String ||
        (source['path']! as String).trim().isEmpty) {
      throw MambaException('A native-file source requires a nonblank path.');
    }
    if (source['harness'] is! String ||
        AgentHarness.values.every((item) => item.name != source['harness'])) {
      throw MambaException(
        'A native-file source requires an explicit harness.',
      );
    }
  } else if (kind == 'codex-role') {
    if (source['configFile'] is! String || source['roleKey'] is! String) {
      throw MambaException(
        'A codex-role source requires configFile and roleKey.',
      );
    }
  } else if (source['installationId'] is! String ||
      (source['installationId']! as String).trim().isEmpty) {
    throw MambaException('A managed-agent source requires installationId.');
  }
  return source;
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map<String, Object?>) {
    throw MambaException('$label must be an object.');
  }
  return value;
}

void _knownKeys(Map<String, Object?> map, Set<String> allowed, String label) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw MambaException('Unknown $label field: $key');
    }
  }
}

void _rejectCredentialLiterals(Object? value, [String path = 'definition']) {
  if (value is Map<String, Object?>) {
    for (final entry in value.entries) {
      final key = entry.key.toLowerCase();
      if (entry.value is String &&
          (key.contains('password') ||
              key.contains('secret') ||
              key.contains('token') ||
              key.contains('credential')) &&
          !key.endsWith('_env') &&
          !key.endsWith('reference')) {
        throw MambaException(
          'New credential literals are not accepted at $path.${entry.key}.',
          exitCode: 4,
        );
      }
      _rejectCredentialLiterals(entry.value, '$path.${entry.key}');
    }
  } else if (value is List<Object?>) {
    for (var index = 0; index < value.length; index++) {
      _rejectCredentialLiterals(value[index], '$path[$index]');
    }
  }
}

final class AuthoringPlan {
  const AuthoringPlan({
    required this.result,
    required this.content,
    required this.harness,
    required this.output,
    required this.destination,
    required this.installationId,
  });

  final LifecycleResult result;
  final String content;
  final AgentHarness harness;
  final String output;
  final AgentDestination destination;
  final String? installationId;
}

interface class AgentAuthoringService {
  AgentAuthoringService({
    AgentLifecycleService? lifecycle,
    AgentGraphService? graph,
  }) : lifecycle = lifecycle ?? AgentLifecycleService(),
       _graph = graph ?? AgentGraphService();

  final AgentLifecycleService lifecycle;
  final AgentGraphService _graph;

  Future<AuthoringPlan> plan(
    AuthoringRequest request,
    LifecycleOptions options, {
    bool showInstructions = false,
    bool allowManagedReplacement = false,
  }) async {
    final context = LifecycleContext.resolve(options);
    final working = context.resolvePath(request.context);
    if (!p.equals(working, context.cwd)) {
      throw MambaException(
        'Request workingDirectory must agree with --cwd.',
        exitCode: 1,
      );
    }
    final harness = AgentHarness.values.singleWhere(
      (value) => value.name == request.target['harness'],
    );
    final destination = request.target['destination'] == 'shared'
        ? AgentDestination.shared
        : AgentDestination.native;
    if (destination == AgentDestination.shared &&
        (harness != AgentHarness.pi ||
            context.scope != LifecycleScope.project)) {
      throw MambaException(
        'Shared Agent targets are supported only for common-Pi project files.',
        exitCode: 4,
      );
    }
    final source = request.source == null
        ? null
        : _inspectSource(request.source!, options);
    final base = request.base == null
        ? null
        : _inspectSource(request.base!, options);
    if (base != null && base.profile != source?.profile && source != null) {
      throw MambaException(
        'The base and source must use the same native profile.',
        exitCode: 2,
      );
    }
    if (base != null && base.profile != _profile(harness)) {
      throw MambaException(
        'The base must match the target native profile.',
        exitCode: 2,
      );
    }
    final inherited = source ?? base;
    if (inherited != null && inherited.profile != _profile(harness)) {
      throw MambaException(
        'Authoring requires a same-profile source or base; use agent convert for a different target.',
        exitCode: 2,
      );
    }
    final fields = <String, Object?>{
      if (inherited != null) ..._nativeFields(inherited),
      ...request.definition,
    };
    final diagnostics = <Map<String, Object?>>[];
    for (final error in applyNativeReferenceMappings(
      fields,
      request.references,
      harness,
    )) {
      diagnostics.add(_finding('REFERENCE_MAPPING', 'references', error));
    }
    if (request.operation == AuthoringOperation.compose && inherited != null) {
      for (final entry in request.definition.entries) {
        final previous = inherited.nativeFields[entry.key];
        if (previous != null &&
            jsonEncode(previous) != jsonEncode(entry.value) &&
            !request.decisions.contains('field:${entry.key}')) {
          diagnostics.add(
            _finding(
              'FIELD_CONFLICT',
              entry.key,
              'The base and explicit ${entry.key} selections conflict; '
                  'resolve with field:${entry.key}.',
            ),
          );
        }
      }
    }
    final name = _resolved(fields, 'name', inherited, 'name');
    final description = _resolved(
      fields,
      'description',
      inherited,
      'description',
    );
    if (name != null) fields['name'] = name;
    if (description != null) fields['description'] = description;
    if (name is! String || name.trim().isEmpty) {
      diagnostics.add(
        _finding(
          'NAME_REQUIRED',
          'name',
          'A nonblank target name is required.',
        ),
      );
    }
    if (description is! String ||
        (harness != AgentHarness.claude && description.trim().isEmpty)) {
      diagnostics.add(
        _finding(
          'DESCRIPTION_REQUIRED',
          'description',
          'A target description is required.',
        ),
      );
    }
    if (harness == AgentHarness.pi) {
      final model = fields['model'];
      if (model is! String || !_qualifiedModel(model)) {
        diagnostics.add(
          _finding(
            'MODEL_REQUIRED',
            'model',
            'Common Pi requires an explicit provider/model-id.',
          ),
        );
      }
      final tools = fields['tools'];
      if (tools is! String || tools.trim().isEmpty) {
        diagnostics.add(
          _finding(
            'TOOLS_REQUIRED',
            'tools',
            'Common Pi requires explicit shared builtin tools.',
          ),
        );
      }
    }
    if (harness == AgentHarness.pi) {
      const providerOnly = <String>{
        'skills',
        'extensions',
        'memory',
        'excludeTools',
        'systemPromptMode',
        'inheritProjectContext',
        'inheritSkills',
        'async',
        'disallowed_tools',
        'prompt_mode',
        'inherit_context',
        'run_in_background',
      };
      for (final key in fields.keys.where(providerOnly.contains)) {
        diagnostics.add(
          _finding(
            'PROVIDER_ONLY_FIELD',
            key,
            'The common Pi profile cannot emit provider-private field $key.',
          ),
        );
      }
    }
    final parts = <String>[];
    if (request.baseInstructions != 'replace' &&
        inherited?.instructionText != null) {
      if (request.instructions.isEmpty ||
          request.baseInstructions == 'include') {
        parts.add(inherited!.instructionText!);
      }
    }
    parts.addAll(request.instructions);
    if (request.operation == AuthoringOperation.clone &&
        request.instructions.isNotEmpty) {
      throw MambaException(
        'Clone preserves source instructions; use compose or edit to change them.',
      );
    }
    final instructions = parts.join('\n');
    if (instructions.trim().isEmpty) {
      diagnostics.add(
        _finding(
          'INSTRUCTIONS_REQUIRED',
          'instructions',
          'Target instructions must not be empty.',
        ),
      );
    }
    if (harness == AgentHarness.codex) {
      fields['developer_instructions'] = instructions;
    }
    final content = _serialize(harness, fields, instructions);
    final candidateBytes = utf8.encode(content);
    if (candidateBytes.length > 1048576) {
      throw MambaException(
        'The proposed Agent definition exceeds 1 MiB.',
        exitCode: 3,
      );
    }
    final output = _targetOutput(
      request,
      context,
      harness,
      destination,
      name is String ? name : null,
    );
    lifecycle.validateTarget(
      options: options,
      harness: harness,
      destination: destination,
      output: output,
    );
    final candidateInspection = inspectNativeAgentContent(
      content: content,
      harness: harness,
      definitionFile: output,
      showInstructions: showInstructions,
    );
    diagnostics.addAll([
      for (final diagnostic in candidateInspection.diagnostics)
        diagnostic.toJson(),
    ]);
    for (final diagnostic in candidateInspection.diagnostics) {
      final field = diagnostic.field;
      if (_requiresFieldDecision(diagnostic.code) &&
          field != null &&
          !request.decisions.contains('field:$field')) {
        diagnostics.add(
          _finding(
            'FIELD_DECISION_REQUIRED',
            field,
            'Unknown or source-only field $field requires an explicit '
                'field:$field decision.',
          ),
        );
      }
    }
    if (inherited != null) {
      diagnostics.addAll(
        _referenceDecisionFindings(
          inherited.references,
          candidateInspection.references,
          request,
        ),
      );
    }
    final graph = _graph.analyzeInspection(candidateInspection);
    final installationId = request.target['installationId'] as String?;
    if (request.operation == AuthoringOperation.edit) {
      if (installationId == null) {
        throw MambaException('Edit requires target.installationId.');
      }
      if (request.source?['kind'] != 'managed-agent' ||
          request.source?['installationId'] != installationId ||
          inherited?.definitionFile == null ||
          !p.equals(output, inherited!.definitionFile!)) {
        throw MambaException(
          'Edit source, target installation ID, and recorded location must agree.',
          exitCode: 4,
        );
      }
    }
    if (installationId != null &&
        request.operation != AuthoringOperation.edit &&
        !allowManagedReplacement) {
      throw MambaException(
        'Only edit or conversion can select managed replacement; clone and create require a separate target.',
        exitCode: 4,
      );
    }
    if (installationId != null) {
      final record = lifecycle.state.recordById(context, installationId);
      if (record.kind != ArtifactKind.agentFile ||
          record.nativeProfile != harness.name ||
          !p.equals(record.location, output) ||
          lifecycle.state.verify(record) != ModificationStatus.unchanged) {
        throw MambaException(
          'The target installation ID, native profile, unchanged baseline, and reviewed output must agree.',
          exitCode: 4,
        );
      }
    }
    final expectedExtension = harness == AgentHarness.codex ? '.toml' : '.md';
    if (p.extension(output) != expectedExtension) {
      diagnostics.add(
        _finding(
          'TARGET_EXTENSION',
          'target.output',
          'The ${harness.name} target requires the exact lowercase $expectedExtension extension.',
        ),
      );
    }
    final targetObservation = _observeTarget(output);
    if (targetObservation == 'occupied' && installationId == null) {
      diagnostics.add(
        _finding(
          'TARGET_OCCUPIED',
          'target.output',
          'The separate target is occupied; explicit managed replacement or adoption is required.',
        ),
      );
    }
    final sourceObservation = inherited == null
        ? null
        : _sourceObservation(inherited);
    final planIdentity = <String, Object?>{
      'operation': request.operation.name,
      'harness': harness.name,
      'destination': destination.name,
      'output': output,
      'installationId': installationId,
      'definition': fields,
      'instructionParts': [for (final part in parts) utf8.encode(part).length],
      'decisions': request.decisions.toList()..sort(),
      'references': request.references,
      'source': sourceObservation,
      'target': targetObservation,
      'graph': graph.toJson(),
    };
    final planId =
        'agent-plan-${sha256.convert(utf8.encode(jsonEncode(_canonicalJson(planIdentity))))}';
    final ready =
        graph.ready &&
        diagnostics.every((diagnostic) => diagnostic['severity'] != 'error') &&
        (targetObservation != 'occupied' || installationId != null);
    final data = <String, Object?>{
      'planId': planId,
      'ready': ready,
      'writes': false,
      'profile': _profile(harness),
      'target': <String, Object?>{
        'output': output,
        'destination': destination.name,
        'installationId': installationId,
      },
      'source': sourceObservation,
      'instructionParts': [for (final part in parts) utf8.encode(part).length],
      'instructionByteLength': utf8.encode(instructions).length,
      'instructionSha256': sha256.convert(utf8.encode(instructions)).toString(),
      'candidateByteLength': candidateBytes.length,
      'candidateSha256': sha256.convert(candidateBytes).toString(),
      'references': candidateInspection.references,
      'capabilities': candidateInspection.capabilities,
      'parentRequirements': candidateInspection.parentRequirements,
      'graph': graph.toJson(),
      'decisions': request.decisions.toList()..sort(),
      if (showInstructions) 'instructions': instructions,
    };
    return AuthoringPlan(
      result: LifecycleResult(
        command: 'agent ${request.operation.name}',
        outcome: 'planned',
        data: data,
        diagnostics: diagnostics,
      ),
      content: content,
      harness: harness,
      output: output,
      destination: destination,
      installationId: installationId,
    );
  }

  Future<LifecycleResult> run(
    AuthoringRequest request,
    LifecycleOptions options, {
    required bool apply,
    required String? planId,
    bool showInstructions = false,
    bool allowManagedReplacement = false,
  }) async {
    if (apply && options.dryRun) {
      throw MambaException('--apply and --dry-run conflict.');
    }
    final planned = await plan(
      request,
      options,
      showInstructions: showInstructions,
      allowManagedReplacement: allowManagedReplacement,
    );
    if (!apply || options.dryRun) return planned.result;
    if (planned.result.data['ready'] != true) {
      throw MambaException(
        'The reviewed proposal has unresolved native fields or decisions.',
        exitCode: 4,
      );
    }
    if (planId == null || planId != planned.result.data['planId']) {
      throw MambaException(
        'Apply requires the current --plan-id; stale approval is refused.',
        exitCode: 4,
      );
    }
    if (!options.approved) {
      throw MambaException('Apply requires --yes.', exitCode: 4);
    }
    return lifecycle.withStagedCandidate(
      options: options,
      harness: planned.harness,
      destination: planned.destination,
      output: planned.output,
      content: planned.content,
      body: (candidate) async {
        if (base64Encode(File(candidate).readAsBytesSync()) !=
            base64Encode(utf8.encode(planned.content))) {
          throw MambaException(
            'The staged candidate changed before publication.',
            exitCode: 4,
          );
        }
        final inspection = inspectNativeAgentContent(
          content: planned.content,
          harness: planned.harness,
          definitionFile: planned.output,
        );
        if (inspection.hasErrors ||
            !_graph.analyzeInspection(inspection).ready) {
          throw MambaException(
            inspection.renderText(AgentOperation.validate),
            exitCode: 2,
          );
        }
        final applied = switch (planned.installationId != null) {
          true => await lifecycle.replace(
            LifecycleReplaceInput(
              options: options,
              installationId: planned.installationId!,
              source: candidate,
            ),
            harness: planned.harness,
          ),
          false => await lifecycle.install(
            AgentInstallInput(
              options: options,
              source: candidate,
              harness: planned.harness,
              destination: planned.destination,
              output: planned.output,
            ),
          ),
        };
        return LifecycleResult(
          command: 'agent ${request.operation.name}',
          outcome: applied.outcome,
          data: <String, Object?>{
            ...applied.data,
            'planId': planned.result.data['planId'],
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
    final context = LifecycleContext.resolve(options);
    final kind = source['kind'];
    if (kind == 'native-file') {
      return inspectNativeAgent(
        AgentInspectionInput(
          nativeFile: context.resolvePath(source['path']! as String),
          harness: AgentHarness.values.singleWhere(
            (value) => value.name == source['harness'],
          ),
          cwd: context.cwd,
        ),
        operation: AgentOperation.inspect,
      );
    }
    if (kind == 'codex-role') {
      return CodexBindingInspection.read(
        configFile: context.resolvePath(source['configFile']! as String),
        workingDirectory: context.cwd,
      ).inspectRole(source['roleKey']! as String);
    }
    return lifecycle.inspectManagedSource(
      options: options,
      installationId: source['installationId']! as String,
    );
  }

  String _targetOutput(
    AuthoringRequest request,
    LifecycleContext context,
    AgentHarness harness,
    AgentDestination destination,
    String? name,
  ) {
    final selected = request.target['output'] as String?;
    if (selected != null) return context.resolvePath(selected);
    final safeName = name;
    if (safeName == null ||
        safeName.trim().isEmpty ||
        safeName.contains('/') ||
        safeName.contains('\\')) {
      throw MambaException(
        'An explicit target output is required until a valid name is available.',
      );
    }
    if (destination == AgentDestination.shared) {
      if (harness != AgentHarness.pi ||
          context.scope != LifecycleScope.project) {
        throw MambaException(
          'The selected target destination is not supported.',
          exitCode: 4,
        );
      }
      return p.join(context.piSharedAgentsRoot(), '$safeName.md');
    }
    final root = switch (harness) {
      AgentHarness.claude =>
        context.scope == LifecycleScope.project
            ? context.claudeAgentsRoot()
            : p.join(context.claudeConfigRoot(), 'agents'),
      AgentHarness.codex =>
        context.scope == LifecycleScope.project
            ? context.codexAgentsRoot()
            : p.join(context.codexRoot(), 'agents'),
      AgentHarness.pi => context.piAgentsRoot(),
    };
    return p.join(
      root,
      '$safeName${harness == AgentHarness.codex ? '.toml' : '.md'}',
    );
  }
}

Object? _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJson(value[key]),
    };
  }
  if (value is List) {
    return <Object?>[for (final entry in value) _canonicalJson(entry)];
  }
  return value;
}

Map<String, Object?> _finding(String code, String field, String message) =>
    <String, Object?>{
      'code': code,
      'category': 'product',
      'severity': 'error',
      'field': field,
      'message': message,
    };

Object? _resolved(
  Map<String, Object?> fields,
  String key,
  AgentInspectionReport? source,
  String identity,
) {
  if (fields.containsKey(key)) return fields[key];
  final value = source?.identity[identity] as Map<String, Object?>?;
  return value?['resolved'];
}

Map<String, Object?> _nativeFields(AgentInspectionReport report) =>
    <String, Object?>{
      for (final entry in report.nativeFields.entries)
        if (entry.key != 'developer_instructions') entry.key: entry.value,
    };

List<Map<String, Object?>> _referenceDecisionFindings(
  List<Map<String, Object?>> source,
  List<Map<String, Object?>> target,
  AuthoringRequest request,
) {
  Map<String, int> counts(Iterable<Map<String, Object?>> references) {
    final result = <String, int>{};
    for (final reference in references) {
      final key = '${reference['kind']}:${reference['name']}';
      result[key] = (result[key] ?? 0) + 1;
    }
    return result;
  }

  Map<String, int> difference(
    Iterable<Map<String, Object?>> left,
    Iterable<Map<String, Object?>> right,
  ) {
    final result = counts(left);
    for (final entry in counts(right).entries) {
      final remaining = (result[entry.key] ?? 0) - entry.value;
      if (remaining > 0) {
        result[entry.key] = remaining;
      } else {
        result.remove(entry.key);
      }
    }
    return result;
  }

  final removed = difference(source, target);
  final added = difference(target, source);

  final findings = <Map<String, Object?>>[];
  void requireDecision(String decision, String impact) {
    if (!request.decisions.contains(decision)) {
      findings.add(
        _finding(
          'REFERENCE_DECISION_REQUIRED',
          'references',
          '$impact requires the explicit $decision decision.',
        ),
      );
    }
  }

  void consume(Map<String, int> impacts, String key) {
    final remaining = impacts[key] ?? 0;
    if (remaining <= 1) {
      impacts.remove(key);
    } else {
      impacts[key] = remaining - 1;
    }
  }

  for (final mapping in request.references.entries) {
    final separator = mapping.key.indexOf(':');
    if (separator <= 0) continue;
    final kind = mapping.key.substring(0, separator);
    final targetKey = '$kind:${mapping.value}';
    if ((removed[mapping.key] ?? 0) > 0 && (added[targetKey] ?? 0) > 0) {
      final decision = 'reference:${mapping.key}:${mapping.value}';
      requireDecision(decision, 'Changing ${mapping.key} to $targetKey');
      consume(removed, mapping.key);
      consume(added, targetKey);
    }
  }
  for (final sourceKey in removed.keys.toList()..sort()) {
    final separator = sourceKey.indexOf(':');
    final kind = sourceKey.substring(0, separator);
    for (final targetKey in added.keys.toList()..sort()) {
      if (!targetKey.startsWith('$kind:')) continue;
      final targetName = targetKey.substring(kind.length + 1);
      final decision = 'reference:$sourceKey:$targetName';
      if (!request.decisions.contains(decision)) continue;
      consume(removed, sourceKey);
      consume(added, targetKey);
      break;
    }
  }
  for (final key in removed.keys.toList()..sort()) {
    requireDecision('reference:$key:remove', 'Removing $key');
  }
  for (final key in added.keys.toList()..sort()) {
    requireDecision('reference:$key:add', 'Adding $key');
  }
  return findings;
}

bool _requiresFieldDecision(String code) => const <String>{
  'UNKNOWN_FIELD',
  'SOURCE_ONLY_FIELD',
  'EXPERIMENTAL_UNKNOWN_FIELD',
  'FEATURE_UNKNOWN',
  'SKILL_CONFIG_UNKNOWN',
  'SKILLS_BUNDLED_UNKNOWN',
  'SKILLS_UNKNOWN',
}.contains(code);

String _profile(AgentHarness harness) => switch (harness) {
  AgentHarness.claude => 'claude-agent-native-v1',
  AgentHarness.codex => 'codex-agent-native-v1',
  AgentHarness.pi => 'pi-agent-common-v1',
};

bool _qualifiedModel(String value) {
  final slash = value.indexOf('/');
  return slash > 0 &&
      slash < value.length - 1 &&
      !RegExp(r'\s').hasMatch(value) &&
      value != 'inherit' &&
      !value.substring(slash + 1).contains(':');
}

String _observeTarget(String path) {
  final type = skillEntityType(path, followLinks: false);
  return type == FileSystemEntityType.notFound ? 'absent' : 'occupied';
}

Map<String, Object?> _sourceObservation(AgentInspectionReport report) =>
    <String, Object?>{
      'form': report.form,
      'profile': report.profile,
      'definitionFile': report.definitionFile,
      'binding': report.binding,
      'identity': report.identity,
      'validation': report.validationStatus.wireName,
      'instructionSha256': report.instructionText == null
          ? null
          : sha256.convert(utf8.encode(report.instructionText!)).toString(),
      'references': report.references,
    };

String _serialize(
  AgentHarness harness,
  Map<String, Object?> fields,
  String instructions,
) {
  final entries = fields.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  if (harness == AgentHarness.codex) {
    return '${entries.map((entry) => '${entry.key} = ${_tomlValue(entry.value)}').join('\n')}\n';
  }
  final frontmatter = entries
      .map((entry) => '${entry.key}: ${_yamlValue(entry.value)}')
      .join('\n');
  return '---\n$frontmatter\n---\n$instructions';
}

String _yamlValue(Object? value) => jsonEncode(value);

String _tomlValue(Object? value) {
  if (value == null ||
      value is String ||
      value is num ||
      value is bool ||
      value is List<Object?>) {
    return jsonEncode(value);
  }
  if (value is Map<String, Object?>) {
    return '{ ${value.entries.map((entry) => '${entry.key} = ${_tomlValue(entry.value)}').join(', ')} }';
  }
  throw MambaException(
    'Unsupported native value type in proposed output.',
    exitCode: 2,
  );
}
