import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import '../agent_inspection.dart';
import '../skill_files.dart';
import 'agent_lifecycle_service.dart';
import 'lifecycle_state_service.dart';
import 'parent_config_service.dart';

enum BoundOwnership { registration, definition, both }

enum BoundOperation { create, adopt, replace, remove }

/// Identifies the legacy bound-role envelope shape without using exceptions
/// for dispatch. Full validation still occurs in [parseBoundRoleRequest].
bool isBoundRoleRequest(String requestFile, String workingDirectory) {
  final path = p.normalize(
    p.isAbsolute(requestFile)
        ? requestFile
        : p.join(workingDirectory, requestFile),
  );
  final bytes = readBoundedSkillMarker(path, maxBytes: parentDocumentLimit);
  final map = parseStrictJsonObject(utf8.decode(bytes, allowMalformed: false));
  final source = map['source'];
  return source is Map<String, Object?> && source['kind'] == 'codex-role';
}

final class BoundRoleRequest {
  const new({
    required this.operation,
    required this.configFile,
    required this.roleKey,
    required this.ownership,
    this.source,
    this.installationId,
    this.output,
    this.planId,
    this.clientsStopped = false,
  });

  final BoundOperation operation;
  final String configFile;
  final String roleKey;
  final BoundOwnership ownership;
  final String? source;
  final String? installationId;
  final String? output;
  final String? planId;
  final bool clientsStopped;
}

BoundRoleRequest parseBoundRoleRequest(
  String requestFile,
  String workingDirectory,
) {
  final path = p.normalize(
    p.isAbsolute(requestFile)
        ? requestFile
        : p.join(workingDirectory, requestFile),
  );
  final file = File(path);
  if (!file.existsSync()) {
    throw MambaException('Bound-role request does not exist: $path');
  }
  final bytes = file.readAsBytesSync();
  if (bytes.length > parentDocumentLimit) {
    throw MambaException('Bound-role request exceeds 8 MiB.', exitCode: 3);
  }
  final Map<String, Object?> map;
  try {
    map = parseStrictJsonObject(utf8.decode(bytes, allowMalformed: false));
  } on FormatException catch (error) {
    throw MambaException('Invalid bound-role request: ${error.message}');
  }
  const allowed = <String>{
    'schemaVersion',
    'operation',
    'source',
    'ownership',
    'definition',
    'planId',
    'clientsStopped',
  };
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw MambaException('Unknown bound-role request field: $key');
    }
  }
  if (map['schemaVersion'] != 1) {
    throw MambaException('Bound-role request schemaVersion must be 1.');
  }
  final operationName = map['operation'];
  final operations = BoundOperation.values.where(
    (item) => item.name == operationName,
  );
  if (operations.length != 1) {
    throw MambaException('Unsupported bound-role operation: $operationName');
  }
  final source = map['source'];
  if (source is! Map<String, Object?>) {
    throw MambaException('Bound-role source must be an object.');
  }
  const sourceKeys = <String>{'kind', 'configFile', 'roleKey'};
  for (final key in source.keys) {
    if (!sourceKeys.contains(key)) {
      throw MambaException('Unknown bound-role source field: $key');
    }
  }
  if (source['kind'] != 'codex-role') {
    throw MambaException('Bound-role source kind must be codex-role.');
  }
  final configFile = source['configFile'];
  final roleKey = source['roleKey'];
  if (configFile is! String || configFile.trim().isEmpty) {
    throw MambaException('Bound-role configFile must be a nonblank string.');
  }
  if (roleKey is! String || roleKey.trim().isEmpty) {
    throw MambaException('Bound-role roleKey must be a nonblank string.');
  }
  final ownershipName = map['ownership'];
  final ownerships = BoundOwnership.values.where(
    (item) => item.name == ownershipName,
  );
  if (ownerships.length != 1) {
    throw MambaException(
      'Bound-role ownership must be registration, definition, or both.',
    );
  }
  final definition = map['definition'];
  if (definition != null && definition is! Map<String, Object?>) {
    throw MambaException('Bound-role definition must be an object.');
  }
  final definitionMap = definition == null
      ? const <String, Object?>{}
      : definition as Map<String, Object?>;
  const definitionKeys = <String>{'source', 'installationId', 'output'};
  for (final key in definitionMap.keys) {
    if (!definitionKeys.contains(key)) {
      throw MambaException('Unknown bound-role definition field: $key');
    }
  }
  String? optionalString(String key) {
    final value = definitionMap[key];
    if (value != null && (value is! String || value.trim().isEmpty)) {
      throw MambaException('Bound-role $key must be a nonblank string.');
    }
    return value as String?;
  }

  final planId = map['planId'];
  if (planId != null && planId is! String) {
    throw MambaException('Bound-role planId must be a string.');
  }
  final clients = map['clientsStopped'];
  if (clients != null && clients is! bool) {
    throw MambaException('Bound-role clientsStopped must be a boolean.');
  }
  return BoundRoleRequest(
    operation: operations.single,
    configFile: configFile,
    roleKey: roleKey,
    ownership: ownerships.single,
    source: optionalString('source'),
    installationId: optionalString('installationId'),
    output: optionalString('output'),
    planId: planId as String?,
    clientsStopped: clients == true,
  );
}

final class BoundRoleService {
  BoundRoleService({AgentLifecycleService? agent, ParentConfigService? parent})
    : agent = agent ?? AgentLifecycleService(),
      parent = parent ?? ParentConfigService();

  final AgentLifecycleService agent;
  final ParentConfigService parent;

  Future<LifecycleResult> run(
    BoundRoleRequest request,
    LifecycleOptions options,
  ) async {
    final plan = await _plan(request, options);
    if (request.planId == null || options.dryRun) {
      return LifecycleResult(
        command: 'agent ${request.operation.name}',
        outcome: 'planned',
        data: <String, Object?>{
          ...plan,
          'planId': plan['planId'],
          'writes': false,
        },
      );
    }
    if (request.planId != plan['planId']) {
      throw MambaException(
        'The bound-role plan ID does not match current evidence.',
        exitCode: 4,
      );
    }
    if (!options.approved) {
      throw MambaException(
        'The bound-role mutation requires approval with --yes.',
        exitCode: 4,
      );
    }
    if (!request.clientsStopped) {
      throw MambaException(
        'The bound-role mutation requires --clients-stopped acknowledgement.',
        exitCode: 4,
      );
    }
    final binding = _binding(request, options);
    final installationId = request.installationId;
    String? definitionId;
    ParentResult? registration;
    try {
      if (request.ownership != BoundOwnership.registration) {
        if (request.operation == BoundOperation.create) {
          final source = request.source;
          if (source == null) {
            throw MambaException(
              'Bound-role create requires a definition source.',
            );
          }
          final installed = await agent.install(
            AgentInstallInput(
              options: options.copyWith(approved: true),
              source: source,
              harness: AgentHarness.codex,
              output: request.output,
            ),
          );
          definitionId = installed.data['installationId']! as String;
        } else if (request.operation == BoundOperation.adopt) {
          final definition = _definitionFile(binding, request);
          if (definition == null) {
            throw MambaException(
              'The bound role has no definition file to adopt.',
            );
          }
          final adopted = await agent.adopt(
            AgentInstallInput(
              options: options,
              source: definition,
              harness: AgentHarness.codex,
            ),
          );
          definitionId = adopted.data['installationId']! as String;
        } else {
          if (installationId == null) {
            throw MambaException(
              'Bound-role ${request.operation.name} requires a definition installationId.',
            );
          }
          if (request.operation == BoundOperation.replace) {
            final source = request.source;
            if (source == null) {
              throw MambaException(
                'Bound-role replace requires a source file.',
              );
            }
            final replaced = await agent.replace(
              LifecycleReplaceInput(
                options: options.copyWith(approved: true),
                installationId: installationId,
                source: source,
              ),
            );
            definitionId = replaced.data['installationId']! as String;
          } else {
            final removed = await agent.remove(
              LifecycleIdInput(
                options: options.copyWith(approved: true),
                id: installationId,
              ),
            );
            definitionId = removed.data['installationId']! as String;
          }
        }
      }
      if (request.ownership != BoundOwnership.definition) {
        final parentRequest = _registrationRequest(request, options, binding);
        final parentPlan = await parent.plan(
          request: parentRequest,
          options: options,
        );
        registration = await parent.apply(
          request: ParentRequest(
            operation: ParentOperation.apply,
            harness: parentRequest.harness,
            scope: parentRequest.scope,
            layer: parentRequest.layer,
            file: parentRequest.file,
            changes: parentRequest.changes,
            adopt: parentRequest.adopt,
            planId: parentPlan.data['planId']! as String,
            clientsStopped: true,
          ),
          options: options.copyWith(approved: true),
        );
      }
      return LifecycleResult(
        command: 'agent ${request.operation.name}',
        outcome: switch (request.operation) {
          BoundOperation.create => 'created',
          BoundOperation.adopt => 'adopted',
          BoundOperation.replace => 'replaced',
          BoundOperation.remove => 'removed',
        },
        data: <String, Object?>{
          'planId': request.planId,
          'ownership': request.ownership.name,
          'roleKey': request.roleKey,
          'configFile': binding.configFile,
          'installationId': definitionId ?? installationId,
          'parentId': registration?.data['parentId'],
          'backupId': registration?.data['backupId'],
          'definitionCommitted': definitionId != null,
          'registrationCommitted': registration != null,
        },
      );
    } catch (error) {
      if (definitionId != null) {
        throw MambaException(
          'The definition prerequisite committed as $definitionId, but the '
          'registration step failed. It is not rolled back across operation '
          'boundaries. $error',
          exitCode: 6,
        );
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> _plan(
    BoundRoleRequest request,
    LifecycleOptions options,
  ) async {
    final binding = _binding(request, options);
    Map<String, Object?>? definitionPlan;
    if (request.ownership != BoundOwnership.registration) {
      final source = switch (request.operation) {
        BoundOperation.create => request.source,
        BoundOperation.adopt => _definitionFile(binding, request),
        _ => request.source,
      };
      if (source != null) {
        final planned = await agent.install(
          AgentInstallInput(
            options: options.copyWith(dryRun: true),
            source: source,
            harness: AgentHarness.codex,
            output: request.output,
          ),
        );
        definitionPlan = <String, Object?>{
          'source': source,
          'location': planned.data['location'],
          'nativeForm': planned.data['nativeForm'],
        };
      } else if (request.operation != BoundOperation.remove) {
        throw MambaException(
          'Bound-role ${request.operation.name} has no definition source.',
          exitCode: 4,
        );
      }
    }
    Map<String, Object?>? registrationPlan;
    ParentRequest? parentRequest;
    if (request.ownership != BoundOwnership.definition) {
      parentRequest = _registrationRequest(request, options, binding);
      final planned = await parent.plan(
        request: parentRequest,
        options: options,
      );
      registrationPlan = <String, Object?>{
        'planId': planned.data['planId'],
        'units': planned.data['changes'],
      };
    }
    final id = sha256
        .convert(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'schemaVersion': 1,
              'operation': request.operation.name,
              'ownership': request.ownership.name,
              'configFile': binding.configFile,
              'roleKey': request.roleKey,
              'source': request.source,
              'installationId': request.installationId,
              'output': request.output,
              'definition': definitionPlan,
              'registration': registrationPlan,
              'context': <String, Object?>{
                'cwd': options.cwd,
                'projectRoot': options.projectRoot,
                'home': options.home,
                'codexHome': options.codexHome,
              },
            }),
          ),
        )
        .toString();
    return <String, Object?>{
      'planId': id,
      'operation': request.operation.name,
      'configFile': binding.configFile,
      'roleKey': request.roleKey,
      'ownership': request.ownership.name,
      'definition': definitionPlan,
      'registration': registrationPlan,
      'clientsStoppedAcknowledgementRequired': true,
      'approvalRequired': true,
    };
  }

  ParentRequest _registrationRequest(
    BoundRoleRequest request,
    LifecycleOptions options,
    CodexBindingInspection binding,
  ) {
    final configFile = binding.configFile;
    final definition = request.operation == BoundOperation.create
        ? null
        : _definitionFile(binding, request);
    final changes = <ParentChange>[];
    if (request.operation == BoundOperation.remove) {
      changes.addAll([
        ParentChange(
          unit: 'agents.${request.roleKey}.config_file',
          action: ParentAction.remove,
          value: null,
        ),
        ParentChange(
          unit: 'agents.${request.roleKey}.description',
          action: ParentAction.remove,
          value: null,
        ),
      ]);
    } else {
      final resolvedDefinition = switch (request.operation) {
        BoundOperation.create =>
          request.output ??
              p.join(
                options.projectRoot ?? Directory.current.path,
                '.codex',
                'agents',
                p.basename(request.source!),
              ),
        _ => definition,
      };
      if (resolvedDefinition == null) {
        throw MambaException(
          'The bound role has no definition file.',
          exitCode: 4,
        );
      }
      final relative = p.isWithin(p.dirname(configFile), resolvedDefinition)
          ? p.relative(resolvedDefinition, from: p.dirname(configFile))
          : resolvedDefinition;
      changes.add(
        ParentChange(
          unit: 'agents.${request.roleKey}.config_file',
          action: ParentAction.set,
          value: relative,
        ),
      );
      final description = _definitionDescription(resolvedDefinition);
      if (description != null) {
        changes.add(
          ParentChange(
            unit: 'agents.${request.roleKey}.description',
            action: ParentAction.set,
            value: description,
          ),
        );
      }
    }
    final scope = _scopeForConfig(configFile, options);
    return ParentRequest(
      operation: ParentOperation.plan,
      harness: ParentHarness.codex,
      scope: scope,
      layer: scope == LifecycleScope.project
          ? ParentLayer.project
          : ParentLayer.user,
      file: configFile,
      changes: changes,
      adopt:
          request.operation == BoundOperation.adopt ||
          request.operation == BoundOperation.replace,
    );
  }

  CodexBindingInspection _binding(
    BoundRoleRequest request,
    LifecycleOptions options,
  ) {
    final cwd = options.cwd ?? options.processWorkingDirectory;
    final binding = CodexBindingInspection.read(
      configFile: request.configFile,
      workingDirectory: cwd,
    );
    if (request.operation != BoundOperation.create) {
      binding.inspectRole(request.roleKey);
    }
    return binding;
  }

  String? _definitionFile(
    CodexBindingInspection binding,
    BoundRoleRequest request,
  ) => binding.inspectRole(request.roleKey).definitionFile;

  LifecycleScope _scopeForConfig(String configFile, LifecycleOptions options) {
    final context = LifecycleContext.resolve(options);
    return p.isWithin(context.projectRoot, configFile)
        ? LifecycleScope.project
        : LifecycleScope.user;
  }

  String? _definitionDescription(String file) {
    final type = skillEntityType(file, followLinks: false);
    if (type != FileSystemEntityType.file) return null;
    final bytes = File(file).readAsBytesSync();
    if (bytes.length > 1024 * 1024) return null;
    final map = TomlDocument.parse(utf8.decode(bytes)).toMap();
    final description = map['description'];
    return description is String && description.trim().isNotEmpty
        ? description.trim()
        : null;
  }
}
