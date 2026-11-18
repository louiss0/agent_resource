import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;

import '../context/context_template_store.dart';
import '../context/context_types.dart';
import 'lifecycle_state_service.dart';

/// Application-facing façade over the user-scope context template store.
final class ContextTemplateService {
  ContextTemplateService({
    fslib.FileSystem? fileSystem,
    ContextTemplateStore? store,
  }) : fileSystem = fileSystem ?? const local.LocalFileSystem(),
       store =
           store ??
           ContextTemplateStore(
             fileSystem: fileSystem ?? const local.LocalFileSystem(),
           );

  final fslib.FileSystem fileSystem;
  final ContextTemplateStore store;

  List<ContextTemplateMetadata> list(LifecycleOptions options) =>
      store.list(options);

  ContextTemplateRead inspect(LifecycleOptions options, String name) =>
      store.inspect(options, name);
}

/// Builds the shared process context for a context command invocation.
LifecycleOptions contextLifecycleOptions({
  required fslib.FileSystem fileSystem,
  Map<String, String> environment = const <String, String>{},
  String? cwd,
  String? home,
  String? stateDir,
  String? projectRoot,
  String? claudeConfigDir,
  String? codexHome,
  String? piAgentDir,
  bool dryRun = false,
  bool approved = false,
}) => LifecycleOptions(
  processWorkingDirectory: fileSystem.currentDirectory.path,
  environment: environment,
  scope: LifecycleScope.user,
  cwd: cwd,
  home: home,
  stateDir: stateDir,
  projectRoot: projectRoot,
  claudeConfigDir: claudeConfigDir,
  codexHome: codexHome,
  piAgentDir: piAgentDir,
  dryRun: dryRun,
  approved: approved,
);
