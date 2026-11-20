import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../agent_inspection.dart';
import '../authoring/authoring_inputs.dart';
import '../authoring/authoring_profiles.dart';
import '../authoring/package_manifest.dart';
import '../harness/harness_catalog.dart';
import '../native_references.dart';
import '../prompt_resource_path_scanner.dart';
import '../skill_files.dart';
import 'agent_authoring_service.dart'
    show authoringReferenceDecisionFindings, canonicalJsonForHash;
import 'agent_graph_service.dart';
import 'lifecycle_state_service.dart';
import 'prompt_inspection_service.dart';

const _maxMarkerBytes = 1048576;

/// The Prompt declarations that the Prompt to Agent mechanism change covers.
const _promptMechanismFields = <String>{
  'disable-model-invocation',
  'user-invocable',
  'argument-hint',
  'arguments',
};

/// The ownership a reviewed plan would establish.
///
/// A new output is author-only unless management is requested explicitly and
/// the requested form and location support it.
enum AuthoringOwnership { authorOnly, managedRequested, managedReplacement }

/// A read-only authoring plan.
///
/// The plan carries the proposed native content, the reviewed observations and
/// a stable identity. Planning writes nothing: no draft, no staging entry, no
/// journal and no installation record.
final class AuthoringPlan {
  const AuthoringPlan({
    required this.planId,
    required this.ready,
    required this.operation,
    required this.kind,
    required this.profile,
    required this.ownership,
    required this.output,
    required this.diagnostics,
    required this.data,
    required this.identity,
    this.candidate,
    this.sidecar,
    this.conversion,
  });

  final String planId;
  final bool ready;
  final AuthoringOperation operation;
  final AuthoringKind kind;
  final AuthoringProfile profile;
  final AuthoringOwnership ownership;
  final String? output;

  /// The proposed native content. It is never written by planning.
  final String? candidate;

  /// The proposed native sidecar content, when the form has one.
  final String? sidecar;

  /// The reviewed conversion of the plan, when the operation converts.
  final ConversionDirection? conversion;

  final List<Map<String, Object?>> diagnostics;
  final Map<String, Object?> data;

  /// The identity that produced [planId].
  final Map<String, Object?> identity;
}

/// Builds read-only authoring plans from shared native inputs.
///
/// The service never publishes, adopts or installs anything. It resolves the
/// selected source, renders the proposed native content, applies the shared
/// ownership and placement rules and records the reviewed observations in a
/// stable plan identity.
interface class AuthoringPlanService {
  AuthoringPlanService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    PromptInspectionService? prompts,
    LifecycleStateService? state,
    AgentGraphService? graph,
    this.standardInput,
  }) : _fileSystem = fileSystem,
       _prompts = prompts ?? PromptInspectionService(fs: fileSystem),
       _state = state ?? LifecycleStateService(io: LifecycleIO(fs: fileSystem)),
       _graph = graph ?? AgentGraphService(fileSystem: fileSystem);

  final fslib.FileSystem _fileSystem;
  final PromptInspectionService _prompts;
  final LifecycleStateService _state;
  final AgentGraphService _graph;

  /// Reads the explicitly selected standard input body.
  ///
  /// A null reader means standard input was not supplied. An unattended plan
  /// never waits for a reader that the caller did not provide.
  final Future<String> Function()? standardInput;

  /// Builds the read-only plan for the selected inputs.
  Future<AuthoringPlan> plan(
    AuthoringInputs inputs,
    LifecycleOptions options, {
    bool showInstructions = false,
  }) async {
    final context = LifecycleContext.resolve(options, fileSystem: _fileSystem);
    final diagnostics = <Map<String, Object?>>[];
    void error(String code, String field, String message) {
      diagnostics.add(<String, Object?>{
        'code': code,
        'category': 'product',
        'severity': 'error',
        'field': field,
        'message': message,
      });
    }

    final sourceContext = _sourceContext(inputs, context);
    final source = await _resolveSource(inputs, sourceContext);
    final body = await _resolveBody(inputs, context);
    if (inputs.scope != context.scope) {
      error(
        'SCOPE_MISMATCH',
        'scope',
        'The selected scope does not agree with the resolved lifecycle scope.',
      );
    }
    final assessment = _assessSourceFields(inputs, source, error);
    _reportSourceDiagnostics(inputs, source, error);
    final fields = _mergeFields(inputs, source, assessment.preserved, error);
    final intents = _fieldIntents(inputs);
    final composed = _composeBody(inputs, source, body);
    var placement = _resolvePlacement(
      inputs,
      context,
      fields,
      source,
      sourceContext,
    );
    final effectiveConversion = _effectiveConversion(inputs, source, error);
    final conversion = _analyzeConversion(
      inputs,
      context,
      source,
      fields,
      error,
      effectiveConversion,
    );
    final adjusted = conversion.placement;
    if (adjusted != null) placement = adjusted;
    final ownership = _resolveOwnership(
      inputs,
      context,
      placement,
      source,
      error,
      effectiveConversion,
    );
    final rendered = _render(
      inputs,
      source,
      fields,
      composed,
      placement,
      error,
    );
    final targetObservation = _observeTarget(placement, source, inputs);
    if (targetObservation == 'occupied') {
      error(
        'TARGET_OCCUPIED',
        'target.output',
        'The target location is occupied; a new output never takes over an '
            'existing entry.',
      );
    }
    final observations = <String>[
      if (source?.scope != null && source!.scope != inputs.scope)
        'crossScopeTransition',
    ];
    final roleDelegation = <String, Object?>{
      ...rendered.roleDelegation,
      ...conversion.roleDelegation,
    };
    final identity = <String, Object?>{
      'operation': inputs.operation.name,
      'kind': inputs.kind.name,
      'profile': inputs.profile.name,
      'scope': context.scope.name,
      'conversion': effectiveConversion?.name,
      'source': source == null
          ? null
          : <String, Object?>{
              'path': source.path,
              'form': source.form?.name,
              'installationId': source.installationId,
              'scope': source.scope?.name,
              'artifactKind': source.artifactKind?.wireName,
              'profile': source.agent == null
                  ? null
                  : _sourceProfile(inputs).name,
              'fields': canonicalJsonForHash(source.fields),
              'bodySha256': _digest(source.body),
              'markerSha256': source.markerSha256,
              'membersDigest': source.members?.digest,
            },
      'target': <String, Object?>{
        'output': placement.output,
        'root': placement.root,
        'form': placement.form,
        'sidecar': placement.sidecar,
        'directory': placement.directory,
        'observation': targetObservation,
      },
      'ownership': ownership.name,
      'fields': canonicalJsonForHash(fields),
      'fieldIntents': canonicalJsonForHash(intents),
      'body': <String, Object?>{
        'sha256': _digest(composed),
        'byteLength': utf8.encode(composed).length,
      },
      'decisions': inputs.decisions.toList()..sort(),
      'references': canonicalJsonForHash(inputs.references),
      'roleDelegation': canonicalJsonForHash(roleDelegation),
      'referenceChoices': canonicalJsonForHash(rendered.referenceChoices),
      'observations': observations,
      'sourceRemovalRequired': conversion.sourceRemovalRequired,
    };
    final planId =
        'authoring-plan-${sha256.convert(utf8.encode(jsonEncode(canonicalJsonForHash(identity))))}';
    final ready = diagnostics.every(
      (diagnostic) => diagnostic['severity'] != 'error',
    );
    final data = <String, Object?>{
      'planId': planId,
      'ready': ready,
      'writes': false,
      'operation': inputs.operation.name,
      'kind': inputs.kind.name,
      'profile': inputs.profile.name,
      'scope': context.scope.name,
      'ownership': ownership.name,
      'conversion': effectiveConversion?.name,
      'target': <String, Object?>{
        'output': placement.output,
        'root': placement.root,
        'form': placement.form,
        'sidecar': placement.sidecar,
        'directory': placement.directory,
        'observation': targetObservation,
      },
      'source': source == null
          ? null
          : <String, Object?>{
              'path': source.path,
              'form': source.form?.name,
              'installationId': source.installationId,
              'scope': source.scope?.name,
              'profile': source.agent == null
                  ? null
                  : _sourceProfile(inputs).name,
              'bodySha256': _digest(source.body),
              'markerSha256': source.markerSha256,
              'membersDigest': source.members?.digest,
              'memberCount': source.members?.entries.length,
            },
      'fields': canonicalJsonForHash(fields),
      'fieldIntents': canonicalJsonForHash(intents),
      'body': <String, Object?>{
        'sha256': _digest(composed),
        'byteLength': utf8.encode(composed).length,
      },
      'decisions': inputs.decisions.toList()..sort(),
      'references': canonicalJsonForHash(inputs.references),
      'roleDelegation': canonicalJsonForHash(roleDelegation),
      'referenceChoices': canonicalJsonForHash(rendered.referenceChoices),
      'observations': observations,
      'sourceRemovalRequired': conversion.sourceRemovalRequired,
      'candidate': <String, Object?>{
        'byteLength': utf8.encode(rendered.content).length,
        'sha256': _digest(rendered.content),
        if (showInstructions) 'text': rendered.content,
      },
    };
    return AuthoringPlan(
      planId: planId,
      ready: ready,
      operation: inputs.operation,
      kind: inputs.kind,
      profile: inputs.profile,
      ownership: ownership,
      output: placement.output,
      candidate: rendered.content,
      sidecar: rendered.sidecar,
      conversion: effectiveConversion,
      diagnostics: List<Map<String, Object?>>.unmodifiable(diagnostics),
      data: Map<String, Object?>.unmodifiable(data),
      identity: Map<String, Object?>.unmodifiable(identity),
    );
  }

  /// The context of the selected source.
  ///
  /// A tracked source may live in the other scope. The source context
  /// selects the ledger that owns the source; the context of the operation
  /// stays the scope of the published output.
  LifecycleContext _sourceContext(
    AuthoringInputs inputs,
    LifecycleContext context,
  ) {
    final scope = inputs.sourceScope;
    if (scope == null || scope == context.scope) return context;
    return LifecycleContext.resolve(
      context.options.copyWith(scope: scope),
      fileSystem: _fileSystem,
    );
  }

  Future<_Source?> _resolveSource(
    AuthoringInputs inputs,
    LifecycleContext context,
  ) async {
    if (inputs.source.isEmpty) return null;
    var path = inputs.source.path;
    String? installationId = inputs.source.installationId;
    LifecycleScope? scope;
    ArtifactKind? artifactKind;
    if (installationId != null) {
      final record = _state.recordById(context, installationId);
      final agentRecord = record.kind == ArtifactKind.agentFile;
      if (inputs.kind == AuthoringKind.agent && !agentRecord) {
        throw MambaException(
          'The selected installation is not an Agent installation.',
          exitCode: 4,
        );
      }
      if (inputs.kind != AuthoringKind.agent && agentRecord) {
        throw MambaException(
          'The selected installation is not a '
          '${inputs.kind.name} installation.',
          exitCode: 4,
        );
      }
      path = record.location;
      scope = record.scope;
      artifactKind = record.kind;
    } else {
      path = context.resolvePath(path!);
    }
    if (inputs.kind == AuthoringKind.agent) {
      final type = skillEntityType(path, followLinks: false, fs: _fileSystem);
      if (type == FileSystemEntityType.directory) {
        return _promptSource(
          path,
          PromptForm.skill,
          installationId,
          scope,
          artifactKind,
        );
      }
      if (type != FileSystemEntityType.file) {
        throw MambaException(
          'The selected source is not a readable native definition.',
          exitCode: 4,
        );
      }
      if (inputs.conversion == ConversionDirection.promptToAgent) {
        return _promptSource(
          path,
          PromptForm.template,
          installationId,
          scope,
          artifactKind,
        );
      }
      final content = _readMarker(path);
      final report = inspectNativeAgentContent(
        content: content,
        harness: agentHarnessForProfile(_sourceProfile(inputs)),
        definitionFile: path,
      );
      return _Source(
        path: path,
        fields: report.nativeFields,
        body: report.instructionText ?? '',
        agent: report,
        installationId: installationId,
        scope: scope,
        artifactKind: artifactKind,
        marker: path,
        markerSha256: _digest(content),
      );
    }
    final type = skillEntityType(path, followLinks: false, fs: _fileSystem);
    if (type == FileSystemEntityType.file &&
        inputs.profile != AuthoringProfile.pi) {
      throw MambaException(
        'The ${inputs.profile.name} source must be a skill directory.',
        exitCode: 4,
      );
    }
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.file) {
      throw MambaException(
        'The selected source is not a readable skill directory or template.',
        exitCode: 4,
      );
    }
    final form = type == FileSystemEntityType.directory
        ? PromptForm.skill
        : PromptForm.template;
    return _promptSource(path, form, installationId, scope, artifactKind);
  }

  Future<_Source> _promptSource(
    String path,
    PromptForm form,
    String? installationId,
    LifecycleScope? scope,
    ArtifactKind? artifactKind,
  ) async {
    final inspection = await _prompts.inspect(
      path,
      form: form,
      // A template is only classified in the Pi template context, so that
      // context is selected explicitly.
      consumer: form == PromptForm.template ? PromptConsumer.pi : null,
    );
    final marker = form == PromptForm.skill
        ? _fileSystem.path.join(path, 'SKILL.md')
        : path;
    final markerContent = _readMarker(marker);
    final body = _splitBody(markerContent);
    return _Source(
      path: path,
      form: form,
      fields: inspection.fields,
      sidecarFields: inspection.sidecarFields,
      body: body,
      inspection: inspection,
      installationId: installationId,
      scope: scope,
      artifactKind: artifactKind,
      marker: marker,
      markerSha256: _digest(markerContent),
      members: form == PromptForm.skill
          ? readPackageManifest(_fileSystem, path)
          : PackageManifest.empty,
    );
  }

  Future<String?> _resolveBody(
    AuthoringInputs inputs,
    LifecycleContext context,
  ) async {
    final selection = inputs.body;
    if (selection == null) return null;
    switch (selection.kind) {
      case BodyInputKind.file:
        final path = context.resolvePath(selection.filePath!);
        final type = skillEntityType(path, followLinks: false, fs: _fileSystem);
        if (type != FileSystemEntityType.file) {
          throw MambaException(
            'The body file must be a regular non-link file: $path',
            exitCode: 4,
          );
        }
        return _readMarker(path, label: 'body file');
      case BodyInputKind.standardInput:
        final reader = standardInput;
        if (reader == null) {
          throw MambaException(
            'Standard input was not supplied; select a body file or literal text.',
            exitCode: 4,
          );
        }
        return await reader();
      case BodyInputKind.literal:
        return selection.text!;
    }
  }

  /// Reports the native diagnostics of the selected source.
  ///
  /// A source that the target profile cannot read is not a valid basis for a
  /// proposal. The unknown field and extra entry findings are reported by the
  /// field assessment and the conversion shape check instead.
  void _reportSourceDiagnostics(
    AuthoringInputs inputs,
    _Source? source,
    void Function(String code, String field, String message) error,
  ) {
    final inspection = source?.inspection;
    if (inspection == null) return;
    final consumers = inputs.profile == AuthoringProfile.global
        ? const <PromptConsumer>[PromptConsumer.claude, PromptConsumer.codex]
        : <PromptConsumer>[_consumer(inputs.profile)];
    final reported = <String>{};
    for (final consumer in consumers) {
      final view = inspection.views[consumer];
      if (view == null) continue;
      for (final diagnostic in view.diagnostics) {
        if (diagnostic.code == 'UNKNOWN_FIELD' ||
            diagnostic.code == 'EXTRA_ENTRY') {
          continue;
        }
        final key = '${diagnostic.code}:${diagnostic.message}';
        if (!reported.add(key)) continue;
        error(diagnostic.code, 'source', diagnostic.message);
      }
    }
  }

  /// Classifies the source fields that the target profile does not expose as
  /// named inputs.
  ///
  /// A source declaration without a named input is preserved when the target
  /// profile accepts and validates it. A declaration that the profile cannot
  /// represent is a blocker: it is never dropped silently.
  _SourceAssessment _assessSourceFields(
    AuthoringInputs inputs,
    _Source? source,
    void Function(String code, String field, String message) error,
  ) {
    final preserved = <String, Object?>{};
    if (source == null) return _SourceAssessment(preserved);
    final matrix = inputs.matrix;
    final sourceFields = source.fields;
    if (sourceFields.isEmpty) return _SourceAssessment(preserved);
    final allowed = _allowedSourceFields(inputs, source);
    final rejected = <String>{};
    for (final key in sourceFields.keys) {
      if (matrix.specFor(key) != null) continue;
      if (key == 'developer_instructions') continue;
      if (inputs.conversion == ConversionDirection.promptToAgent &&
          _promptMechanismFields.contains(key)) {
        // The manual-only controls and the invocation surface are accounted
        // for by the disclosed Prompt to Agent mechanism change.
        continue;
      }
      if (allowed.contains(key)) {
        preserved[key] = sourceFields[key];
        continue;
      }
      rejected.add(key);
    }
    for (final key in rejected.toList()..sort()) {
      error(
        'SOURCE_FIELD_UNSUPPORTED',
        key,
        'The source declares $key, which the ${inputs.profile.name} '
            '${inputs.kind.name} profile cannot represent. Edit the source '
            'explicitly before this operation.',
      );
    }
    return _SourceAssessment(preserved);
  }

  Set<String> _allowedSourceFields(AuthoringInputs inputs, _Source source) {
    final form = source.form ?? PromptForm.skill;
    return switch (inputs.profile) {
      AuthoringProfile.claude => PromptInspectionService.allowedFields(
        form,
        PromptConsumer.claude,
      ),
      AuthoringProfile.codex => PromptInspectionService.allowedFields(
        form,
        PromptConsumer.codex,
      ),
      AuthoringProfile.pi => PromptInspectionService.allowedFields(
        form,
        PromptConsumer.pi,
      ),
      AuthoringProfile.global =>
        PromptInspectionService.allowedFields(
          form,
          PromptConsumer.claude,
        ).intersection(
          PromptInspectionService.allowedFields(form, PromptConsumer.codex),
        ),
      AuthoringProfile.antigravity => inputs.matrix.supportedNames.toSet(),
    };
  }

  Map<String, Object?> _mergeFields(
    AuthoringInputs inputs,
    _Source? source,
    Map<String, Object?> preserved,
    void Function(String code, String field, String message) error,
  ) {
    final matrix = inputs.matrix;
    final merged = <String, Object?>{...preserved};
    final sourceFields = source?.fields ?? const <String, Object?>{};
    for (final spec in matrix.fields) {
      if (sourceFields.containsKey(spec.name)) {
        merged[spec.name] = sourceFields[spec.name];
      }
    }
    for (final entry in inputs.fields.entries) {
      final value = entry.value;
      switch (value) {
        case ClearedFieldValue():
          merged.remove(entry.key);
        case InheritedFieldValue():
          break;
        case TextFieldValue(:final text):
          merged[entry.key] = text;
        case BooleanFieldValue(:final value):
          merged[entry.key] = value;
        case ListFieldValue(:final values):
          merged[entry.key] = List<String>.of(values);
        case MapFieldValue(:final entries):
          merged[entry.key] = Map<String, Object?>.of(entries);
      }
    }
    for (final spec in matrix.fields) {
      if (!spec.required) continue;
      final value = merged[spec.name];
      final missing =
          value == null ||
          (value is String && value.trim().isEmpty) ||
          (value is List && value.isEmpty);
      if (missing) {
        error(
          'FIELD_REQUIRED',
          spec.name,
          'The ${spec.name} field is required for the '
              '${matrix.profile.name} ${matrix.kind.name} profile.',
        );
      }
    }
    return merged;
  }

  Map<String, String> _fieldIntents(AuthoringInputs inputs) {
    final intents = <String, String>{};
    for (final entry in inputs.fields.entries) {
      switch (entry.value) {
        case ClearedFieldValue():
          intents[entry.key] = 'cleared';
        case InheritedFieldValue():
          intents[entry.key] = 'inherited';
        case TextFieldValue() ||
            BooleanFieldValue() ||
            ListFieldValue() ||
            MapFieldValue():
          intents[entry.key] = 'supplied';
      }
    }
    return intents;
  }

  String _composeBody(AuthoringInputs inputs, _Source? source, String? body) {
    final sourceBody = source?.body ?? '';
    switch (inputs.operation) {
      case AuthoringOperation.create:
        return body ?? '';
      case AuthoringOperation.clone:
      case AuthoringOperation.convert:
        return sourceBody;
      case AuthoringOperation.edit:
        return body ?? sourceBody;
      case AuthoringOperation.compose:
        return switch (inputs.composition) {
          CompositionMode.append =>
            body == null
                ? sourceBody
                : sourceBody.isEmpty
                ? body
                : '$sourceBody\n$body',
          CompositionMode.replace => body ?? sourceBody,
          CompositionMode.retain => sourceBody,
          null => sourceBody,
        };
    }
  }

  _Placement _resolvePlacement(
    AuthoringInputs inputs,
    LifecycleContext context,
    Map<String, Object?> fields,
    _Source? source,
    LifecycleContext sourceContext,
  ) {
    final name = fields['name'];
    final nameText = name is String ? name.trim() : '';
    final nativeRoot = _nativeRoot(inputs, context);
    if (inputs.operation == AuthoringOperation.edit && source?.path != null) {
      final sourcePath = source!.path!;
      final directory = source.form == PromptForm.skill ? sourcePath : null;
      final marker = directory == null
          ? sourcePath
          : _fileSystem.path.join(directory, 'SKILL.md');
      // An edit replaces its source in place, so the native root of the
      // placement is the root of the scope that owns the source.
      final sourceRoot = _nativeRoot(inputs, sourceContext);
      final root = sourceRoot != null && _within(sourcePath, sourceRoot)
          ? sourceRoot
          : null;
      return _Placement(
        output: marker,
        root: root,
        form: _formFor(inputs),
        name: nameText,
        directory: directory,
        sidecar: _sidecarFor(inputs, directory),
      );
    }
    final override = inputs.output;
    if (override != null) {
      final resolved = context.resolvePath(override);
      if (_isPackageForm(inputs)) {
        final shape = _packageOverride(resolved);
        return _placementFor(
          inputs,
          shape.output,
          null,
          nameText,
          directory: shape.directory,
          sidecar: _sidecarFor(inputs, shape.directory),
          override: true,
        );
      }
      return _placementFor(inputs, resolved, null, nameText);
    }
    if (nameText.isEmpty) {
      // The missing name is reported as a required field. The plan stays
      // unready and reports no target until the name is supplied.
      return _Placement(
        output: null,
        root: null,
        form: _formFor(inputs),
        name: nameText,
      );
    }
    switch (inputs.kind) {
      case AuthoringKind.skill:
        final directory = _fileSystem.path.join(nativeRoot!, nameText);
        return _placementFor(
          inputs,
          _fileSystem.path.join(directory, 'SKILL.md'),
          nativeRoot,
          nameText,
          directory: directory,
        );
      case AuthoringKind.prompt:
        if (inputs.profile == AuthoringProfile.pi) {
          return _placementFor(
            inputs,
            _fileSystem.path.join(nativeRoot!, '$nameText.md'),
            nativeRoot,
            nameText,
          );
        }
        final directory = _fileSystem.path.join(nativeRoot!, nameText);
        return _placementFor(
          inputs,
          _fileSystem.path.join(directory, 'SKILL.md'),
          nativeRoot,
          nameText,
          directory: directory,
          sidecar: _sidecarFor(inputs, directory),
        );
      case AuthoringKind.agent:
        final extension = inputs.profile == AuthoringProfile.codex
            ? '.toml'
            : '.md';
        return _placementFor(
          inputs,
          _fileSystem.path.join(nativeRoot!, '$nameText$extension'),
          nativeRoot,
          nameText,
        );
    }
  }

  _Placement _placementFor(
    AuthoringInputs inputs,
    String output,
    String? root,
    String name, {
    String? directory,
    String? sidecar,
    bool override = false,
  }) => _Placement(
    output: output,
    root: root,
    form: _formFor(inputs),
    name: name,
    directory: directory,
    sidecar: sidecar,
    override: override,
  );

  String _formFor(AuthoringInputs inputs) => switch (inputs.kind) {
    AuthoringKind.skill => 'skill-directory',
    AuthoringKind.prompt =>
      inputs.profile == AuthoringProfile.pi
          ? 'prompt-template'
          : 'prompt-skill',
    AuthoringKind.agent => 'agent-file',
  };

  String? _sidecarFor(AuthoringInputs inputs, String? directory) {
    if (directory == null) return null;
    if (inputs.kind != AuthoringKind.prompt) return null;
    if (inputs.profile == AuthoringProfile.claude ||
        inputs.profile == AuthoringProfile.pi) {
      return null;
    }
    return _fileSystem.path.join(directory, 'agents', 'openai.yaml');
  }

  /// Whether the selected profile publishes a native package.
  bool _isPackageForm(AuthoringInputs inputs) =>
      inputs.kind == AuthoringKind.skill ||
      (inputs.kind == AuthoringKind.prompt &&
          inputs.profile != AuthoringProfile.pi);

  /// The package shape of an explicit output override.
  ///
  /// A package override names the package directory, unless it names the
  /// marker of the package itself.
  ({String output, String directory}) _packageOverride(String path) {
    if (_fileSystem.path.basename(path) == 'SKILL.md') {
      return (output: path, directory: _fileSystem.path.dirname(path));
    }
    return (output: _fileSystem.path.join(path, 'SKILL.md'), directory: path);
  }

  _ConversionAnalysis _analyzeConversion(
    AuthoringInputs inputs,
    LifecycleContext context,
    _Source? source,
    Map<String, Object?> fields,
    void Function(String code, String field, String message) error,
    ConversionDirection? direction,
  ) {
    if (direction == null) return const _ConversionAnalysis();
    switch (direction) {
      case ConversionDirection.skillToPrompt:
        if (source?.form != PromptForm.skill) {
          error(
            'CONVERSION_SOURCE_UNSUPPORTED',
            'source',
            'A Skill to Prompt conversion requires a skill directory source.',
          );
          return const _ConversionAnalysis();
        }
        for (final entry in _extraSkillEntries(source!.path!)) {
          error(
            'CONVERSION_SOURCE_SHAPE',
            'source',
            'The source skill contains an entry that a Prompt cannot carry: '
                '$entry.',
          );
        }
        for (final match in PromptResourcePathScanner.scan(source.body)) {
          error(
            'CONVERSION_RESOURCE_REFERENCE',
            'source',
            'The source instructions reference a ${match.segment} resource '
                'path; a Prompt must be resource free.',
          );
          break;
        }
        final name = fields['name'];
        final nameText = name is String ? name.trim() : '';
        if (inputs.profile == AuthoringProfile.pi) {
          // The Pi conversion replaces the Skill with a standalone native
          // template instead of keeping a second active resource.
          final nativeRoot = _nativeRoot(inputs, context);
          return _ConversionAnalysis(
            placement: _Placement(
              output: _fileSystem.path.join(nativeRoot!, '$nameText.md'),
              root: nativeRoot,
              form: 'prompt-template',
              name: nameText,
            ),
            roleDelegation: const <String, Object?>{
              'manualInvocationBecomesTemplate': true,
            },
            sourceRemovalRequired: true,
          );
        }
        final directory = source.path!;
        final nativeRoot = _nativeRoot(inputs, context);
        final crossScope =
            source.scope != null && source.scope != context.scope;
        if (crossScope) {
          // A tracked source of the other scope migrates into the scope of
          // the operation: the converted target is published in the target
          // scope and the source is retired in the scope that owns it.
          final targetRoot = nativeRoot!;
          final targetDirectory = _fileSystem.path.join(targetRoot, nameText);
          return _ConversionAnalysis(
            placement: _Placement(
              output: _fileSystem.path.join(targetDirectory, 'SKILL.md'),
              root: targetRoot,
              form: 'prompt-skill',
              name: nameText,
              directory: targetDirectory,
              sidecar: inputs.profile == AuthoringProfile.claude
                  ? null
                  : _fileSystem.path.join(
                      targetDirectory,
                      'agents',
                      'openai.yaml',
                    ),
            ),
            roleDelegation: const <String, Object?>{
              'manualOnlyInvocationDeclared': true,
            },
          );
        }
        return _ConversionAnalysis(
          placement: _Placement(
            output: _fileSystem.path.join(directory, 'SKILL.md'),
            root: nativeRoot != null && _within(directory, nativeRoot)
                ? nativeRoot
                : null,
            form: 'prompt-skill',
            name: nameText,
            directory: directory,
            sidecar: inputs.profile == AuthoringProfile.claude
                ? null
                : _fileSystem.path.join(directory, 'agents', 'openai.yaml'),
          ),
          roleDelegation: const <String, Object?>{
            'manualOnlyInvocationDeclared': true,
          },
        );
      case ConversionDirection.promptToAgent:
        final view = _promptView(source?.inspection, inputs.profile);
        if (view == null ||
            view.classification != PromptClassification.prompt) {
          error(
            'CONVERSION_SOURCE_UNSUPPORTED',
            'source',
            'A Prompt to Agent conversion requires a valid prompt source for '
                'the selected profile.',
          );
          return const _ConversionAnalysis();
        }
        if (view.argumentExpressions.isNotEmpty || view.dynamicShell) {
          error(
            'ACTIVE_TEMPLATE_REFUSED',
            'source',
            'Active template arguments and dynamic injection are refused; '
                'rewrite the prompt explicitly before converting.',
          );
        }
        return const _ConversionAnalysis(
          roleDelegation: <String, Object?>{
            'instructionsBecomeRole': true,
            'manualInvocationBecomesDelegation': true,
          },
        );
      case ConversionDirection.agentToAgent:
        final matrix = inputs.matrix;
        for (final key in (source?.fields ?? const <String, Object?>{}).keys) {
          if (matrix.specFor(key) == null) {
            error(
              'CONVERSION_FIELD_UNSUPPORTED',
              key,
              'The source field $key is not supported by the '
                  '${inputs.profile.name} agent profile.',
            );
          }
        }
        return const _ConversionAnalysis();
    }
  }

  /// The conversion direction that the selected operation performs.
  ///
  /// An explicit direction is used as supplied. A Skill to Prompt edit
  /// dispatches the conversion, and a Prompt to Skill edit is refused.
  ConversionDirection? _effectiveConversion(
    AuthoringInputs inputs,
    _Source? source,
    void Function(String code, String field, String message) error,
  ) {
    if (inputs.conversion != null) return inputs.conversion;
    if (source == null) return null;
    if (inputs.operation != AuthoringOperation.edit) return null;
    final prompt = _promptView(source.inspection, inputs.profile);
    final sourceIsPrompt =
        prompt != null && prompt.classification == PromptClassification.prompt;
    if (inputs.kind == AuthoringKind.prompt) {
      if (sourceIsPrompt) return null;
      return ConversionDirection.skillToPrompt;
    }
    if (inputs.kind == AuthoringKind.skill && sourceIsPrompt) {
      error(
        'PROMPT_TO_SKILL_UNSUPPORTED',
        'source',
        'A Prompt to Skill reclassification is not supported; edit the Skill '
            'source explicitly instead.',
      );
    }
    return null;
  }

  List<String> _extraSkillEntries(String directory) {
    final entries = <String>[];
    final names = listSkillDirectory(
      directory,
      fs: _fileSystem,
    ).map((entry) => _fileSystem.path.basename(entry.path)).toList();
    for (final name in names) {
      if (name == 'SKILL.md' || name == 'agents') continue;
      entries.add(name);
    }
    final agents = _fileSystem.path.join(directory, 'agents');
    if (skillEntityType(agents, followLinks: false, fs: _fileSystem) ==
        FileSystemEntityType.directory) {
      for (final entry in listSkillDirectory(agents, fs: _fileSystem)) {
        if (_fileSystem.path.basename(entry.path) != 'openai.yaml') {
          entries.add('agents/${_fileSystem.path.basename(entry.path)}');
        }
      }
    }
    entries.sort();
    return entries;
  }

  AuthoringOwnership _resolveOwnership(
    AuthoringInputs inputs,
    LifecycleContext context,
    _Placement placement,
    _Source? source,
    void Function(String code, String field, String message) error,
    ConversionDirection? conversion,
  ) {
    final installationId = source?.installationId;
    if (installationId != null && conversion != null) {
      // A tracked source keeps its management through a conversion: the
      // target inherits the managed ownership and the source is retired.
      return AuthoringOwnership.managedReplacement;
    }
    if (installationId != null && _sameTarget(placement, source)) {
      final installation = _state.recordById(context, installationId);
      if (_state.verify(installation) != ModificationStatus.unchanged) {
        error(
          'MANAGED_TARGET_CHANGED',
          'target.output',
          'The managed source changed since its baseline; a reviewed plan '
              'cannot replace it.',
        );
      }
      return AuthoringOwnership.managedReplacement;
    }
    if (!inputs.manage) return AuthoringOwnership.authorOnly;
    if (!_supportsManagement(inputs.kind, inputs.profile)) {
      error(
        'MANAGEMENT_UNSUPPORTED',
        'management',
        'Managed publication is not supported for ${inputs.kind.name} '
            'resources in the ${inputs.profile.name} profile; author-only '
            'output remains available.',
      );
      return AuthoringOwnership.authorOnly;
    }
    final root = placement.root;
    final output = placement.output;
    if (root == null || output == null || !_within(output, root)) {
      error(
        'MANAGEMENT_TARGET_UNSUPPORTED',
        'target.output',
        'Managed publication requires the eligible native location for the '
            'selected profile and scope.',
      );
      return AuthoringOwnership.authorOnly;
    }
    return AuthoringOwnership.managedRequested;
  }

  _Rendered _render(
    AuthoringInputs inputs,
    _Source? source,
    Map<String, Object?> fields,
    String body,
    _Placement placement,
    void Function(String code, String field, String message) error,
  ) {
    if (inputs.kind == AuthoringKind.agent) {
      return _renderAgent(inputs, source, fields, body, placement, error);
    }
    return _renderSkillOrPrompt(inputs, source, fields, body, placement, error);
  }

  _Rendered _renderSkillOrPrompt(
    AuthoringInputs inputs,
    _Source? source,
    Map<String, Object?> fields,
    String body,
    _Placement placement,
    void Function(String code, String field, String message) error,
  ) {
    final rendered = <String, Object?>{...fields};
    String? sidecar;
    if (inputs.kind == AuthoringKind.prompt) {
      if (inputs.profile == AuthoringProfile.pi) {
        // A native template names the command by its file name.
        rendered.remove('name');
      } else {
        rendered['disable-model-invocation'] = true;
      }
      if (inputs.profile == AuthoringProfile.codex ||
          inputs.profile == AuthoringProfile.global) {
        sidecar = _sidecarContent(inputs, source);
      }
    }
    _validateSkillFields(rendered, placement, error);
    if (body.trim().isEmpty) {
      error(
        'INSTRUCTIONS_REQUIRED',
        'body',
        'The proposed instructions must not be empty.',
      );
    }
    if (inputs.kind == AuthoringKind.prompt) {
      _validatePromptBody(body, error);
    }
    return _Rendered(
      content: _renderMarkdown(rendered, body, inputs.matrix),
      sidecar: sidecar,
    );
  }

  /// The proposed Codex sidecar.
  ///
  /// The manual-only policy is declared without dropping the other validated
  /// sidecar declarations of the source.
  String? _sidecarContent(AuthoringInputs inputs, _Source? source) {
    final merged = <String, Object?>{};
    for (final entry
        in (source?.sidecarFields ?? const <String, Object?>{}).entries) {
      merged[entry.key] = entry.value;
    }
    final policy = merged['policy'];
    final policyFields = policy is Map
        ? Map<String, Object?>.from(policy)
        : <String, Object?>{};
    policyFields['allow_implicit_invocation'] = false;
    merged['policy'] = policyFields;
    return _yamlDocument(merged);
  }

  _Rendered _renderAgent(
    AuthoringInputs inputs,
    _Source? source,
    Map<String, Object?> fields,
    String body,
    _Placement placement,
    void Function(String code, String field, String message) error,
  ) {
    final rendered = <String, Object?>{...fields};
    for (final message in applyNativeReferenceMappings(
      rendered,
      inputs.references,
      agentHarnessForProfile(inputs.profile),
    )) {
      error('REFERENCE_MAPPING', 'references', message);
    }
    if (inputs.profile == AuthoringProfile.codex) {
      rendered['developer_instructions'] = body;
    }
    final content = _renderAgentNative(
      inputs.profile,
      rendered,
      body,
      inputs.matrix,
    );
    final report = inspectNativeAgentContent(
      content: content,
      harness: agentHarnessForProfile(inputs.profile),
      definitionFile: placement.output,
    );
    for (final diagnostic in report.diagnostics) {
      error(
        diagnostic.code,
        diagnostic.field ?? 'target.output',
        diagnostic.message,
      );
    }
    // The reference accounting reconciles the references of a native Agent
    // source with the references of the proposal. A creation has no source
    // to reconcile with: an explicitly supplied native field is the intent
    // itself and never needs a second decision token.
    final sourceAgent = source?.agent;
    if (sourceAgent != null) {
      for (final finding in authoringReferenceDecisionFindings(
        sourceAgent.references,
        report.references,
        inputs.decisions,
        inputs.references,
      )) {
        error(
          finding['code']! as String,
          (finding['field'] as String?) ?? 'references',
          finding['message']! as String,
        );
      }
    }
    final graph = _graph.analyzeInspection(report);
    if (!graph.ready) {
      error(
        'GRAPH_NOT_READY',
        'target.output',
        'The native dependency graph of the proposed Agent is not ready.',
      );
    }
    return _Rendered(
      content: content,
      roleDelegation: <String, Object?>{
        'parentRequirements': report.parentRequirements,
        'graphReady': graph.ready,
      },
      referenceChoices: <Map<String, Object?>>[
        for (final reference in report.references)
          <String, Object?>{
            'kind': reference['kind'],
            'name': reference['name'],
          },
      ],
    );
  }

  void _validateSkillFields(
    Map<String, Object?> fields,
    _Placement placement,
    void Function(String code, String field, String message) error,
  ) {
    final name = fields['name'];
    if (name is String && name.isNotEmpty) {
      final directory = placement.directory;
      // The native name must match the directory name of a native placement
      // and of an in-place edit. An explicit output override keeps the name
      // of the proposal: the operator selected the folder.
      if (directory != null &&
          !placement.override &&
          !_fileSystem.path.equals(
            _fileSystem.path.basename(directory),
            name,
          )) {
        error(
          'NAME_MISMATCH',
          'name',
          'The native name must match the target directory name.',
        );
      }
      if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(name) ||
          name.length > 64) {
        error(
          'NAME_INVALID',
          'name',
          'The native name must use lowercase words separated by single '
              'hyphens and must not exceed 64 characters.',
        );
      }
    }
    final description = fields['description'];
    if (description is String && description.runes.length > 1024) {
      error(
        'DESCRIPTION_LENGTH',
        'description',
        'The description exceeds 1024 characters.',
      );
    }
    final compatibility = fields['compatibility'];
    if (compatibility is String) {
      final length = compatibility.runes.length;
      if (length == 0 || length > 500) {
        error(
          'COMPATIBILITY_LENGTH',
          'compatibility',
          'The compatibility field must contain 1 to 500 characters.',
        );
      }
    }
  }

  void _validatePromptBody(
    String body,
    void Function(String code, String field, String message) error,
  ) {
    for (final match in PromptResourcePathScanner.scan(body)) {
      error(
        'RESOURCE_REFERENCE',
        'body',
        'The instruction body contains a blocked ${match.segment} resource '
            'path segment.',
      );
    }
  }

  String _observeTarget(
    _Placement placement,
    _Source? source,
    AuthoringInputs inputs,
  ) {
    final output = placement.output;
    if (output == null) return 'unresolved';
    final target = placement.directory ?? output;
    final type = skillEntityType(target, followLinks: false, fs: _fileSystem);
    if (type == FileSystemEntityType.notFound) return 'absent';
    if (_sameTarget(placement, source) && _mayTargetSource(inputs)) {
      return 'source';
    }
    return 'occupied';
  }

  /// Whether the operation may place its target on the selected source.
  ///
  /// An edit replaces the source in place and a strict conversion replaces the
  /// source with its converted successor. A create, a clone and a compose
  /// produce a separate output and never take the source over.
  bool _mayTargetSource(AuthoringInputs inputs) =>
      inputs.operation == AuthoringOperation.edit ||
      inputs.operation == AuthoringOperation.convert;

  bool _sameTarget(_Placement placement, _Source? source) {
    final sourcePath = source?.path;
    final output = placement.output;
    if (sourcePath == null || output == null) return false;
    if (placement.directory != null) {
      return _fileSystem.path.equals(placement.directory!, sourcePath);
    }
    return _fileSystem.path.equals(output, sourcePath);
  }

  String _readMarker(String path, {String label = 'native marker'}) {
    final bytes = readBoundedSkillMarker(
      path,
      maxBytes: _maxMarkerBytes,
      fs: _fileSystem,
    );
    if (bytes.length > _maxMarkerBytes) {
      throw MambaException(
        'The $label exceeds the 1 MiB limit: $path',
        exitCode: 3,
      );
    }
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw MambaException('The $label is not valid UTF-8: $path', exitCode: 2);
    }
  }

  String? _nativeRoot(AuthoringInputs inputs, LifecycleContext context) =>
      switch (inputs.kind) {
        AuthoringKind.skill => _skillsRoot(context, inputs.profile),
        AuthoringKind.prompt =>
          inputs.profile == AuthoringProfile.pi
              ? _piPromptsRoot(context)
              : _skillsRoot(context, inputs.profile),
        AuthoringKind.agent => _agentsRoot(context, inputs.profile),
      };

  String _skillsRoot(LifecycleContext context, AuthoringProfile profile) =>
      switch (profile) {
        AuthoringProfile.claude => context.claudeSkillsRoot(),
        AuthoringProfile.codex => context.codexSkillsRoot(),
        AuthoringProfile.global => context.sharedSkillsRoot(),
        AuthoringProfile.pi => _piSkillsRoot(context),
        AuthoringProfile.antigravity =>
          (HarnessCatalog.instance.requireFacet(
            HarnessId.antigravity,
            HarnessFacet.skill,
          ) as SkillHarnessSpec).root(
            context,
            userScope: context.scope == LifecycleScope.user,
          ),
      };

  String _piSkillsRoot(LifecycleContext context) =>
      context.scope == LifecycleScope.project
      ? _fileSystem.path.join(context.projectRoot, '.pi', 'skills')
      : _fileSystem.path.join(context.piAgentRoot(), 'skills');

  String _piPromptsRoot(LifecycleContext context) =>
      context.scope == LifecycleScope.project
      ? _fileSystem.path.join(context.projectRoot, '.pi', 'prompts')
      : _fileSystem.path.join(context.piAgentRoot(), 'prompts');

  String _agentsRoot(LifecycleContext context, AuthoringProfile profile) =>
      switch (profile) {
        AuthoringProfile.claude =>
          context.scope == LifecycleScope.project
              ? context.claudeAgentsRoot()
              : _fileSystem.path.join(context.claudeConfigRoot(), 'agents'),
        AuthoringProfile.codex =>
          context.scope == LifecycleScope.project
              ? context.codexAgentsRoot()
              : _fileSystem.path.join(context.codexRoot(), 'agents'),
        AuthoringProfile.pi => context.piAgentsRoot(),
        AuthoringProfile.global => throw StateError('unreachable'),
        AuthoringProfile.antigravity =>
          context.scope == LifecycleScope.project
              ? _fileSystem.path.join(context.projectRoot, '.agents', 'agents')
              : _fileSystem.path.join(context.geminiConfigRoot(), 'agents'),
      };

  bool _within(String path, String root) =>
      _fileSystem.path.equals(path, root) ||
      _fileSystem.path.isWithin(root, path);

  bool _supportsManagement(AuthoringKind kind, AuthoringProfile profile) =>
      switch (kind) {
        AuthoringKind.skill =>
          profile == AuthoringProfile.claude ||
              profile == AuthoringProfile.codex ||
              profile == AuthoringProfile.antigravity,
        AuthoringKind.agent => true,
        AuthoringKind.prompt => false,
      };

  String _splitBody(String content) {
    final lines = content.split('\n');
    if (lines.isEmpty || lines.first.trimRight() != '---') return content;
    var end = 1;
    while (end < lines.length && lines[end].trimRight() != '---') {
      end++;
    }
    if (end == lines.length) return content;
    return lines.sublist(end + 1).join('\n');
  }

  String _yamlDocument(Map<String, Object?> values) {
    final buffer = StringBuffer();
    void write(String indent, Object? value) {
      if (value is Map) {
        for (final entry in value.entries) {
          final child = entry.value;
          if (child is Map || child is List) {
            buffer.writeln('$indent${entry.key}:');
            write('$indent  ', child);
          } else {
            buffer.writeln('$indent${entry.key}: ${_yamlScalar(child)}');
          }
        }
        return;
      }
      if (value is List) {
        for (final item in value) {
          if (item is Map) {
            final entries = item.entries.toList();
            if (entries.isEmpty) {
              buffer.writeln('$indent- {}');
              continue;
            }
            buffer.writeln(
              '$indent- ${entries.first.key}: '
              '${_yamlScalar(entries.first.value)}',
            );
            for (final entry in entries.skip(1)) {
              buffer.writeln(
                '$indent  ${entry.key}: ${_yamlScalar(entry.value)}',
              );
            }
            continue;
          }
          buffer.writeln('$indent- ${_yamlScalar(item)}');
        }
        return;
      }
      buffer.writeln('$indent${_yamlScalar(value)}');
    }

    write('', values);
    return buffer.toString();
  }

  String _yamlScalar(Object? value) {
    if (value == null) return 'null';
    if (value is bool || value is num) return value.toString();
    return jsonEncode(value.toString());
  }

  String _renderMarkdown(
    Map<String, Object?> fields,
    String body,
    NativeFieldMatrix matrix,
  ) {
    final entries = fields.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    final frontmatter = entries
        .map(
          (entry) =>
              '${entry.key}: ${_yamlValue(entry.value, matrix.specFor(entry.key))}',
        )
        .join('\n');
    return '---\n$frontmatter\n---\n$body';
  }

  String _renderAgentNative(
    AuthoringProfile profile,
    Map<String, Object?> fields,
    String body,
    NativeFieldMatrix matrix,
  ) {
    final harness = agentHarnessForProfile(profile);
    final spec = HarnessCatalog.instance.requireFacet(
      HarnessId.of(harness),
      HarnessFacet.agent,
    ) as AgentHarnessSpec;
    return spec.serializeNativeAgent(profile, fields, body, matrix: matrix);
  }

  String _yamlValue(Object? value, NativeFieldSpec? spec) {
    if (value is List) {
      return spec?.listForm == NativeListForm.scalar
          ? jsonEncode(value.join(', '))
          : jsonEncode(value);
    }
    if (value is Map) {
      return jsonEncode(
        value.map((key, item) => MapEntry(key.toString(), item.toString())),
      );
    }
    return jsonEncode(value);
  }
}

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();

PromptView? _promptView(
  PromptInspection? inspection,
  AuthoringProfile profile,
) {
  if (inspection == null) return null;
  if (inspection.form == PromptForm.template) {
    return inspection.views[PromptConsumer.pi];
  }
  final selected = inspection.views[_consumer(profile)];
  if (selected != null &&
      selected.classification == PromptClassification.prompt) {
    return selected;
  }
  for (final consumer in PromptConsumer.inspectable) {
    final view = inspection.views[consumer];
    if (view != null && view.classification == PromptClassification.prompt) {
      return view;
    }
  }
  return selected;
}

PromptConsumer _consumer(AuthoringProfile profile) => switch (profile) {
  AuthoringProfile.claude => PromptConsumer.claude,
  AuthoringProfile.codex => PromptConsumer.codex,
  AuthoringProfile.pi => PromptConsumer.pi,
  AuthoringProfile.global => PromptConsumer.claude,
  AuthoringProfile.antigravity => PromptConsumer.antigravity,
};

/// The native profile of the selected source.
///
/// The source profile is explicit when it is supplied. It otherwise follows
/// the target profile, and it is never inferred from a Markdown file alone.
AuthoringProfile _sourceProfile(AuthoringInputs inputs) {
  final selected = inputs.source.profile;
  if (selected == null) return inputs.profile;
  if (selected == AuthoringProfile.global) {
    throw MambaException(
      'A global profile does not describe a source definition.',
      exitCode: 4,
    );
  }
  return selected;
}

final class _SourceAssessment {
  const _SourceAssessment(this.preserved);

  final Map<String, Object?> preserved;
}

final class _Source {
  const _Source({
    this.path,
    this.form,
    this.fields = const <String, Object?>{},
    this.sidecarFields = const <String, Object?>{},
    this.body = '',
    this.inspection,
    this.agent,
    this.installationId,
    this.scope,
    this.artifactKind,
    this.marker,
    this.markerSha256,
    this.members,
  });

  final String? path;
  final PromptForm? form;
  final Map<String, Object?> fields;
  final Map<String, Object?> sidecarFields;
  final String body;
  final PromptInspection? inspection;
  final AgentInspectionReport? agent;
  final String? installationId;
  final LifecycleScope? scope;
  final ArtifactKind? artifactKind;

  /// The reviewed marker file of the source.
  ///
  /// A package source is reviewed through its marker, a regular file through
  /// itself.
  final String? marker;

  /// The content digest of the reviewed marker.
  final String? markerSha256;

  /// The reviewed manifest of the owned package members.
  final PackageManifest? members;
}

final class _Placement {
  const _Placement({
    required this.output,
    required this.root,
    required this.form,
    required this.name,
    this.directory,
    this.sidecar,
    this.override = false,
  });

  /// The proposed target, or null while a required field is missing.
  final String? output;
  final String? root;
  final String form;
  final String name;
  final String? directory;
  final String? sidecar;

  /// Whether the placement is an explicit output override.
  final bool override;
}

final class _ConversionAnalysis {
  const _ConversionAnalysis({
    this.placement,
    this.roleDelegation = const <String, Object?>{},
    this.sourceRemovalRequired = false,
  });

  final _Placement? placement;
  final Map<String, Object?> roleDelegation;

  /// Whether the source must be removed after a successful publication.
  ///
  /// A Pi conversion replaces the source Skill with a standalone template
  /// instead of keeping a second active resource.
  final bool sourceRemovalRequired;
}

final class _Rendered {
  const _Rendered({
    required this.content,
    this.sidecar,
    this.roleDelegation = const <String, Object?>{},
    this.referenceChoices = const <Map<String, Object?>>[],
  });

  final String content;
  final String? sidecar;
  final Map<String, Object?> roleDelegation;
  final List<Map<String, Object?>> referenceChoices;
}
