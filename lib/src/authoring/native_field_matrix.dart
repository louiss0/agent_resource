import 'package:mamba/mamba.dart';

import '../harness/harness_catalog.dart';

/// The resource family that one shared authoring input belongs to.
enum AuthoringKind { skill, agent, prompt }

/// The selected native profile.
///
/// [global] is a prompt-only profile: it is the harness-neutral skill-backed
/// form that carries the manual-only controls of every supported harness.
/// A profile never implies runtime discovery or activation.
enum AuthoringProfile { claude, codex, pi, global, antigravity }

/// The value shape that one supported native field accepts.
enum NativeFieldValueKind { text, list, map, flag }

/// The native form that a repeatable list field takes.
enum NativeListForm { sequence, scalar }

/// One documented native authoring field for a single kind and profile.
///
/// The matrix is the supported surface. A field that is not listed here is not
/// an input for that profile, and accepting one spelling across profiles does
/// not establish equivalent semantics.
final class NativeFieldSpec {
  const NativeFieldSpec({
    required this.name,
    required this.valueKind,
    this.required = false,
    this.clearable = false,
    this.inheritable = false,
    this.listForm = NativeListForm.sequence,
    this.description = '',
  });

  final String name;
  final NativeFieldValueKind valueKind;

  /// The native form requires this field.
  final bool required;

  /// The field may be removed explicitly from the target.
  final bool clearable;

  /// The source value may be kept as an explicit recorded intent.
  final bool inheritable;

  /// The native form of a repeatable list field.
  ///
  /// A scalar list is a comma-separated native string; a sequence list is a
  /// native list value.
  final NativeListForm listForm;

  final String description;
}

/// The supported native field surface for one resource kind and profile.
final class NativeFieldMatrix {
  const NativeFieldMatrix({
    required this.kind,
    required this.profile,
    required this.fields,
  });

  final AuthoringKind kind;
  final AuthoringProfile profile;
  final List<NativeFieldSpec> fields;

  /// The documented field for [name], or null when the profile does not
  /// support it.
  NativeFieldSpec? specFor(String name) {
    for (final field in fields) {
      if (field.name == name) return field;
    }
    return null;
  }

  /// The supported field names, sorted for stable messages.
  List<String> get supportedNames =>
      fields.map((field) => field.name).toList()..sort();

  /// The matrix for one kind and profile.
  static NativeFieldMatrix forKind(
    AuthoringKind kind,
    AuthoringProfile profile,
  ) => switch (kind) {
    AuthoringKind.skill => _skill(kind, profile),
    AuthoringKind.prompt => _prompt(kind, profile),
    AuthoringKind.agent => _agent(kind, profile),
  };

  static NativeFieldMatrix _skill(
    AuthoringKind kind,
    AuthoringProfile profile,
  ) {
    if (profile == AuthoringProfile.global) {
      throw MambaException(
        'A global profile applies to prompts only.',
        exitCode: 4,
      );
    }
    final harness = switch (profile) {
      AuthoringProfile.claude => HarnessId.claude,
      AuthoringProfile.codex => HarnessId.codex,
      AuthoringProfile.pi => HarnessId.pi,
      AuthoringProfile.antigravity => HarnessId.antigravity,
      AuthoringProfile.global => throw StateError('unreachable'),
    };
    final spec = HarnessCatalog.instance.requireFacet(
      harness,
      HarnessFacet.skill,
    ) as SkillHarnessSpec;
    return spec.nativeSkillFields(profile);
  }

  static NativeFieldMatrix _prompt(
    AuthoringKind kind,
    AuthoringProfile profile,
  ) {
    switch (profile) {
      case AuthoringProfile.pi:
        return NativeFieldMatrix(
          kind: kind,
          profile: profile,
          fields: const <NativeFieldSpec>[
            NativeFieldSpec(
              name: 'name',
              valueKind: NativeFieldValueKind.text,
              required: true,
              description:
                  'Template command name; it names the file and is not '
                  'rendered into the template.',
            ),
            NativeFieldSpec(
              name: 'description',
              valueKind: NativeFieldValueKind.text,
              required: true,
              description: 'Command completion description.',
            ),
            NativeFieldSpec(
              name: 'argument-hint',
              valueKind: NativeFieldValueKind.text,
              description: 'Argument hint shown for the command.',
            ),
          ],
        );
      case AuthoringProfile.claude:
      case AuthoringProfile.global:
        return NativeFieldMatrix(
          kind: kind,
          profile: profile,
          fields: const <NativeFieldSpec>[
            NativeFieldSpec(
              name: 'name',
              valueKind: NativeFieldValueKind.text,
              required: true,
              description: 'Native prompt name; it must match the directory.',
            ),
            NativeFieldSpec(
              name: 'description',
              valueKind: NativeFieldValueKind.text,
              required: true,
              description: 'When the harness should offer this prompt.',
            ),
            NativeFieldSpec(
              name: 'license',
              valueKind: NativeFieldValueKind.text,
              description: 'Declared license of the prompt.',
            ),
            NativeFieldSpec(
              name: 'compatibility',
              valueKind: NativeFieldValueKind.text,
              description: 'Declared harness compatibility of the prompt.',
            ),
            NativeFieldSpec(
              name: 'argument-hint',
              valueKind: NativeFieldValueKind.text,
              description: 'Argument hint shown for the prompt.',
            ),
          ],
        );
      case AuthoringProfile.codex:
        return NativeFieldMatrix(
          kind: kind,
          profile: profile,
          fields: const <NativeFieldSpec>[
            NativeFieldSpec(
              name: 'name',
              valueKind: NativeFieldValueKind.text,
              required: true,
              description: 'Native prompt name; it must match the directory.',
            ),
            NativeFieldSpec(
              name: 'description',
              valueKind: NativeFieldValueKind.text,
              required: true,
              description: 'When the harness should offer this prompt.',
            ),
            NativeFieldSpec(
              name: 'license',
              valueKind: NativeFieldValueKind.text,
              description: 'Declared license of the prompt.',
            ),
            NativeFieldSpec(
              name: 'compatibility',
              valueKind: NativeFieldValueKind.text,
              description: 'Declared harness compatibility of the prompt.',
            ),
          ],
        );
      case AuthoringProfile.antigravity:
        HarnessCatalog.instance.requirePromptFacet(
          HarnessId.antigravity,
          exitCode: 4,
        );
        throw StateError('unreachable');
    }
  }

  static NativeFieldMatrix _agent(
    AuthoringKind kind,
    AuthoringProfile profile,
  ) {
    final harness = switch (profile) {
      AuthoringProfile.claude => HarnessId.claude,
      AuthoringProfile.codex => HarnessId.codex,
      AuthoringProfile.pi => HarnessId.pi,
      AuthoringProfile.antigravity => HarnessId.antigravity,
      AuthoringProfile.global => throw MambaException(
        'A global profile applies to prompts only.',
        exitCode: 4,
      ),
    };
    final spec = HarnessCatalog.instance.requireFacet(
      harness,
      HarnessFacet.agent,
    ) as AgentHarnessSpec;
    return spec.nativeAgentFields(profile);
  }
}
