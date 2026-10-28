import 'dart:io';

import 'package:mamba/mamba.dart';

import 'installation_command_support.dart';
import 'lifecycle.dart' show LifecycleOutputFormat;
import 'src/installation/installation_plan.dart';
import 'src/installation/installation_request.dart';
import 'src/installation/resource_catalog.dart';
import 'src/services/acquisition_service.dart';
import 'src/services/agent_installation_service.dart';
import 'src/services/lifecycle_state_service.dart';

final class AgentInstallCommand extends Command {
  AgentInstallCommand(this._installation)
    : super(
        discretionaryPositionals: [_source],
        options: [
          _resources,
          _targets,
          _profile,
          _scope,
          _ref,
          _subpath,
          _sourceKind,
          _format,
          _cwd,
          _projectRoot,
          _home,
          _claude,
          _codex,
          _piAgentDir,
          _state,
          _readRoots,
          _destination,
          _harness,
          _method,
          _output,
        ],
        flags: const [_allResources, _dryRun, _yes, _interactive],
        conflicts: const {
          'resource': ['all-resources'],
        },
        longDescription:
            'Install explicitly profiled native Agent definitions as managed '
            'file copies. Sources are exact native files or curated '
            'agent-resources.toml collections; no heuristic scanning, '
            'conversion, links, role registration, parent changes, dependency '
            'installation, or runtime probes occur. Interactive project scope '
            'is the default on a usable text terminal. JSON and unattended '
            'execution require explicit source, selection, target, scope, '
            'exact-resource profile/kind where applicable, and --yes unless '
            '--dry-run. --yes approves only the current final plan.',
      );

  final AgentInstallationService _installation;

  static final _source = NormalPositional.optional(
    'source',
    description: 'Local path, Git locator, direct download, or archive.',
  );
  static final _resources = RepeatableStringOption(
    'resource',
    description: 'Exact catalog ID; repeat for multiple entries.',
  );
  static final _targets = RepeatableChoiceOption(
    'target',
    InstallationTarget.values,
    description: 'Consuming harness filter: claude, codex, or pi.',
  );
  static final _profile = ChoiceOption(
    'profile',
    choices: NativeAgentProfile.values,
    description: 'Direct-file profile: claude, codex, or pi-common.',
  );
  static final _scope = ChoiceOption(
    'scope',
    choices: const [LifecycleScope.project, LifecycleScope.user],
    description: 'Installation scope; project is the interactive default.',
  );
  static final _ref = StringOption(
    'ref',
    description: 'Git branch, tag, or commit; Git sources only.',
  );
  static final _subpath = StringOption(
    'subpath',
    description: 'Explicit source-relative root; never broadened to a scan.',
  );
  static final _sourceKind = ChoiceOption(
    'source-kind',
    choices: AcquisitionSourceKind.values,
    description: 'Explicit collection or exact-resource intent.',
  );
  static final _format = ChoiceOption.withDefault(
    'format',
    choices: LifecycleOutputFormat.values,
    defaultValue: LifecycleOutputFormat.text,
  );
  static final _cwd = FolderPathOption('cwd');
  static final _projectRoot = FolderPathOption('project-root');
  static final _home = FolderPathOption('home');
  static final _claude = FolderPathOption('claude-config-dir');
  static final _codex = FolderPathOption('codex-home');
  static final _piAgentDir = FolderPathOption('pi-agent-dir');
  static final _state = FolderPathOption('state-dir');
  static final _readRoots = RepeatableFolderPathOption('read-root');
  static const _allResources = BooleanFlag(
    'all-resources',
    description: 'Select every curated entry after target filtering.',
  );
  static const _dryRun = BooleanFlag('dry-run');
  static const _yes = BooleanFlag('yes');

  // Retired inputs remain parseable solely to provide migration guidance.
  static final _destination = StringOption('destination', hidden: true);
  static final _harness = StringOption('harness', hidden: true);
  static final _method = StringOption('method', hidden: true);
  static final _output = StringOption('output', hidden: true);
  static const _interactive = BooleanFlag('interactive', hidden: true);

  @override
  String get name => 'install';

  @override
  String get shortDescription =>
      'Install curated or exact native Agent copies.';

  @override
  Future<String> run(ValueOf valueOf, List<String> args) async {
    _rejectRetired(valueOf);
    final format = valueOf(_format);
    final source = valueOf(_source);
    if (source != null && source.trim().isEmpty) {
      throw MambaException('The installation source must not be blank.');
    }
    final result = await _installation.run(
      InstallationWorkflowRequest(
        source: source,
        options: LifecycleOptions(
          processWorkingDirectory: Directory.current.path,
          environment: Map<String, String>.unmodifiable(Platform.environment),
          scope: valueOf(_scope) ?? LifecycleScope.project,
          cwd: valueOf(_cwd),
          projectRoot: valueOf(_projectRoot),
          home: valueOf(_home),
          claudeConfigDir: valueOf(_claude),
          codexHome: valueOf(_codex),
          piAgentDir: valueOf(_piAgentDir),
          stateDir: valueOf(_state),
          readRoots: valueOf(_readRoots) ?? const <String>[],
          dryRun: valueOf(_dryRun),
          approved: valueOf(_yes),
        ),
        sourceKind: valueOf(_sourceKind),
        resourceIds: (valueOf(_resources) ?? const <String>[]).toSet().toList(),
        allResources: valueOf(_allResources),
        targets: (valueOf(_targets) ?? const <InstallationTarget>[])
            .toSet()
            .toList(),
        method: null,
        profile: valueOf(_profile),
        ref: valueOf(_ref),
        subpath: valueOf(_subpath),
        scopeExplicit: valueOf(_scope) != null,
      ),
      interactive:
          format == LifecycleOutputFormat.text &&
          _installation.hasInteractiveTerminal,
    );
    return renderInstallationResult(result, format);
  }

  void _rejectRetired(ValueOf valueOf) {
    if (valueOf(_destination) != null) {
      throw MambaException(
        '--destination is retired for agent install. Native placement follows '
        '--profile and --target; do not use a shared-destination override.',
      );
    }
    if (valueOf(_harness) != null) {
      throw MambaException(
        '--harness is retired for agent install. Use --profile for a direct '
        'file and --target for consuming-harness selection.',
      );
    }
    if (valueOf(_method) != null) {
      throw MambaException(
        'Agents are copy-only and do not accept --method. Remove it; Skill '
        'source-link/canonical methods do not apply to Agent definitions.',
      );
    }
    if (valueOf(_output) != null) {
      throw MambaException(
        '--output is no longer part of agent install. The validated source '
        'basename is preserved at the application-owned native destination.',
      );
    }
    if (valueOf(_interactive)) {
      throw MambaException(
        '--interactive is retired: interactive installation is the default on '
        'a usable text terminal. JSON and unattended mode stay explicit.',
      );
    }
  }
}
