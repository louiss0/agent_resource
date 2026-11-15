import 'package:mamba/mamba.dart';

import '../services/lifecycle_state_service.dart' show LifecycleScope;
import 'native_field_matrix.dart';

export 'native_field_matrix.dart';

/// The shared authoring operation.
enum AuthoringOperation { create, edit, clone, compose, convert }

/// The approved conversion directions.
///
/// A Prompt to Skill reclassification is deliberately absent: that direction
/// is not supported by this feature.
enum ConversionDirection { skillToPrompt, promptToAgent, agentToAgent }

/// How one body input was selected.
enum BodyInputKind { file, standardInput, literal }

/// How a composition combines the base body with the new instructions.
enum CompositionMode { append, replace, retain }

/// One normalized native field value.
sealed class AuthoringFieldValue {
  const AuthoringFieldValue();
}

/// A single text value.
final class TextFieldValue extends AuthoringFieldValue {
  const TextFieldValue(this.text);

  final String text;
}

/// A complete list value. A supplied list replaces the whole native field.
final class ListFieldValue extends AuthoringFieldValue {
  const ListFieldValue(this.values);

  final List<String> values;
}

/// A complete map value. The values are JSON-compatible native declarations.
final class MapFieldValue extends AuthoringFieldValue {
  const MapFieldValue(this.entries);

  final Map<String, Object?> entries;
}

/// An explicit removal of a native field.
final class ClearedFieldValue extends AuthoringFieldValue {
  const ClearedFieldValue();
}

/// An explicit request to keep the source value of a native field.
final class InheritedFieldValue extends AuthoringFieldValue {
  const InheritedFieldValue();
}

/// The selected existing source.
///
/// A source is chosen by path or by installation identifier, never by both.
/// A tracked path stays tracked: selecting it does not make it unmanaged.
/// [profile] is the native profile of the source itself. It is required when
/// the source profile differs from the target profile, and it is never
/// inferred from a Markdown file alone.
final class AuthoringSourceSelection {
  const AuthoringSourceSelection({
    this.path,
    this.installationId,
    this.profile,
  });

  final String? path;
  final String? installationId;
  final AuthoringProfile? profile;

  bool get isEmpty => path == null && installationId == null;
  bool get isInstallation => installationId != null;
}

/// The selected body input.
///
/// File, standard input and literal text are mutually exclusive. Multiline
/// bytes are preserved exactly as supplied.
final class AuthoringBodySelection {
  const AuthoringBodySelection({required this.kind, this.filePath, this.text});

  final BodyInputKind kind;
  final String? filePath;
  final String? text;
}

/// The normalized shared authoring inputs.
///
/// The values are typed and profile-aware. They are not a serialized
/// operation document, and no operation document is accepted as an input.
final class AuthoringInputs {
  const AuthoringInputs({
    required this.operation,
    required this.kind,
    required this.profile,
    required this.scope,
    required this.source,
    required this.fields,
    required this.manage,
    this.body,
    this.composition,
    this.output,
    this.decisions = const <String>{},
    this.references = const <String, String>{},
    this.conversion,
    this.sourceScope,
  });

  final AuthoringOperation operation;
  final AuthoringKind kind;
  final AuthoringProfile profile;
  final LifecycleScope scope;
  final AuthoringSourceSelection source;
  final AuthoringBodySelection? body;

  /// The normalized named field values, keyed by native field name.
  final Map<String, AuthoringFieldValue> fields;

  /// An explicit request for a managed installation record.
  final bool manage;

  final CompositionMode? composition;

  /// An explicit output override, used for pack or source authoring.
  final String? output;

  /// Recorded field-specific and reference-specific decisions.
  final Set<String> decisions;

  /// Per-reference mappings chosen for the target.
  final Map<String, String> references;

  final ConversionDirection? conversion;

  /// The scope of a tracked source.
  ///
  /// A tracked source may live in the other scope. The source scope selects
  /// the ledger that owns the source, while the scope of the inputs stays
  /// the scope of the published output. An unmanaged source has no scope:
  /// its path names its location.
  final LifecycleScope? sourceScope;

  /// The supported native fields for the selected kind and profile.
  NativeFieldMatrix get matrix => NativeFieldMatrix.forKind(kind, profile);

  /// A copy of these inputs with a different body or field selection.
  ///
  /// The guided authoring flow uses the copy to replace the deferred body of
  /// an editor-led run and to record the values the operator supplied.
  AuthoringInputs copyWith({
    AuthoringBodySelection? body,
    Map<String, AuthoringFieldValue>? fields,
    bool? manage,
    String? output,
  }) => AuthoringInputs(
    operation: operation,
    kind: kind,
    profile: profile,
    scope: scope,
    source: source,
    body: body ?? this.body,
    fields: fields ?? this.fields,
    manage: manage ?? this.manage,
    composition: composition,
    output: output ?? this.output,
    decisions: decisions,
    references: references,
    conversion: conversion,
    sourceScope: sourceScope,
  );
}

/// Parses and validates the shared native inputs.
///
/// The inputs are named values, not an operation document. Every refusal
/// names the supported alternative so an operator can correct the input
/// without reading the implementation.
///
/// [allowDeferredBody] is the guided authoring seam: an editor-led create
/// supplies the instruction body after the inputs are parsed. The deferred
/// body is never a publication input: the plan of a create without a body
/// is not ready.
AuthoringInputs parseAuthoringInputs({
  required AuthoringOperation operation,
  required AuthoringKind kind,
  required AuthoringProfile profile,
  LifecycleScope scope = LifecycleScope.project,
  String? sourcePath,
  String? installationId,
  AuthoringProfile? sourceProfile,
  String? bodyFile,
  bool bodyStandardInput = false,
  String? bodyText,
  Map<String, Object?> fields = const <String, Object?>{},
  CompositionMode? composition,
  bool manage = false,
  String? output,
  Set<String> decisions = const <String>{},
  Map<String, String> references = const <String, String>{},
  ConversionDirection? conversion,
  LifecycleScope? sourceScope,
  bool allowDeferredBody = false,
}) {
  if (profile == AuthoringProfile.global && kind != AuthoringKind.prompt) {
    throw MambaException(
      'A global profile applies to prompts only; select claude, codex or pi.',
      exitCode: 4,
    );
  }
  final trimmedSource = _blankToNull(sourcePath);
  final trimmedInstallation = _blankToNull(installationId);
  if (trimmedSource != null && trimmedInstallation != null) {
    throw MambaException(
      'Select the source by path or with --installation, not both.',
      exitCode: 4,
    );
  }
  final selectedBody = _selectBody(
    bodyFile: bodyFile,
    bodyStandardInput: bodyStandardInput,
    bodyText: bodyText,
  );
  final matrix = NativeFieldMatrix.forKind(kind, profile);
  final normalizedFields = _normalizeFields(matrix, fields);

  switch (operation) {
    case AuthoringOperation.create:
      if (trimmedSource != null || trimmedInstallation != null) {
        throw MambaException(
          'A create operation uses explicit field and body inputs, not a source.',
          exitCode: 4,
        );
      }
      if (selectedBody == null && !allowDeferredBody) {
        throw MambaException(
          'A create operation requires a body input.',
          exitCode: 4,
        );
      }
    case AuthoringOperation.edit:
    case AuthoringOperation.clone:
    case AuthoringOperation.compose:
    case AuthoringOperation.convert:
      if (trimmedSource == null && trimmedInstallation == null) {
        throw MambaException(
          'The ${operation.name} operation requires a source path or --installation.',
          exitCode: 4,
        );
      }
  }
  if (operation == AuthoringOperation.clone && selectedBody != null) {
    throw MambaException(
      'Clone preserves the source instructions; use compose or edit to change them.',
      exitCode: 4,
    );
  }
  if (operation != AuthoringOperation.compose && composition != null) {
    throw MambaException(
      'The append, replace or retain choice is valid for a compose operation only.',
      exitCode: 4,
    );
  }
  if (operation == AuthoringOperation.compose) {
    if (composition == null) {
      throw MambaException(
        'Compose requires an explicit append, replace or retain choice.',
        exitCode: 4,
      );
    }
    if (composition == CompositionMode.retain && selectedBody != null) {
      throw MambaException(
        'Compose retain cannot be combined with a supplied body.',
        exitCode: 4,
      );
    }
    if (composition != CompositionMode.retain && selectedBody == null) {
      throw MambaException(
        'Compose $composition requires a supplied body.',
        exitCode: 4,
      );
    }
  }
  if (operation == AuthoringOperation.convert) {
    if (selectedBody != null) {
      throw MambaException(
        'A strict conversion preserves the source instructions; edit the source explicitly instead.',
        exitCode: 4,
      );
    }
    if (conversion == null) {
      throw MambaException(
        'A conversion requires an explicit supported direction.',
        exitCode: 4,
      );
    }
    if (conversion == ConversionDirection.skillToPrompt &&
        kind != AuthoringKind.prompt) {
      throw MambaException(
        'A Skill to Prompt conversion targets the prompt kind.',
        exitCode: 4,
      );
    }
    if (conversion == ConversionDirection.promptToAgent &&
        kind != AuthoringKind.agent) {
      throw MambaException(
        'A Prompt to Agent conversion targets the agent kind.',
        exitCode: 4,
      );
    }
    if (conversion == ConversionDirection.agentToAgent &&
        kind != AuthoringKind.agent) {
      throw MambaException(
        'An Agent to Agent conversion targets the agent kind.',
        exitCode: 4,
      );
    }
  } else if (conversion != null) {
    throw MambaException(
      'A conversion direction is only valid for a convert operation.',
      exitCode: 4,
    );
  }
  if (sourceScope == LifecycleScope.all) {
    throw MambaException(
      'A source scope selects one scope: project or user.',
      exitCode: 4,
    );
  }
  if (sourceScope != null && trimmedInstallation == null) {
    throw MambaException(
      'A source scope applies to a tracked source selected by --installation; '
      'an unmanaged source is selected by its path.',
      exitCode: 4,
    );
  }
  final source = AuthoringSourceSelection(
    path: trimmedSource,
    installationId: trimmedInstallation,
    profile: sourceProfile,
  );
  return AuthoringInputs(
    operation: operation,
    kind: kind,
    profile: profile,
    scope: scope,
    source: source,
    fields: normalizedFields,
    manage: manage,
    body: selectedBody,
    composition: composition,
    output: _blankToNull(output),
    decisions: Set<String>.unmodifiable(decisions),
    references: Map<String, String>.unmodifiable(references),
    conversion: conversion,
    sourceScope: sourceScope,
  );
}

AuthoringBodySelection? _selectBody({
  String? bodyFile,
  bool bodyStandardInput = false,
  String? bodyText,
}) {
  final file = _blankToNull(bodyFile);
  final literal = bodyText;
  final selected = <BodyInputKind>[
    if (file != null) BodyInputKind.file,
    if (bodyStandardInput) BodyInputKind.standardInput,
    if (literal != null && literal.isNotEmpty) BodyInputKind.literal,
  ];
  if (selected.length > 1) {
    throw MambaException(
      'Select exactly one body input: a body file, standard input or literal text.',
      exitCode: 4,
    );
  }
  if (selected.isEmpty) return null;
  return switch (selected.single) {
    BodyInputKind.file => AuthoringBodySelection(
      kind: BodyInputKind.file,
      filePath: file,
    ),
    BodyInputKind.standardInput => AuthoringBodySelection(
      kind: BodyInputKind.standardInput,
    ),
    BodyInputKind.literal => AuthoringBodySelection(
      kind: BodyInputKind.literal,
      text: literal,
    ),
  };
}

Map<String, AuthoringFieldValue> _normalizeFields(
  NativeFieldMatrix matrix,
  Map<String, Object?> fields,
) {
  final normalized = <String, AuthoringFieldValue>{};
  for (final entry in fields.entries) {
    final spec = matrix.specFor(entry.key);
    if (spec == null) {
      throw MambaException(
        'The ${matrix.profile.name} profile does not support the '
        '${entry.key} field for ${matrix.kind.name} resources. '
        'Supported fields: ${matrix.supportedNames.join(', ')}.',
        exitCode: 4,
      );
    }
    final value = entry.value;
    normalized[entry.key] = switch (value) {
      ClearedFieldValue() => _cleared(spec),
      InheritedFieldValue() => _inherited(spec),
      TextFieldValue() => _text(spec, value),
      ListFieldValue() => _list(spec, value),
      MapFieldValue() => _map(spec, value),
      String() => _text(spec, TextFieldValue(value)),
      List<Object?>() => _list(spec, ListFieldValue(_textList(spec, value))),
      Map<Object?, Object?>() => _map(
        spec,
        MapFieldValue(_textMap(spec, value)),
      ),
      _ => throw MambaException(
        'The ${spec.name} field does not accept a ${value.runtimeType}.',
        exitCode: 4,
      ),
    };
  }
  return Map<String, AuthoringFieldValue>.unmodifiable(normalized);
}

List<String> _textList(NativeFieldSpec spec, List<Object?> values) {
  final items = <String>[];
  for (final item in values) {
    if (item is! String) {
      throw MambaException(
        'The ${spec.name} field accepts only text values.',
        exitCode: 4,
      );
    }
    items.add(item);
  }
  return items;
}

Map<String, Object?> _textMap(
  NativeFieldSpec spec,
  Map<Object?, Object?> values,
) {
  final entries = <String, Object?>{};
  for (final item in values.entries) {
    if (item.key is! String) {
      throw MambaException(
        'The ${spec.name} field accepts only named entries.',
        exitCode: 4,
      );
    }
    entries[item.key! as String] = _jsonValue(spec, item.value);
  }
  return entries;
}

Object? _jsonValue(NativeFieldSpec spec, Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is List) {
    return [for (final item in value) _jsonValue(spec, item)];
  }
  if (value is Map) {
    final entries = <String, Object?>{};
    for (final item in value.entries) {
      if (item.key is! String) {
        throw MambaException(
          'The ${spec.name} field accepts only named entries.',
          exitCode: 4,
        );
      }
      entries[item.key! as String] = _jsonValue(spec, item.value);
    }
    return entries;
  }
  throw MambaException(
    'The ${spec.name} field does not accept a ${value.runtimeType}.',
    exitCode: 4,
  );
}

AuthoringFieldValue _text(NativeFieldSpec spec, TextFieldValue value) {
  if (spec.valueKind != NativeFieldValueKind.text) {
    throw MambaException(
      'The ${spec.name} field does not accept a text value.',
      exitCode: 4,
    );
  }
  return value;
}

AuthoringFieldValue _list(NativeFieldSpec spec, ListFieldValue value) {
  if (spec.valueKind != NativeFieldValueKind.list) {
    throw MambaException(
      'The ${spec.name} field does not accept a list value.',
      exitCode: 4,
    );
  }
  for (final item in value.values) {
    if (item.trim().isEmpty) {
      throw MambaException(
        'The ${spec.name} field does not accept blank entries.',
        exitCode: 4,
      );
    }
  }
  return value;
}

AuthoringFieldValue _map(NativeFieldSpec spec, MapFieldValue value) {
  if (spec.valueKind != NativeFieldValueKind.map) {
    throw MambaException(
      'The ${spec.name} field does not accept a map value.',
      exitCode: 4,
    );
  }
  for (final entry in value.entries.entries) {
    if (entry.key.trim().isEmpty) {
      throw MambaException(
        'The ${spec.name} field does not accept blank entries.',
        exitCode: 4,
      );
    }
  }
  return value;
}

AuthoringFieldValue _cleared(NativeFieldSpec spec) {
  if (!spec.clearable) {
    throw MambaException(
      'The ${spec.name} field cannot be cleared explicitly.',
      exitCode: 4,
    );
  }
  return const ClearedFieldValue();
}

AuthoringFieldValue _inherited(NativeFieldSpec spec) {
  if (!spec.inheritable) {
    throw MambaException(
      'The ${spec.name} field cannot inherit the source value explicitly.',
      exitCode: 4,
    );
  }
  return const InheritedFieldValue();
}

String? _blankToNull(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
