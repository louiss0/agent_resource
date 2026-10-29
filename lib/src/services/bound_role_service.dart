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
    this.affected = const <String>[],
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
  final List<String> affected;
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
    'affected',
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
  final affected = map['affected'];
  if (affected != null) {
    if (affected is! List<Object?>) {
      throw MambaException('Bound-role affected decisions must be an array.');
    }
    if (affected.any((Object? value) => value is! String)) {
      throw MambaException('Bound-role affected decisions must be strings.');
    }
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
    affected: affected == null
        ? const <String>[]
        : (affected as List<Object?>).cast<String>().toList(),
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
    if (request.ownership != BoundOwnership.definition &&
        !request.clientsStopped) {
      throw MambaException(
        'Parent-writing bound-role mutations require --clients-stopped acknowledgement.',
        exitCode: 4,
      );
    }
    final binding = _binding(request, options);
    final installationId = request.installationId;
    String? definitionId;
    String? definitionBackupId;
    ParentResult? registration;
    agent.state.ensureLedger(LifecycleContext.resolve(options));
    Future<void> publishDefinition() async {
      if (request.ownership == BoundOwnership.registration) return;
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
        return;
      }
      if (request.operation == BoundOperation.adopt) {
        final definition = _definitionFile(binding, request);
        if (definition == null) {
          throw MambaException(
            'The bound role has no definition file to adopt.',
          );
        }
        final adopted = await agent.adoptBoundDefinition(
          AgentInstallInput(
            options: options,
            source: definition,
            harness: AgentHarness.codex,
          ),
        );
        definitionId = adopted.data['installationId']! as String;
        return;
      }
      if (installationId == null) {
        throw MambaException(
          'Bound-role ${request.operation.name} requires a definition installationId.',
        );
      }
      if (request.operation == BoundOperation.replace) {
        final source = request.source;
        if (source == null) {
          throw MambaException('Bound-role replace requires a source file.');
        }
        final replaced = await agent.replace(
          LifecycleReplaceInput(
            options: options.copyWith(approved: true),
            installationId: installationId,
            source: source,
          ),
        );
        definitionId = replaced.data['installationId']! as String;
        definitionBackupId = replaced.data['backupId']! as String;
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

    Future<void> publishRegistration() async {
      if (request.ownership == BoundOwnership.definition) return;
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
          affected: parentRequest.affected,
          planId: parentPlan.data['planId']! as String,
          clientsStopped: true,
        ),
        options: options.copyWith(approved: true),
      );
    }

    try {
      if (request.operation == BoundOperation.create ||
          request.operation == BoundOperation.replace) {
        await publishDefinition();
        await publishRegistration();
      } else {
        await publishRegistration();
        await publishDefinition();
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
      if ((request.operation == BoundOperation.create ||
              request.operation == BoundOperation.replace) &&
          definitionId != null &&
          registration == null) {
        try {
          if (request.operation == BoundOperation.create) {
            await agent.remove(
              LifecycleIdInput(
                options: options.copyWith(approved: true),
                id: definitionId!,
              ),
            );
          } else {
            final backup = definitionBackupId;
            if (backup == null) {
              throw MambaException(
                'The definition replacement has no retained backup for recovery.',
                exitCode: 6,
              );
            }
            await agent.restore(
              LifecycleIdInput(
                options: options.copyWith(approved: true),
                id: backup,
              ),
            );
          }
        } on MambaException catch (recoveryError) {
          throw MambaException(
            'The bound-role mutation requires recovery; definition rollback could not be proven. $recoveryError',
            exitCode: 6,
          );
        }
        throw MambaException(
          'Registration failed and the definition was restored to its prior state. $error',
          exitCode: 5,
        );
      }
      if (registration != null) {
        final backupId = registration!.data['backupId'];
        if (backupId is! String) {
          throw MambaException(
            'The combined bound-role operation failed after registration, and no registration backup is available for recovery. $error',
            exitCode: 6,
          );
        }
        try {
          final restorePlan = parent.restorePlanId(options, backupId);
          await parent.restore(
            options: options.copyWith(approved: true),
            backupId: backupId,
            planId: restorePlan,
            clientsStopped: true,
          );
        } on MambaException catch (recoveryError) {
          throw MambaException(
            'The combined bound-role operation requires recovery; registration rollback could not be proven. $recoveryError',
            exitCode: 6,
          );
        }
        throw MambaException(
          'The definition step failed and registration was restored; no combined bound-role change was committed. $error',
          exitCode: 5,
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
    if ((request.operation == BoundOperation.replace ||
            request.operation == BoundOperation.remove) &&
        request.ownership != BoundOwnership.registration) {
      final id = request.installationId;
      if (id == null) {
        throw MambaException(
          'Bound-role ${request.operation.name} requires a definition installationId.',
        );
      }
      final record = agent.state.recordById(
        LifecycleContext.resolve(options),
        id,
      );
      final referenced = _definitionFile(binding, request);
      if (referenced == null || !p.equals(record.location, referenced)) {
        throw MambaException(
          'The managed definition and binding reference do not match; registration cannot be redirected implicitly.',
          exitCode: 4,
        );
      }
    }
    Map<String, Object?>? definitionPlan;
    if (request.ownership != BoundOwnership.registration) {
      final source = switch (request.operation) {
        BoundOperation.create => request.source,
        BoundOperation.adopt => _definitionFile(binding, request),
        _ => request.source,
      };
      if (source != null) {
        final planned = switch (request.operation) {
          BoundOperation.adopt => await agent.adoptBoundDefinition(
            AgentInstallInput(
              options: options.copyWith(dryRun: true),
              source: source,
              harness: AgentHarness.codex,
            ),
          ),
          BoundOperation.replace => await agent.replace(
            LifecycleReplaceInput(
              options: options.copyWith(dryRun: true),
              installationId: request.installationId!,
              source: source,
            ),
          ),
          _ => await agent.install(
            AgentInstallInput(
              options: options.copyWith(dryRun: true),
              source: source,
              harness: AgentHarness.codex,
              output: request.output,
            ),
          ),
        };
        definitionPlan = <String, Object?>{
          'source': source,
          'sourceDigest': _sourceDigest(source, options),
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
        'knownAffected': planned.data['knownAffected'],
        'impacts': planned.data['impacts'],
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
      'clientsStoppedAcknowledgementRequired':
          request.ownership != BoundOwnership.definition,
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
      changes.add(
        ParentChange(
          unit: 'agents.${request.roleKey}',
          action: ParentAction.remove,
          value: null,
        ),
      );
    } else {
      final resolvedDefinition = switch (request.operation) {
        BoundOperation.create =>
          request.output ?? _defaultDefinitionLocation(request, options),
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
      affected: request.affected,
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

  String _defaultDefinitionLocation(
    BoundRoleRequest request,
    LifecycleOptions options,
  ) {
    final context = LifecycleContext.resolve(options);
    final root = context.scope == LifecycleScope.project
        ? context.codexAgentsRoot()
        : p.join(context.codexRoot(), 'agents');
    return p.join(root, p.basename(request.source!));
  }

  LifecycleScope _scopeForConfig(String configFile, LifecycleOptions options) {
    final context = LifecycleContext.resolve(options);
    return p.isWithin(context.projectRoot, configFile)
        ? LifecycleScope.project
        : LifecycleScope.user;
  }

  String _sourceDigest(String source, LifecycleOptions options) {
    final resolved = LifecycleContext.resolve(options).resolvePath(source);
    final bytes = readBoundedSkillMarker(resolved, maxBytes: 1048576);
    if (bytes.length > 1048576) {
      throw MambaException(
        'The bound-role definition exceeds the 1 MiB native limit.',
        exitCode: 3,
      );
    }
    return sha256.convert(bytes).toString();
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
