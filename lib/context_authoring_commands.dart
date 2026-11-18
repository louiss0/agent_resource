import 'dart:io' show Platform;

import 'package:mamba/mamba.dart';

import 'context_read_commands.dart';
import 'src/context/context_types.dart';
import 'src/services/context_template_authoring_service.dart';
import 'src/services/lifecycle_state_service.dart';

final _nameOption = StringOption(
  'name',
  description: 'The context template name to author.',
);
final _bodyFile = FilePathOption(
  'body-file',
  description: 'Read the instruction body from this file.',
);
final _bodyText = StringOption(
  'body-text',
  description: 'Read the instruction body from literal text.',
);
final _editor = StringOption(
  'editor',
  description: 'The editor command used for the instruction draft.',
);
final _planId = StringOption(
  'plan-id',
  description: 'The exact reviewed plan identity required for apply.',
);
final _format = ChoiceOption.withDefault(
  'format',
  choices: ContextOutputFormat.values,
  defaultValue: ContextOutputFormat.text,
);
final _cwd = FolderPathOption('cwd');
final _home = FolderPathOption('home');
final _stateDir = FolderPathOption('state-dir');

const _empty = BooleanFlag(
  'empty',
  description: 'Create a 0-byte template without a draft or an editor.',
);
const _bodyStdin = BooleanFlag(
  'body-stdin',
  description: 'Read the instruction body from buffered standard input.',
);
const _apply = BooleanFlag(
  'apply',
  description: 'Publish the reviewed proposal instead of only planning it.',
);
const _yes = BooleanFlag(
  'yes',
  description: 'Approve the publication without an interactive prompt.',
);
const _dryRun = BooleanFlag(
  'dry-run',
  description: 'Plan without a draft, an editor or any filesystem write.',
);
const _interactive = BooleanFlag(
  'interactive',
  description: 'Allow an interactive name prompt, selector and editor.',
);
const _unattended = BooleanFlag(
  'unattended',
  description: 'Never prompt; supply every required value explicitly.',
);
const _showInstructions = BooleanFlag(
  'show-instructions',
  description: 'Include the instruction body in the report.',
);

const Map<String, List<String>> _createConflicts = <String, List<String>>{
  'empty': ['body-file', 'body-stdin', 'body-text', 'editor'],
  'body-file': ['body-stdin', 'body-text'],
  'body-stdin': ['body-text'],
  'interactive': ['unattended'],
};

const Map<String, List<String>> _editConflicts = <String, List<String>>{
  'body-file': ['body-stdin', 'body-text'],
  'body-stdin': ['body-text'],
  'interactive': ['unattended'],
};

/// The shared authoring behavior of the `context create` and `context edit`
/// command routes.
abstract class ContextAuthoringCommand extends Command with HookRunner {
  ContextAuthoringCommand(
    this._service, {
    required this.create,
    required Map<String, List<String>> conflicts,
  }) : super(
         discretionaryPositionals: [_nameArgument],
         options: <Option<Object?>>[
           _nameOption,
           _bodyFile,
           _bodyText,
           _editor,
           _planId,
           _format,
           _cwd,
           _home,
           _stateDir,
         ],
         flags: <Flag<Object?>>[
           if (create) _empty,
           _bodyStdin,
           _apply,
           _yes,
           _dryRun,
           _interactive,
           _unattended,
           _showInstructions,
         ],
         conflicts: conflicts,
       );

  static final _nameArgument = NormalPositional.optional(
    'name',
    description: 'The context template name to author.',
  );

  final ContextTemplateAuthoringService _service;
  final bool create;

  String? _standardInput;

  @override
  Future<void> preRun(
    ValueOf valueOf,
    MambaReadContext context,
    ProcessedStandardInput? input,
  ) async {
    _standardInput = input?.utf8Text;
  }

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    final format = valueOf(_format);
    final interactive = _resolveInteractive(valueOf, format);
    final result = await _service.run(
      ContextAuthoringRequest(
        command: name == 'create' ? 'context create' : 'context edit',
        create: create,
        positionalName: valueOf(_nameArgument),
        optionName: valueOf(_nameOption),
        interactive: interactive,
        unattended: valueOf(_unattended),
        empty: create && valueOf(_empty),
        bodyFile: valueOf(_bodyFile),
        bodyStdin: valueOf(_bodyStdin),
        bodyText: valueOf(_bodyText),
        standardInput: _standardInput,
        editorChoice: valueOf(_editor),
        planId: valueOf(_planId),
        apply: valueOf(_apply),
        yes: valueOf(_yes),
        dryRun: valueOf(_dryRun),
        showInstructions: valueOf(_showInstructions),
        options: _options(valueOf),
      ),
    );
    return renderContextResult(result, format);
  }

  bool _resolveInteractive(ValueOf valueOf, ContextOutputFormat format) {
    final explicit = valueOf(_interactive);
    final unattended = valueOf(_unattended);
    if (explicit && format == ContextOutputFormat.json) {
      throw MambaException(
        'INTERACTIVE_JSON_REFUSED: --interactive cannot be used with '
        '--format json.',
        exitCode: 4,
      );
    }
    if (explicit && !_service.hasTerminal) {
      throw MambaException(
        'INTERACTIVE_TERMINAL_REFUSED: No usable terminal for an interactive '
        'session.',
        exitCode: 4,
      );
    }
    if (unattended || format == ContextOutputFormat.json) return false;
    return explicit || _service.hasTerminal;
  }

  LifecycleOptions _options(ValueOf valueOf) => LifecycleOptions(
    processWorkingDirectory: _service.fileSystem.currentDirectory.path,
    environment: Map<String, String>.unmodifiable(Platform.environment),
    scope: LifecycleScope.user,
    cwd: valueOf(_cwd),
    home: valueOf(_home),
    stateDir: valueOf(_stateDir),
    dryRun: valueOf(_dryRun),
    approved: valueOf(_yes),
  );
}

/// Creates a named, user-scope context template.
final class ContextCreateCommand extends ContextAuthoringCommand {
  ContextCreateCommand(super.service)
    : super(create: true, conflicts: _createConflicts);

  @override
  String get name => 'create';

  @override
  String get shortDescription => 'Create a named context template.';
}

/// Replaces the body of one stored context template.
final class ContextEditCommand extends ContextAuthoringCommand {
  ContextEditCommand(super.service)
    : super(create: false, conflicts: _editConflicts);

  @override
  String get name => 'edit';

  @override
  String get shortDescription => 'Edit a stored context template.';
}
