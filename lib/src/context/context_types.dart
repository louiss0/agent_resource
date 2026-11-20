import '../harness/harness_id.dart';

/// The portable name contract shared by every context template operation.
final RegExp contextTemplateNamePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

const Set<String> _windowsReservedNames = <String>{
  'con',
  'prn',
  'aux',
  'nul',
  'com1',
  'com2',
  'com3',
  'com4',
  'com5',
  'com6',
  'com7',
  'com8',
  'com9',
  'lpt1',
  'lpt2',
  'lpt3',
  'lpt4',
  'lpt5',
  'lpt6',
  'lpt7',
  'lpt8',
  'lpt9',
};

/// Whether [value] maps cleanly to a regular `<name>.md` template file.
bool isValidContextTemplateName(String value) =>
    contextTemplateNamePattern.hasMatch(value) &&
    !_windowsReservedNames.contains(value);

/// The two output formats shared by every context command.
enum ContextOutputFormat { text, json }

/// The coding harnesses that consume injected context files.
enum ContextHarness implements HarnessWireNamed {
  claude,
  codex,
  pi,
  antigravity;

  @override
  String get wireName => name;
}

/// Whether a context resource belongs to a project or the user's environment.
enum ContextScope { project, user }

/// A harness-recognized context file variant and its CLI spelling.
enum const ContextVariant(final String wireName) {
  standard('standard'),
  local('local'),
  override('override'),
  dotClaude('dot-claude'),
  gemini('gemini'),
  dotAgents('dot-agents'),
}

/// The byte-level action taken when combining a template with a target file.
enum ContextCombineAction { create, append, replace }

/// The observable metadata of one stored context template.
final class const ContextTemplateMetadata({
  required final String name,
  required final String path,
  required final int byteLength,
  required final String sha256,
}) {
  bool get isEmpty => byteLength == 0;

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'path': path,
    'byteLength': byteLength,
    'isEmpty': isEmpty,
    'sha256': sha256,
  };
}

/// The metadata and complete UTF-8 body returned by `context inspect`.
final class const ContextTemplateRead({
  required final ContextTemplateMetadata metadata,
  required final String content,
}) {
  Map<String, Object?> toJson() => <String, Object?>{
    ...metadata.toJson(),
    'content': content,
  };
}
