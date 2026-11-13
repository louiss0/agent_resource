import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';

import '../pack/pack_models.dart';
import '../services/prompt_inspection_service.dart';
import '../skill_files.dart';

/// The Prompt views of one reviewed path.
///
/// The views are per consumer: a resource is a Prompt for the harnesses whose
/// native controls it declares. The classification never becomes a label in
/// the resource and never replaces the native form of the resource.
final class PackPromptView {
  const PackPromptView({
    required this.path,
    required this.views,
    required this.isTemplate,
  });

  /// The reviewed path.
  final String path;

  /// The per-consumer views of the path.
  final Map<PromptConsumer, PromptView> views;

  /// Whether the path is a standalone native template.
  final bool isTemplate;

  /// The classification of the path in one consumer view.
  PromptClassification? classificationOf(PromptConsumer consumer) =>
      views[consumer]?.classification;

  /// Whether the path is a Prompt for the consumer.
  bool isPrompt(PromptConsumer consumer) =>
      classificationOf(consumer) == PromptClassification.prompt;

  /// Whether the path is a valid Prompt for the consumer.
  bool isValidFor(PromptConsumer consumer) => views[consumer]?.valid ?? false;

  /// The blocking diagnostics of the path in the consumer view.
  List<PromptDiagnostic> diagnosticsFor(PromptConsumer consumer) =>
      views[consumer]?.diagnostics ?? const <PromptDiagnostic>[];
}

/// The Prompt view of one pack candidate.
///
/// The candidate owns the reviewed source and its staged output. The staged
/// output is optional: a selection that was never staged has no staged view.
final class PackPromptCandidate {
  const PackPromptCandidate({
    required this.name,
    required this.source,
    this.staged,
    this.template = false,
  });

  /// The native name of the candidate.
  final String name;

  /// The reviewed source of the candidate.
  final PackPromptView source;

  /// The staged output of the candidate, when it was staged.
  final PackPromptView? staged;

  /// Whether the candidate is a standalone native template.
  final bool template;

  /// Whether the candidate is a Prompt for the consumer.
  bool isPrompt(PromptConsumer consumer) => source.isPrompt(consumer);

  /// Whether the candidate is a Prompt for any consumer.
  bool get isPromptAnywhere => PromptConsumer.values.any(source.isPrompt);
}

/// Inspects and admits the Prompt candidates of a pack.
///
/// The service reads the native views of the explicitly selected candidates.
/// It never writes, never installs and never changes the classification of a
/// resource.
interface class PackPromptService {
  factory PackPromptService({
    fslib.FileSystem fileSystem = const local.LocalFileSystem(),
    PromptInspectionService? prompts,
  }) {
    final resolved = prompts ?? PromptInspectionService(fs: fileSystem);
    return PackPromptService._(fileSystem, resolved);
  }

  PackPromptService._(this._fileSystem, this._prompts);

  final fslib.FileSystem _fileSystem;
  final PromptInspectionService _prompts;

  /// Inspects one path as a Prompt.
  ///
  /// A package is inspected in its skill form and a standalone file in its
  /// template form. The form follows the entity: it is never inferred from
  /// the file extension.
  Future<PackPromptView> inspectView(
    String path, {
    bool template = false,
  }) async {
    final type = skillEntityType(path, followLinks: false, fs: _fileSystem);
    final standalone = template || type == FileSystemEntityType.file;
    final inspection = await _prompts.inspect(
      path,
      form: standalone ? PromptForm.template : PromptForm.skill,
      consumer: standalone ? PromptConsumer.pi : null,
    );
    return PackPromptView(
      path: path,
      views: inspection.views,
      isTemplate: standalone,
    );
  }

  /// Inspects one candidate and its staged output.
  ///
  /// The reviewed source and the staged output are both inspected: the pack
  /// admission and the root Markdown migration cannot disguise an invalid
  /// Prompt.
  Future<PackPromptCandidate> inspect(
    String originalPath,
    String stagedPath, {
    required String name,
  }) async {
    final source = await inspectView(originalPath);
    final staged = await inspectView(stagedPath);
    return PackPromptCandidate(
      name: name,
      source: source,
      staged: staged,
      template: source.isTemplate,
    );
  }

  /// Refuses a Prompt selection that the requested targets do not support.
  ///
  /// Every selected candidate must be a valid, supported Prompt for every
  /// requested target, in the reviewed source and in the staged output. The
  /// whole selection is refused: no resource is skipped, no kind is
  /// substituted and no target is dropped.
  void requireSupportedSelection({
    required List<PackPromptCandidate> selected,
    required List<String> targets,
  }) {
    requireNoPiTarget(targets);
    for (final candidate in selected) {
      if (candidate.template) {
        throw MambaException(
          'A standalone template Prompt is not supported for installation: '
          '${candidate.name}. The selection is refused.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      for (final consumer in consumersOf(targets)) {
        requireEquivalentView(candidate: candidate, consumer: consumer);
        if (!candidate.source.isPrompt(consumer)) {
          throw MambaException(
            '${candidate.name} is not a Prompt for the '
            '${_targetLabel(consumer)} target; the selection is refused.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
        if (!candidate.source.isValidFor(consumer)) {
          throw MambaException(
            '${candidate.name} is an invalid Prompt for the '
            '${_targetLabel(consumer)} target: '
            '${_diagnostics(candidate.source.diagnosticsFor(consumer))} '
            'The selection is refused.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
        final staged = candidate.staged;
        if (staged == null) continue;
        if (!staged.isPrompt(consumer)) {
          throw MambaException(
            'The staged output of ${candidate.name} is not a Prompt for the '
            '${_targetLabel(consumer)} target; the selection is refused.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
        if (!staged.isValidFor(consumer)) {
          throw MambaException(
            'The staged output of ${candidate.name} is an invalid Prompt for '
            'the ${_targetLabel(consumer)} target: '
            '${_diagnostics(staged.diagnosticsFor(consumer))} '
            'The selection is refused.',
            exitCode: PackProcessStatus.invalidInput.code,
          );
        }
      }
    }
  }

  /// Refuses an ordinary Skill that is an invalid Prompt in a target view.
  ///
  /// A manual-only resource that carries bundled resources or forbidden
  /// content is an invalid Prompt candidate. The ordinary Skill selection
  /// never falls back to installing it as an ordinary Skill.
  void requireNoInvalidPromptFallback({
    required PackPromptCandidate candidate,
    required List<String> targets,
  }) {
    if (!candidate.isPromptAnywhere) return;
    for (final consumer in consumersOf(targets)) {
      if (candidate.source.isPrompt(consumer) &&
          !candidate.source.isValidFor(consumer)) {
        throw MambaException(
          '${candidate.name} is an invalid Prompt for the '
          '${_targetLabel(consumer)} target: '
          '${_diagnostics(candidate.source.diagnosticsFor(consumer))} '
          'It is not installed as an ordinary Skill.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
      final staged = candidate.staged;
      if (staged != null &&
          staged.isPrompt(consumer) &&
          !staged.isValidFor(consumer)) {
        throw MambaException(
          'The staged output of ${candidate.name} is an invalid Prompt for '
          'the ${_targetLabel(consumer)} target: '
          '${_diagnostics(staged.diagnosticsFor(consumer))} '
          'It is not installed as an ordinary Skill.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
    }
  }

  /// Refuses a staged output that does not preserve the Prompt view of the
  /// reviewed source.
  ///
  /// The pack admission and the migration must not disguise an invalid
  /// Prompt: the staged output keeps the classification of the reviewed
  /// source in the target view.
  void requireEquivalentView({
    required PackPromptCandidate candidate,
    required PromptConsumer consumer,
  }) {
    final staged = candidate.staged;
    if (staged == null) return;
    if (candidate.source.classificationOf(consumer) ==
        staged.classificationOf(consumer)) {
      return;
    }
    throw MambaException(
      'The staged output of ${candidate.name} does not preserve the Prompt '
      'view of the reviewed source for the ${_targetLabel(consumer)} target.',
      exitCode: PackProcessStatus.invalidInput.code,
    );
  }

  /// Refuses a Pi target.
  ///
  /// The Pi Prompt installation is not supported: a Pi skill-backed Prompt
  /// is recognized and validated, but it is not installed for Pi.
  void requireNoPiTarget(List<String> targets) {
    for (final target in targets) {
      if (target == 'pi') {
        throw MambaException(
          'A Pi Prompt installation is not supported; the selection is '
          'refused before any installation effect.',
          exitCode: PackProcessStatus.invalidInput.code,
        );
      }
    }
  }

  /// The Prompt consumers of the requested targets.
  ///
  /// The shared target consumes the Prompts of every supported harness.
  static List<PromptConsumer> consumersOf(List<String> targets) => [
    for (final target in targets)
      ...switch (target) {
        'claude' => const <PromptConsumer>[PromptConsumer.claude],
        'codex' => const <PromptConsumer>[PromptConsumer.codex],
        'shared' => const <PromptConsumer>[
          PromptConsumer.claude,
          PromptConsumer.codex,
        ],
        'pi' => const <PromptConsumer>[PromptConsumer.pi],
        _ => throw MambaException(
          'Unsupported Prompt installation target: $target.',
          exitCode: PackProcessStatus.invalidInput.code,
        ),
      },
  ];

  /// The blocking diagnostics of one view.
  String _diagnostics(List<PromptDiagnostic> diagnostics) =>
      diagnostics.map((diagnostic) => diagnostic.message).join(' ');

  /// The target label of one consumer.
  String _targetLabel(PromptConsumer consumer) => switch (consumer) {
    PromptConsumer.claude => 'claude',
    PromptConsumer.codex => 'codex',
    PromptConsumer.pi => 'pi',
  };
}
