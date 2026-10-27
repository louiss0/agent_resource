import 'dart:collection';
import 'dart:io';

import 'package:mamba/mamba.dart';
import 'package:path/path.dart' as p;

import '../agent_inspection.dart';
import '../skill_files.dart';

final class AgentGraphReport {
  const AgentGraphReport({
    required this.profile,
    required this.source,
    required this.complete,
    required this.ready,
    required this.nodes,
    required this.edges,
    required this.blockers,
    required this.capabilities,
    required this.exposureNotes,
    required this.coverage,
  });

  final String profile;
  final Map<String, Object?> source;
  final bool complete;
  final bool ready;
  final List<Map<String, Object?>> nodes;
  final List<Map<String, Object?>> edges;
  final List<Map<String, Object?>> blockers;
  final List<Map<String, Object?>> capabilities;
  final List<Map<String, Object?>> exposureNotes;
  final Map<String, Object?> coverage;

  Map<String, Object?> toJson() => <String, Object?>{
    'profile': profile,
    'source': source,
    'complete': complete,
    'ready': ready,
    'nodes': nodes,
    'edges': edges,
    'blockers': blockers,
    'capabilities': capabilities,
    'exposureNotes': exposureNotes,
    'coverage': coverage,
    'runtimeVerification': 'notPerformed',
  };

  String renderText() {
    final buffer = StringBuffer()
      ..writeln('graph: ${complete ? 'complete' : 'incomplete'}, ready $ready')
      ..writeln('graph nodes: ${nodes.length}; edges: ${edges.length}');
    for (final edge in edges) {
      buffer.writeln(
        '  ${edge['from']} -[${edge['kind']}]-> ${edge['to']} '
        '(${edge['coverage']})',
      );
    }
    for (final blocker in blockers) {
      buffer.writeln('  blocker ${blocker['code']}: ${blocker['message']}');
    }
    for (final note in exposureNotes) {
      buffer.writeln(
        '  exposure ${note['kind']} ${note['name']}: ${note['note']}',
      );
    }
    return buffer.toString();
  }
}

final class _GraphWork {
  const _GraphWork({
    required this.id,
    required this.depth,
    required this.ancestors,
    this.references = const <Map<String, Object?>>[],
    this.sourcePath,
  });

  final String id;
  final int depth;
  final Set<String> ancestors;
  final List<Map<String, Object?>> references;
  final String? sourcePath;
}

/// Bounded, offline native dependency and capability analysis.
///
/// Only declarations produced by native inspection become edges. Prose,
/// commands, scripts, hooks, servers, models, and credential helpers are never
/// executed or parsed for implicit dependencies.
interface class AgentGraphService {
  static const maxDepth = 32;
  static const maxNodes = 1000;
  static const maxEdges = 5000;
  static const maxSourceBytes = 16 * 1024 * 1024;

  AgentGraphReport analyze(AgentInspectionInput input) {
    final inspection = inspectNativeAgent(
      AgentInspectionInput(
        nativeFile: input.nativeFile,
        requestFile: input.requestFile,
        cwd: input.cwd,
        harness: input.harness,
      ),
      operation: AgentOperation.inspect,
    );
    return analyzeInspection(inspection);
  }

  AgentGraphReport analyzeInspection(AgentInspectionReport inspection) {
    final definition = inspection.definitionFile;
    final rootId =
        'agent:${definition ?? inspection.binding?['roleKey'] ?? 'metadata-only'}';
    final resolutionBase = definition == null
        ? p.dirname(
            inspection.binding?['configFile'] as String? ??
                Directory.current.path,
          )
        : p.dirname(definition);
    final nodesById = <String, Map<String, Object?>>{
      rootId: <String, Object?>{
        'id': rootId,
        'kind': inspection.form,
        'profile': inspection.profile,
        'path': definition,
        'coverage': inspection.validationStatus.wireName,
        'depth': 0,
      },
    };
    final edges = <Map<String, Object?>>[];
    final blockers = <Map<String, Object?>>[];
    var sourceBytes = 0;
    void chargeBytes(int count) {
      sourceBytes += count;
      if (sourceBytes > maxSourceBytes) {
        throw MambaException(
          'Agent graph exceeds the 16 MiB inspected-source budget.',
          exitCode: 3,
        );
      }
    }

    if (definition != null) {
      final type = skillEntityType(definition, followLinks: false);
      if (!inspection.coverage.contains('in-memory-candidate') &&
          type != FileSystemEntityType.file) {
        throw MambaException(
          'Required graph source is no longer an ordinary file: $definition',
          exitCode: 3,
        );
      }
      if (type == FileSystemEntityType.file) {
        chargeBytes(_sourceLength(definition));
      }
    }
    final binding = inspection.binding;
    if (binding != null) {
      final config = binding['configFile']! as String;
      chargeBytes(_sourceLength(config));
      final bindingId = 'binding:$config';
      nodesById[bindingId] = <String, Object?>{
        'id': bindingId,
        'kind': 'codex-role-binding',
        'profile': inspection.profile,
        'path': config,
        'coverage': 'resolved',
        'depth': 0,
      };
      edges.add(<String, Object?>{
        'from': bindingId,
        'to': rootId,
        'kind': 'binding',
        'provenance': <String, Object?>{
          'configFile': config,
          'roleKey': binding['roleKey'],
        },
        'resolutionBase': p.dirname(config),
        'coverage': 'resolved',
        'blocker': false,
      });
    }

    final frontier = Queue<_GraphWork>();
    frontier.add(
      _GraphWork(
        id: rootId,
        depth: 0,
        ancestors: <String>{rootId},
        references: inspection.references,
      ),
    );
    while (frontier.isNotEmpty) {
      final work = frontier.removeFirst();
      final sourcePath = work.sourcePath;
      if (sourcePath != null) {
        // Resolved native Skill inputs are read once within the existing Skill
        // marker budget. Their prose is not scanned for dependencies.
        chargeBytes(_readSkill(sourcePath).length);
      }
      if (work.references.isNotEmpty && work.depth >= maxDepth) {
        throw MambaException(
          'Agent graph exceeds the depth-32 budget.',
          exitCode: 3,
        );
      }
      for (final reference in work.references) {
        if (edges.length >= maxEdges) {
          throw MambaException(
            'Agent graph exceeds the 5,000-edge budget.',
            exitCode: 3,
          );
        }
        final kind = reference['kind']! as String;
        final name = reference['name']! as String;
        final relationship = _relationship(inspection, kind);
        final id = '$kind:$name';
        final cyclic = work.ancestors.contains(id);
        final ({String status, String? path}) resolution = cyclic
            ? (status: 'cycle', path: null)
            : _resolveReference(
                inspection,
                kind,
                name,
                relationship,
                resolutionBase,
              );
        var blocker = false;
        if (cyclic && relationship == 'skill-preload') {
          blocker = true;
          blockers.add(<String, Object?>{
            'code': 'FINITE_RESOLUTION_CYCLE',
            'reference': id,
            'message': 'A required finite Skill expansion contains a cycle.',
          });
        } else if (resolution.status == 'missing' &&
            relationship == 'skill-preload') {
          blocker = true;
          blockers.add(<String, Object?>{
            'code': 'REQUIRED_REFERENCE_MISSING',
            'reference': id,
            'message':
                'Required Skill preload $name was not found in the authorized native roots.',
          });
        } else if (resolution.status == 'unauthorized' &&
            relationship == 'skill-preload') {
          blocker = true;
          blockers.add(<String, Object?>{
            'code': 'REQUIRED_REFERENCE_UNAUTHORIZED',
            'reference': id,
            'message':
                'Required Skill preload $name is not an authorized ordinary file.',
          });
        }
        final depth = work.depth + 1;
        final existing = nodesById[id];
        if (existing == null) {
          if (nodesById.length >= maxNodes) {
            throw MambaException(
              'Agent graph exceeds the 1,000-node budget.',
              exitCode: 3,
            );
          }
          nodesById[id] = <String, Object?>{
            'id': id,
            'kind': kind,
            'name': name,
            'profile': inspection.profile,
            'resolutionBase': resolutionBase,
            'coverage': resolution.status,
            'depth': depth,
          };
        } else if ((existing['depth']! as int) > depth) {
          existing['depth'] = depth;
        }
        edges.add(<String, Object?>{
          'from': work.id,
          'to': id,
          'kind': relationship,
          'provenance': <String, Object?>{
            'definitionFile': definition,
            'binding': binding,
            'declaration': reference,
          },
          'resolutionBase': resolutionBase,
          'coverage': resolution.status,
          'blocker': blocker,
          'cycle': cyclic,
          'cycleMeaning': cyclic
              ? (relationship == 'skill-preload'
                    ? 'finite-expansion-blocker'
                    : 'runtime-observation-only')
              : null,
        });
        // Resolved Skill markers have no documented outgoing native dependency
        // declarations. Queue their bounded read as terminal frontier work;
        // runtime-only/excluded/missing nodes need no further reads.
        if (existing == null && resolution.path != null && !cyclic) {
          frontier.add(
            _GraphWork(
              id: id,
              depth: depth,
              ancestors: <String>{...work.ancestors, id},
              sourcePath: resolution.path,
            ),
          );
        }
      }
    }

    final nodes = nodesById.values.toList();
    final capabilities = <Map<String, Object?>>[
      for (final capability in inspection.capabilities)
        <String, Object?>{
          ...capability,
          'sourceProfile': inspection.profile,
          'conditions': inspection.parentRequirements,
          'contraryEvidence': inspection.diagnostics
              .where(
                (diagnostic) =>
                    diagnostic.severity == AgentDiagnosticSeverity.error,
              )
              .map((diagnostic) => diagnostic.toJson())
              .toList(),
        },
    ];
    final exposureNotes = <Map<String, Object?>>[
      for (final capability in capabilities)
        <String, Object?>{
          'kind': capability['kind'],
          'name': capability['name'],
          'provenance': capability['label'],
          'note':
              '${capability['label']} ${capability['kind']} declaration from '
              '${inspection.profile}; runtime availability and enforcement are not verified.',
        },
      for (final reference in inspection.references)
        <String, Object?>{
          'kind': reference['kind'],
          'name': reference['name'],
          'provenance': reference['label'],
          'note':
              '${reference['label']} ${reference['kind']} association from '
              '${inspection.profile}; no runtime connection or availability probe was performed.',
        },
    ];
    final observedDepth = nodes.fold<int>(
      0,
      (maximum, node) =>
          node['depth']! as int > maximum ? node['depth']! as int : maximum,
    );
    return AgentGraphReport(
      profile: inspection.profile,
      source: <String, Object?>{
        'definitionFile': definition,
        'binding': binding,
        'form': inspection.form,
      },
      complete: true,
      ready: inspection.ready && blockers.isEmpty,
      nodes: List<Map<String, Object?>>.unmodifiable(nodes),
      edges: List<Map<String, Object?>>.unmodifiable(edges),
      blockers: List<Map<String, Object?>>.unmodifiable(blockers),
      capabilities: List<Map<String, Object?>>.unmodifiable(capabilities),
      exposureNotes: List<Map<String, Object?>>.unmodifiable(exposureNotes),
      coverage: <String, Object?>{
        'status': 'complete',
        'traversal': 'exhausted-documented-frontier',
        'depth': observedDepth,
        'depthBudget': maxDepth,
        'inspectedSourceBytes': sourceBytes,
        'frontier': const <Object?>[],
        'cyclePolicy': const <String, Object?>{
          'skill-preload': 'finite-expansion-blocker',
          'binding': 'finite-expansion-blocker',
          'model': 'runtime-observation-only',
          'mcp-association': 'runtime-observation-only',
          'potential-delegation': 'runtime-observation-only',
        },
        'exclusions': const <String>[
          'prose and script inference',
          'runtime delegation resolution',
          'server, model, account, and harness probes',
        ],
      },
    );
  }

  int _sourceLength(String path) {
    try {
      return File(path).lengthSync();
    } on FileSystemException catch (error) {
      throw MambaException(
        'Required graph source could not be observed: ${error.message}',
        exitCode: 3,
      );
    }
  }

  List<int> _readSkill(String path) {
    try {
      return readBoundedSkillMarker(path, maxBytes: 1048576);
    } on MambaException catch (error) {
      throw MambaException(
        'Required Skill graph coverage is incomplete: ${error.message}',
        exitCode: 3,
      );
    } on FileSystemException catch (error) {
      throw MambaException(
        'Required Skill graph coverage is incomplete: ${error.message}',
        exitCode: 3,
      );
    }
  }

  String _relationship(AgentInspectionReport inspection, String kind) {
    if (kind == 'skill') {
      return inspection.form == 'claude-agent-file'
          ? 'skill-preload'
          : 'skill-exclusion';
    }
    return switch (kind) {
      'mcp-server' => 'mcp-association',
      'hook' => 'hook-association',
      'model' => 'model',
      _ => kind,
    };
  }

  ({String status, String? path}) _resolveReference(
    AgentInspectionReport inspection,
    String kind,
    String name,
    String relationship,
    String base,
  ) {
    if (kind == 'model' || kind == 'mcp-server' || kind == 'hook') {
      return (status: 'runtime-dependent', path: null);
    }
    if (kind != 'skill') return (status: 'unresolved', path: null);
    for (final root in _skillRoots(inspection, base)) {
      final candidate = p.join(root, name, 'SKILL.md');
      final type = skillEntityType(candidate, followLinks: false);
      if (type == FileSystemEntityType.file) {
        return (
          status: relationship == 'skill-exclusion'
              ? 'excluded-resolved'
              : 'resolved',
          path: relationship == 'skill-exclusion' ? null : candidate,
        );
      }
      if (type == FileSystemEntityType.link) {
        return (status: 'unauthorized', path: null);
      }
    }
    return (
      status: relationship == 'skill-exclusion' ? 'excluded-absent' : 'missing',
      path: null,
    );
  }

  List<String> _skillRoots(AgentInspectionReport inspection, String base) {
    final nativeBase = _nativeBase(base);
    if (inspection.form == 'claude-agent-file') {
      return <String>[
        p.join(nativeBase, '.claude', 'skills'),
        p.join(nativeBase, '.agents', 'skills'),
      ];
    }
    if (inspection.form == 'codex-agent-file' ||
        inspection.form == 'codex-config-bound-role') {
      return <String>[
        p.join(nativeBase, '.codex', 'skills'),
        p.join(nativeBase, '.agents', 'skills'),
      ];
    }
    return <String>[p.join(nativeBase, '.agents', 'skills')];
  }

  String _nativeBase(String base) {
    var current = p.normalize(base);
    for (var depth = 0; depth < 64; depth++) {
      final parent = p.dirname(current);
      if (p.basename(current) == 'agents' &&
          (p.basename(parent) == '.claude' || p.basename(parent) == '.codex')) {
        return p.dirname(parent);
      }
      if (p.basename(current) == '.claude' || p.basename(current) == '.codex') {
        return parent;
      }
      if (p.equals(parent, current)) return p.normalize(base);
      current = parent;
    }
    throw MambaException(
      'Native graph resolution exceeds the 64-ancestor budget.',
      exitCode: 3,
    );
  }
}
