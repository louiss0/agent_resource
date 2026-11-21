import 'dart:convert';
import 'dart:io';

import 'package:file/file.dart' as fslib;
import 'package:file/local.dart' as local;
import 'package:mamba/mamba.dart';
import 'package:yaml/yaml.dart';
// The public loader builds the complete graph before exposing it. The event
// parser permits bounded, scalar-aware preflight before that allocation.
// ignore: implementation_imports
import 'package:yaml/src/parser.dart' as yaml_parser;
// ignore: implementation_imports
import 'package:yaml/src/event.dart' as yaml_event;

export '../prompt/prompt_contracts.dart';

import '../prompt/prompt_contracts.dart';
import '../prompt_resource_path_scanner.dart';
import '../skill_files.dart';

/// Inspects explicitly selected native files only. No harness or template is run.
/// Form and optional consumer are caller context, not inferred from placement.
interface class const PromptInspectionService({
  final fslib.FileSystem fs = const local.LocalFileSystem(),
}) {
  static const _maxFile = 1048576;
  static const _maxYaml = 65536;

  /// The native frontmatter fields accepted for one form and consumer.
  ///
  /// The set is the native surface of that form. A field outside it is
  /// diagnosed instead of being silently carried as portable.
  static Set<String> allowedFields(PromptForm form, PromptConsumer consumer) {
    if (form == PromptForm.template) {
      return const <String>{'description', 'argument-hint'};
    }
    if (consumer == PromptConsumer.claude) {
      return const <String>{
        'name',
        'description',
        'license',
        'compatibility',
        'metadata',
        'allowed-tools',
        'disallowed-tools',
        'disable-model-invocation',
        'user-invocable',
        'argument-hint',
        'arguments',
        'model',
        'context',
        'agent',
        'hooks',
        'effort',
      };
    }
    return const <String>{
      'name',
      'description',
      'license',
      'compatibility',
      'metadata',
      'allowed-tools',
      'disable-model-invocation',
    };
  }

  Future<PromptInspection> inspect(
    String source, {
    required PromptForm form,
    PromptConsumer? consumer,
    PromptPlacement placement = PromptPlacement.unknown,
  }) async {
    if (source.trim().isEmpty) throw ArgumentError.value(source, 'source');
    final path = fs.path.normalize(fs.path.absolute(source));
    final diagnostics = <PromptDiagnostic>[];
    void add(
      String code,
      String message,
      String at, [
      int? line,
      int? column,
    ]) => diagnostics.add((
      code: code,
      message: message,
      path: at,
      line: line,
      column: column,
    ));
    // A notFound result can also mean an inaccessible or unstable entry.
    // Confirm absence by streaming the already-checked parent, never by an
    // unbounded synchronous listing. Each confirmation is independently capped.
    Future<FileSystemEntityType> entityType(String item) async {
      FileSystemEntityType rawType() {
        try {
          return fs.typeSync(item, followLinks: false);
        } on FileSystemException catch (error) {
          throw MambaException(
            'Could not inspect filesystem path $item: ${error.message}',
          );
        }
      }

      final type = rawType();
      if (type != FileSystemEntityType.notFound) return type;
      final parent = fs.path.dirname(item);
      if (fs.path.equals(parent, item)) {
        throw MambaException('Could not confirm filesystem root: $item');
      }
      var entries = 0;
      try {
        await for (final child
            in fs.directory(parent).list(followLinks: false)) {
          if (++entries > 1024) {
            throw MambaException(
              'Prompt directory exceeds the 1024-entry inspection limit: $parent',
            );
          }
          if (fs.path.equals(fs.path.normalize(child.path), item)) {
            final observed = rawType();
            if (observed == FileSystemEntityType.notFound) {
              throw MambaException(
                'Could not classify listed filesystem path: $item',
              );
            }
            return observed;
          }
        }
      } on FileSystemException catch (error) {
        throw MambaException(
          'Could not inspect filesystem directory $parent: ${error.message}',
        );
      }
      return FileSystemEntityType.notFound;
    }

    // Check every component before accessing any descendant. No links are followed.
    var part = path;
    final ancestors = <String>[];
    while (true) {
      ancestors.add(part);
      final parent = fs.path.dirname(part);
      if (parent == part) break;
      part = parent;
    }
    for (final item in ancestors.reversed) {
      final type = await entityType(item);
      if (type == FileSystemEntityType.link) {
        throw MambaException('Prompt source contains a symbolic link: $item');
      }
      if (type == FileSystemEntityType.notFound) {
        throw MambaException('Prompt source does not exist: $item');
      }
    }
    final sourceType = await entityType(path);
    final expected = form == PromptForm.skill
        ? FileSystemEntityType.directory
        : FileSystemEntityType.file;
    if (sourceType != expected) {
      throw MambaException(
        'Prompt source has the wrong filesystem type: $path',
      );
    }
    final marker = form == PromptForm.skill
        ? fs.path.join(path, 'SKILL.md')
        : path;
    Future<String?> readFile(String file, {int limit = _maxFile}) async {
      final type = await entityType(file);
      if (type != FileSystemEntityType.file) {
        add('FILE_TYPE', 'Expected a regular non-link file.', file);
        return null;
      }
      final bytes = readBoundedSkillMarker(file, maxBytes: limit, fs: fs);
      if (bytes.length > limit) {
        add('FILE_SIZE_LIMIT', 'File exceeds the inspection byte limit.', file);
        return null;
      }
      try {
        return utf8.decode(bytes, allowMalformed: false);
      } on FormatException {
        add('UTF8_INVALID', 'File is not valid UTF-8.', file);
        return null;
      }
    }

    Map<Object?, Object?>? yamlMap(String text, String file) {
      if (utf8.encode(text).length > _maxYaml) {
        add('YAML_SIZE_LIMIT', 'YAML exceeds the inspection byte limit.', file);
        return null;
      }
      // The event parser is iterative and recognizes real YAML tokens, not
      // lookalikes in quoted or block scalars. Reject aliases before loading
      // the graph; node and nesting limits also bound loader recursion.
      try {
        final parser = yaml_parser.Parser(text);
        var depth = 0;
        var nodes = 0;
        while (!parser.isDone) {
          final event = parser.parse();
          if (event is yaml_event.AliasEvent) {
            add('YAML_ALIAS', 'YAML aliases are unsupported.', file);
            return null;
          }
          if (event is yaml_event.ScalarEvent ||
              event is yaml_event.MappingStartEvent ||
              event is yaml_event.SequenceStartEvent) {
            nodes++;
          }
          if (event is yaml_event.MappingStartEvent ||
              event is yaml_event.SequenceStartEvent) {
            depth++;
          }
          if (event.type == yaml_event.EventType.mappingEnd ||
              event.type == yaml_event.EventType.sequenceEnd) {
            depth--;
          }
          if (depth > 32 || nodes > 4096) {
            add('YAML_BUDGET', 'YAML exceeds the node or depth limit.', file);
            return null;
          }
        }
      } on Exception {
        add('YAML_INVALID', 'Invalid YAML.', file);
        return null;
      }
      Object? value;
      try {
        value = loadYaml(text);
      } on Exception {
        add('YAML_INVALID', 'Invalid YAML.', file);
        return null;
      }
      var count = 0;
      bool bounded(Object? node, int depth) {
        if (++count > 4096 || depth > 32) return false;
        if (node is Map) {
          for (final e in node.entries) {
            if (!bounded(e.key, depth + 1) || !bounded(e.value, depth + 1)) {
              return false;
            }
          }
        } else if (node is List) {
          for (final e in node) {
            if (!bounded(e, depth + 1)) return false;
          }
        }
        return true;
      }

      if (!bounded(value, 0)) {
        add('YAML_BUDGET', 'YAML exceeds the node or depth limit.', file);
        return null;
      }
      if (value is! Map) {
        add('YAML_MAPPING', 'YAML must be a mapping.', file);
        return null;
      }
      return Map<Object?, Object?>.from(value);
    }

    final content = await readFile(marker);
    Map<Object?, Object?>? front;
    String body = '';
    var bodyLine = 1;
    if (content != null) {
      final lines = content.split('\n');
      if (lines.first.trimRight() == '---') {
        var end = 1;
        while (end < lines.length && lines[end].trimRight() != '---') {
          end++;
        }
        if (end == lines.length) {
          add(
            'FRONTMATTER_UNTERMINATED',
            'Frontmatter has no closing delimiter.',
            marker,
          );
        } else {
          front = yamlMap(lines.sublist(1, end).join('\n'), marker);
          body = lines.sublist(end + 1).join('\n');
          bodyLine = end + 2;
        }
      } else if (form == PromptForm.skill) {
        add('FRONTMATTER_MISSING', 'Skill frontmatter is required.', marker);
      } else {
        front = {};
        body = content;
      }
    }
    final malformed = front == null;
    final fields = <String, Object?>{};
    if (front != null) {
      for (final entry in front.entries) {
        if (entry.key is String) {
          fields[entry.key as String] = entry.value;
        } else {
          add('FIELD_KEY', 'Field names must be strings.', marker);
        }
      }
    }
    bool? codexControl = false;
    final sidecarFields = <String, Object?>{};

    Future<List<FileSystemEntity>> boundedEntries(String directory) async {
      final entries = <FileSystemEntity>[];
      try {
        await for (final entry
            in fs.directory(directory).list(followLinks: false)) {
          if (entries.length == 1024) {
            throw MambaException(
              'Prompt directory exceeds the 1024-entry inspection limit: $directory',
            );
          }
          entries.add(entry);
        }
      } on FileSystemException catch (error) {
        throw MambaException(
          'Could not inspect prompt directory $directory: ${error.message}',
        );
      }
      return entries..sort((a, b) => a.path.compareTo(b.path));
    }

    if (form == PromptForm.skill) {
      final entries = await boundedEntries(path);
      for (final entry in entries) {
        final name = fs.path.basename(entry.path);
        if (name == 'SKILL.md') continue;
        final type = await entityType(entry.path);
        if (name != 'agents' || type != FileSystemEntityType.directory) {
          if (name == 'agents') codexControl = null;
          add(
            'EXTRA_ENTRY',
            'Only SKILL.md and agents/openai.yaml are permitted.',
            entry.path,
          );
          continue;
        }
        final sideEntries = await boundedEntries(entry.path);
        if (sideEntries.isEmpty) {
          add(
            'EXTRA_ENTRY',
            'The agents directory requires openai.yaml.',
            entry.path,
          );
        }
        for (final side in sideEntries) {
          if (fs.path.basename(side.path) != 'openai.yaml') {
            add(
              'EXTRA_ENTRY',
              'Only agents/openai.yaml is permitted.',
              side.path,
            );
            continue;
          }
          final sidecarStart = diagnostics.length;
          var explicitControl = false;
          final text = await readFile(side.path, limit: _maxYaml);
          final map = text == null ? null : yamlMap(text, side.path);
          if (map == null) {
            codexControl = null;
            continue;
          }
          for (final entry in map.entries) {
            if (entry.key is String) {
              sidecarFields[entry.key as String] = entry.value;
            }
          }
          for (final key in map.keys) {
            if (!const ['interface', 'policy', 'dependencies'].contains(key)) {
              add('SIDECAR_FIELD', 'Unsupported sidecar field.', side.path);
            }
          }
          for (final section in const ['interface', 'policy', 'dependencies']) {
            if (map.containsKey(section) && map[section] is! Map) {
              add('SIDECAR_TYPE', '$section must be a mapping.', side.path);
            }
          }
          final policy = map['policy'];
          if (map.containsKey('policy') && policy is! Map) codexControl = null;
          if (policy is Map) {
            for (final key in policy.keys) {
              if (key != 'allow_implicit_invocation') {
                add('SIDECAR_FIELD', 'Unsupported policy field.', side.path);
              }
            }
            if (policy.containsKey('allow_implicit_invocation') &&
                policy['allow_implicit_invocation'] is! bool) {
              add(
                'SIDECAR_TYPE',
                'allow_implicit_invocation must be a boolean.',
                side.path,
              );
            }
            final control = policy['allow_implicit_invocation'];
            explicitControl =
                policy.containsKey('allow_implicit_invocation') &&
                control is bool;
            codexControl = !policy.containsKey('allow_implicit_invocation')
                ? false
                : control is bool
                ? !control
                : null;
          }
          final interface = map['interface'];
          if (interface is Map) {
            for (final e in interface.entries) {
              if (!const [
                    'display_name',
                    'short_description',
                    'icon_small',
                    'icon_large',
                    'brand_color',
                    'default_prompt',
                  ].contains(e.key) ||
                  e.value is! String) {
                add(
                  'SIDECAR_FIELD',
                  'Unsupported or invalid interface field.',
                  side.path,
                );
              }
            }
          }
          final dependencies = map['dependencies'];
          if (dependencies is Map) {
            for (final e in dependencies.entries) {
              if (e.key != 'tools' || e.value is! List) {
                add(
                  'SIDECAR_FIELD',
                  'Unsupported or invalid dependencies field.',
                  side.path,
                );
                continue;
              }
              // Codex discards dependencies without usable identity fields.
              // A validated sidecar must not silently accept those declarations.
              bool dependencyIdentity(Object? value, int maxLength) {
                if (value is! String) return false;
                final normalized = value.trim().split(RegExp(r'\s+')).join(' ');
                return normalized.isNotEmpty &&
                    normalized.runes.length <= maxLength;
              }

              for (final tool in e.value as List) {
                if (tool is! Map ||
                    !dependencyIdentity(tool['type'], 64) ||
                    !dependencyIdentity(tool['value'], 1024) ||
                    tool.entries.any(
                      (e) =>
                          !const [
                            'type',
                            'value',
                            'description',
                            'transport',
                            'url',
                          ].contains(e.key) ||
                          e.value is! String,
                    )) {
                  add('SIDECAR_FIELD', 'Invalid tool dependency.', side.path);
                }
              }
            }
          }
          if (diagnostics.length != sidecarStart && !explicitControl) {
            codexControl = null;
          }
        }
      }
    }
    final sharedDiagnostics = List<PromptDiagnostic>.of(diagnostics);
    final flagValue = fields['disable-model-invocation'];
    final bool? flag = malformed
        ? null
        : !fields.containsKey('disable-model-invocation')
        ? false
        : flagValue is bool
        ? flagValue
        : null;

    Object? freeze(Object? value) {
      if (value is Map) {
        return Map<Object?, Object?>.unmodifiable(
          value.map((key, item) => MapEntry(freeze(key), freeze(item))),
        );
      }
      if (value is List) return List<Object?>.unmodifiable(value.map(freeze));
      return value;
    }

    PromptView build(PromptConsumer profile) {
      diagnostics.clear();
      final control = profile == PromptConsumer.codex ? codexControl : flag;
      final classification = form == PromptForm.template
          ? (profile == PromptConsumer.pi && consumer == PromptConsumer.pi
                ? PromptClassification.prompt
                : PromptClassification.unclassified)
          : control == null || (malformed && control != true)
          ? PromptClassification.malformed
          : control
          ? PromptClassification.prompt
          : PromptClassification.nonPrompt;
      for (final diagnostic in sharedDiagnostics) {
        final promptOnly = diagnostic.code == 'EXTRA_ENTRY';
        final sidecar = fs.path.basename(diagnostic.path) == 'openai.yaml';
        if (promptOnly && classification != PromptClassification.prompt) {
          continue;
        }
        if (sidecar &&
            classification != PromptClassification.prompt &&
            profile != PromptConsumer.codex) {
          continue;
        }
        diagnostics.add(diagnostic);
      }
      if (form == PromptForm.template &&
          profile == PromptConsumer.pi &&
          fs.path.extension(path).toLowerCase() != '.md') {
        add('TEMPLATE_EXTENSION', 'Pi templates must be Markdown files.', path);
      }
      if (front != null) {
        final allowed = allowedFields(form, profile);
        for (final key in fields.keys) {
          if (!allowed.contains(key)) {
            add('UNKNOWN_FIELD', 'Unsupported native field.', marker);
          }
        }
        for (final e in fields.entries) {
          if (const {
                'disable-model-invocation',
                'user-invocable',
              }.contains(e.key) &&
              e.value is! bool) {
            add('FIELD_TYPE', '${e.key} must be a boolean.', marker);
          }
          if (const {
                'name',
                'description',
                'license',
                'compatibility',
                'argument-hint',
                'model',
                'context',
                'agent',
                'effort',
              }.contains(e.key) &&
              e.value is! String) {
            add('FIELD_TYPE', '${e.key} must be a string.', marker);
          }
        }
        bool stringOrStringList(Object? value) =>
            value is String ||
            (value is List && value.every((item) => item is String));
        for (final key in const [
          'allowed-tools',
          'disallowed-tools',
          'arguments',
        ]) {
          if (fields.containsKey(key) && !stringOrStringList(fields[key])) {
            add(
              'FIELD_TYPE',
              '$key must be a string or list of strings.',
              marker,
            );
          }
        }
        if (form == PromptForm.skill && fields['compatibility'] is String) {
          final length = (fields['compatibility'] as String).runes.length;
          if (length == 0 || length > 500) {
            add(
              'COMPATIBILITY_LENGTH',
              'compatibility must contain 1?500 characters.',
              marker,
            );
          }
        }
        if (form == PromptForm.skill &&
            profile != PromptConsumer.claude &&
            fields.containsKey('allowed-tools') &&
            fields['allowed-tools'] is! String) {
          add('FIELD_TYPE', 'allowed-tools must be a string.', marker);
        }
        if (fields.containsKey('metadata')) {
          final metadata = fields['metadata'];
          if (metadata is! Map ||
              metadata.entries.any(
                (e) => e.key is! String || e.value is! String,
              )) {
            add('FIELD_TYPE', 'metadata must be a map of strings.', marker);
          }
        }
        if (fields['context'] is String && fields['context'] != 'fork') {
          add('FIELD_VALUE', 'context must be fork when present.', marker);
        }
        if (fields.containsKey('hooks')) {
          add(
            'UNSUPPORTED_FIELD',
            'Claude hook definitions are not validated by this inspector.',
            marker,
          );
        }
        if (fields['user-invocable'] == false &&
            flag == true &&
            classification == PromptClassification.prompt &&
            profile == PromptConsumer.claude) {
          add(
            'USER_INVOCATION_DISABLED',
            'A Prompt must remain user-invocable.',
            marker,
          );
        }
        if (form == PromptForm.skill) {
          for (final key in const ['name', 'description']) {
            if (fields[key] is! String ||
                (fields[key] as String).trim().isEmpty) {
              add(
                'FIELD_REQUIRED',
                'The skill-backed Prompt product profile requires a nonempty $key string.',
                marker,
              );
            }
          }
          final name = fields['name'];
          if (name is String &&
              (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(name) ||
                  name.length > 64 ||
                  name != fs.path.basename(path))) {
            add(
              'NAME_INVALID',
              'Skill name must match its directory and native name rules.',
              marker,
            );
          }
          if (fields['description'] is String &&
              (fields['description'] as String).runes.length > 1024) {
            add(
              'DESCRIPTION_LENGTH',
              'Description exceeds 1024 characters.',
              marker,
            );
          }
        }
      }
      for (final match
          in classification == PromptClassification.prompt
              ? PromptResourcePathScanner.scan(body)
              : const <BlockedResourcePath>[]) {
        final offset = match.matchStart;
        final before = body.substring(0, offset);
        final line = bodyLine + '\n'.allMatches(before).length;
        final last = before.lastIndexOf('\n');
        add(
          'RESOURCE_REFERENCE',
          'Instruction contains a blocked resource path segment.',
          marker,
          line,
          offset - last,
        );
      }
      final argumentPattern = switch (profile) {
        PromptConsumer.claude => RegExp(r'\$(?:ARGUMENTS(?:\[\d+\])?|\d+)'),
        PromptConsumer.pi when form == PromptForm.template => RegExp(
          r'\$(?:ARGUMENTS|\d+|@|\{(?:\d+|@)(?::[^}]+)?\})',
        ),
        _ => null,
      };
      final observed = <String>{};
      if (argumentPattern != null) {
        observed.addAll(
          argumentPattern.allMatches(body).map((match) => match.group(0)!),
        );
      }
      if (profile == PromptConsumer.claude) {
        final declared = fields['arguments'];
        final names = declared is String
            ? declared.split(RegExp(r'[,\s]+'))
            : declared is List
            ? declared.whereType<String>()
            : const <String>[];
        for (final name in names) {
          if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name) &&
              RegExp('\\\$${RegExp.escape(name)}(?![A-Za-z0-9_])')
                  .hasMatch(body)) {
            observed.add('\$$name');
          }
        }
      }
      final arguments = observed.toList()..sort();
      return (
        consumer: profile,
        classification: classification,
        valid:
            classification != PromptClassification.malformed &&
            classification != PromptClassification.unclassified &&
            diagnostics.isEmpty,
        argumentExpressions: List<String>.unmodifiable(arguments),
        dynamicShell: profile == PromptConsumer.claude && body.contains('!`'),
        argumentsAppended:
            profile == PromptConsumer.pi && form == PromptForm.skill,
        diagnostics: List<PromptDiagnostic>.unmodifiable(diagnostics),
      );
    }

    final views = Map<PromptConsumer, PromptView>.unmodifiable({
      for (final item in PromptConsumer.inspectable) item: build(item),
    });
    final globalCompatibility =
        views.values.any(
          (v) => v.classification == PromptClassification.malformed,
        )
        ? PromptCompatibility.unknown
        : views.values.every(
            (v) => v.classification == PromptClassification.prompt && v.valid,
          )
        ? PromptCompatibility.compatible
        : PromptCompatibility.incompatible;
    return (
      path: path,
      form: form,
      selectedConsumer: consumer,
      selectedView: consumer == null ? null : views[consumer],
      views: views,
      globalCompatibility: globalCompatibility,
      placement: placement,
      fields: Map<String, Object?>.unmodifiable(
        fields.map((key, value) => MapEntry(key, freeze(value))),
      ),
      sidecarFields: Map<String, Object?>.unmodifiable(
        sidecarFields.map((key, value) => MapEntry(key, freeze(value))),
      ),
    );
  }
}
