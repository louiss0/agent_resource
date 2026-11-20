import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:mamba/mamba.dart';

import '../../lifecycle.dart' show LifecycleOutputFormat;
import '../services/guided_authoring_service.dart';
import '../services/lifecycle_state_service.dart';
import 'authoring_inputs.dart';
import 'guided_create_fields.dart';

/// The shared base of the guided create commands.
///
/// The base owns the named native vocabulary, the interaction boundary and
/// the rendering of the reviewed proposal. A concrete command owns its
/// resource kind, its supported profiles and its own long description.
abstract class GuidedCreateCommand extends Command with HookRunner {
  GuidedCreateCommand({
    required this.kind,
    required this.guided,
    List<Option<Object?>> options = const <Option<Object?>>[],
    List<Flag<Object?>> flags = const <Flag<Object?>>[],
    List<DiscretionaryPositional<Object?>> positionals =
        const <DiscretionaryPositional<Object?>>[],
    Map<String, List<String>>? conflicts,
    this.terminal,
    super.longDescription,
  }) : super(
         discretionaryPositionals: positionals,
         options: <Option<Object?>>[
           ...GuidedCreateCommand.sharedOptions,
           ...options,
         ],
         flags: <Flag<Object?>>[...GuidedCreateCommand.sharedFlags, ...flags],
         conflicts: conflicts ?? GuidedCreateCommand.sharedConflicts,
       );

  /// The native resource kind of the command.
  final AuthoringKind kind;

  /// The guided authoring flow of the command.
  final GuidedAuthoringService guided;

  /// Whether the session of the process has a usable terminal.
  ///
  /// The check is injected so a test can state the capability of the
  /// session instead of depending on the terminal of the test runner.
  final bool Function()? terminal;

  /// The buffered standard input of the current invocation.
  String? _standardInput;

  /// The file system of the run.
  fslib.FileSystem get fileSystem => guided.fileSystem;

  /// The shared named options of the guided create commands.
  static final List<Option<Object?>> sharedOptions = <Option<Object?>>[
    GuidedCreateFields.profile,
    GuidedCreateFields.harness,
    GuidedCreateFields.scope,
    GuidedCreateFields.format,
    GuidedCreateFields.cwd,
    GuidedCreateFields.projectRoot,
    GuidedCreateFields.home,
    GuidedCreateFields.claudeConfigDir,
    GuidedCreateFields.codexHome,
    GuidedCreateFields.piAgentDir,
    GuidedCreateFields.geminiDir,
    GuidedCreateFields.stateDir,
    GuidedCreateFields.bodyFile,
    GuidedCreateFields.bodyText,
    GuidedCreateFields.name,
    GuidedCreateFields.description,
    GuidedCreateFields.model,
    GuidedCreateFields.tools,
    GuidedCreateFields.allowedTools,
    GuidedCreateFields.disallowedTools,
    GuidedCreateFields.metadata,
    GuidedCreateFields.skills,
    GuidedCreateFields.argumentHint,
    GuidedCreateFields.license,
    GuidedCreateFields.compatibility,
    GuidedCreateFields.output,
    GuidedCreateFields.planId,
    GuidedCreateFields.editor,
  ];

  /// The shared flags of the guided create commands.
  static final List<Flag<Object?>> sharedFlags = <Flag<Object?>>[
    GuidedCreateFields.bodyStdin,
    GuidedCreateFields.mainAgent,
    GuidedCreateFields.manage,
    GuidedCreateFields.apply,
    GuidedCreateFields.yes,
    GuidedCreateFields.dryRun,
    GuidedCreateFields.interactive,
    GuidedCreateFields.unattended,
    GuidedCreateFields.showInstructions,
  ];

  /// The incompatible explicit occurrences of the guided create commands.
  static const Map<String, List<String>> sharedConflicts =
      GuidedCreateFields.conflicts;

  /// The native profiles that the command supports.
  List<AuthoringProfile> get supportedProfiles;

  /// The canonical command path of the create route.
  String get commandPath;

  /// The authoring operation performed by this route.
  AuthoringOperation get operation => AuthoringOperation.create;

  /// The selected source of an edit, clone or compose route.
  String? sourcePath(ValueOf valueOf) => null;

  /// The question that confirms the publication.
  ///
  /// The guided flow and the bound-role route share one confirmation, so a
  /// caller never sees two different consent questions.
  GuidedConfirmationRequest get confirmation =>
      guided.confirmation ?? defaultGuidedConfirmation;

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(GuidedCreateFields.format);
    final interactive = resolveInteractive(valueOf, format);
    final options = buildOptions(valueOf);
    final inputs = buildInputs(valueOf);
    final outcome = await guided.run(
      GuidedAuthoringRequest(
        command: commandPath,
        inputs: inputs,
        apply: valueOf(GuidedCreateFields.apply),
        planId: valueOf(GuidedCreateFields.planId),
        interactive: interactive,
        editorChoice: valueOf(GuidedCreateFields.editor),
        showInstructions: valueOf(GuidedCreateFields.showInstructions),
        standardInput: _standardInput,
      ),
      options,
    );
    final rendered = renderOutcome(outcome, format);
    if (outcome.rejected) {
      throw MambaException(rendered, exitCode: 4);
    }
    return rendered;
  }

  @override
  Future<void> preRun(
    ValueOf valueOf,
    MambaReadContext context,
    ProcessedStandardInput? input,
  ) async {
    // The buffered standard input of this invocation. It is used only when
    // the body selection is the explicitly selected standard input.
    _standardInput = input?.utf8Text;
  }

  /// Whether the run may ask the operator a question.
  ///
  /// A machine-readable output never prompts, and an unattended run never
  /// prompts. The guided flow is the default on a usable terminal.
  bool resolveInteractive(ValueOf valueOf, LifecycleOutputFormat format) {
    final explicit = valueOf(GuidedCreateFields.interactive);
    final unattended = valueOf(GuidedCreateFields.unattended);
    if (explicit && unattended) {
      throw MambaException(
        '--interactive and --unattended conflict.',
        exitCode: 4,
      );
    }
    if (explicit && format == LifecycleOutputFormat.json) {
      throw MambaException(
        '--interactive and --format json conflict.',
        exitCode: 4,
      );
    }
    final hasTerminal = terminal?.call() ?? guided.hasTerminal;
    if (explicit && !hasTerminal) {
      throw MambaException(
        'The guided flow needs a usable terminal; supply every value '
        'explicitly with --unattended.',
        exitCode: 4,
      );
    }
    if (unattended || format == LifecycleOutputFormat.json) return false;
    return explicit || hasTerminal;
  }

  /// The lifecycle context of the run.
  LifecycleOptions buildOptions(ValueOf valueOf) => LifecycleOptions(
    processWorkingDirectory: fileSystem.currentDirectory.path,
    environment: Map<String, String>.unmodifiable(Platform.environment),
    scope: valueOf(GuidedCreateFields.scope),
    cwd: valueOf(GuidedCreateFields.cwd),
    projectRoot: valueOf(GuidedCreateFields.projectRoot),
    home: valueOf(GuidedCreateFields.home),
    claudeConfigDir: valueOf(GuidedCreateFields.claudeConfigDir),
    codexHome: valueOf(GuidedCreateFields.codexHome),
    piAgentDir: valueOf(GuidedCreateFields.piAgentDir),
    geminiDir: valueOf(GuidedCreateFields.geminiDir),
    stateDir: valueOf(GuidedCreateFields.stateDir),
    dryRun: valueOf(GuidedCreateFields.dryRun),
    approved: valueOf(GuidedCreateFields.yes),
  );

  /// The named native inputs of the run.
  AuthoringInputs buildInputs(ValueOf valueOf) {
    final profile =
        valueOf(GuidedCreateFields.profile) ??
        valueOf(GuidedCreateFields.harness);
    if (profile == null) {
      throw MambaException(
        'Select the native profile explicitly with --profile or --harness '
        '(${supportedProfiles.map((value) => value.name).join(', ')}).',
        exitCode: 4,
      );
    }
    final matrix = NativeFieldMatrix.forKind(kind, profile);
    final skills = valueOf(GuidedCreateFields.skills);
    final skillsSpec = matrix.specFor('skills');
    if (skills != null &&
        skillsSpec != null &&
        skillsSpec.valueKind == NativeFieldValueKind.map) {
      throw MambaException(
        'The ${profile.name} ${kind.name} profile declares skills as a '
        'native table; the authoring input accepts a list of skill names '
        'only where the native form is a list.',
        exitCode: 4,
      );
    }
    return parseAuthoringInputs(
      operation: operation,
      kind: kind,
      profile: profile,
      scope: valueOf(GuidedCreateFields.scope),
      sourcePath: sourcePath(valueOf),
      bodyFile: valueOf(GuidedCreateFields.bodyFile),
      bodyStandardInput: valueOf(GuidedCreateFields.bodyStdin),
      bodyText: valueOf(GuidedCreateFields.bodyText),
      fields: GuidedCreateFields.nativeFields(
        name: valueOf(GuidedCreateFields.name),
        description: valueOf(GuidedCreateFields.description),
        model: valueOf(GuidedCreateFields.model),
        tools: valueOf(GuidedCreateFields.tools),
        mainAgent: valueOf(GuidedCreateFields.mainAgent),
        skills: skills,
        allowedTools: valueOf(GuidedCreateFields.allowedTools),
        disallowedTools: valueOf(GuidedCreateFields.disallowedTools),
        metadata: valueOf(GuidedCreateFields.metadata),
        argumentHint: valueOf(GuidedCreateFields.argumentHint),
        license: valueOf(GuidedCreateFields.license),
        compatibility: valueOf(GuidedCreateFields.compatibility),
      ),
      manage: valueOf(GuidedCreateFields.manage),
      output: valueOf(GuidedCreateFields.output),
      allowDeferredBody: true,
    );
  }

  /// The rendered outcome of the run.
  String renderOutcome(
    GuidedAuthoringOutcome outcome,
    LifecycleOutputFormat format,
  ) {
    if (format == LifecycleOutputFormat.json) {
      return encodeGuidedOutcome(outcome);
    }
    final result = LifecycleResult(
      command: outcome.command,
      outcome: outcome.outcome,
      data: outcome.data,
      diagnostics: outcome.diagnostics,
    );
    return result.renderText();
  }
}
