import 'dart:convert';

import 'package:path/path.dart' as p;

import '../services/lifecycle_state_service.dart';
import 'path_action_diff.dart';

/// Standalone lexical evidence only. Decoding does not authorize recovery or
/// establish filesystem authority or validate live state. Callers may use valid
/// evidence to conservatively reserve its participating paths and identities.
final class RouteJournalEvidence {
  RouteJournalEvidence._(this._encoded);
  final String _encoded;

  Map<String, Object?> toJson() => jsonDecode(_encoded) as Map<String, Object?>;
  String encode() => _encoded;

  static RouteJournalEvidence decode(String encoded, p.Context paths) {
    if (utf8.encode(encoded).length > 4 * 1024 * 1024) {
      throw const FormatException('Journal exceeds size limit.');
    }
    _checkJsonKeys(encoded);
    final Object? raw = jsonDecode(encoded);
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('Expected journal object.');
    }
    final map = raw;
    void fail() =>
        throw const FormatException('Invalid route journal evidence.');
    void keys(Map<dynamic, dynamic> m, Set<String> expected) {
      if (m.length != expected.length ||
          !m.keys.toSet().containsAll(expected)) {
        fail();
      }
    }

    keys(map, {
      'schemaVersion',
      'operation',
      'transactionId',
      'scope',
      'phase',
      'oldRecords',
      'newRecords',
      'actions',
      'completedActions',
    });
    if (map['schemaVersion'] != 1 ||
        map['operation'] != 'cross-route' ||
        map['transactionId'] is! String ||
        !RegExp(r'^trx_[a-f0-9]{32}$')
            .hasMatch(map['transactionId'] as String) ||
        !['project', 'user'].contains(map['scope'])) {
      fail();
    }
    final old = <OldArtifactPath>[];
    final next = <NewArtifactPath>[];
    String? name;
    Object? source;
    Object? sourceIdentity;

    void records(Object? value, bool before) {
      if (value is! List || value.isEmpty) {
        fail();
        return;
      }
      final ids = <String>{};
      Object? groupRoute;
      final consumers = <String>{};
      for (final item in value) {
        final record = InstallationRecord.fromJson(item);
        if (jsonEncode(_sorted(item)) != jsonEncode(_sorted(record.toJson()))) {
          fail();
        }
        if (!ids.add(record.installationId) ||
            record.scope.name != map['scope'] ||
            record.lifecycle != 'live' ||
            record.installationRoute == null) {
          fail();
        }
        final route = record.installationRoute!;
        final routeJson = route.toJson();
        if (groupRoute != null &&
            jsonEncode(_sorted(groupRoute)) != jsonEncode(_sorted(routeJson))) {
          fail();
        }
        groupRoute = routeJson;
        final sourceJson = route.source.toJson();
        final identity = [
          route.sourceKind.name,
          route.sourceRelativePath,
          route.entryId,
          route.packKey,
          route.source.durableLocalDirectory,
        ];
        if (sourceIdentity != null &&
            jsonEncode(sourceIdentity) != jsonEncode(identity)) {
          fail();
        }
        sourceIdentity = identity;
        if (name != null && name != record.name ||
            source != null &&
                jsonEncode(_sorted(source)) !=
                    jsonEncode(_sorted(sourceJson)) ||
            jsonEncode(_sorted(record.origin['source'])) !=
                jsonEncode(_sorted(sourceJson))) {
          fail();
        }
        name = record.name;
        source = sourceJson;
        if (![
          'skillCopy',
          'skillLink',
          'skillCanonical',
        ].contains(record.kind.name)) {
          fail();
        }
        for (final consumer in record.knownConsumers) {
          if (!consumers.add(consumer)) fail();
        }
        if (record.kind.name != 'skillCanonical' &&
            (record.exposures.isNotEmpty ||
                record.knownConsumers.length != 1)) {
          fail();
        }
        final targets = <String>{};
        for (final exposure in record.exposures) {
          if (!record.knownConsumers.contains(exposure.target) ||
              !targets.add(exposure.target)) {
            fail();
          }
        }
        void add(String location, String kind) {
          if (!paths.isAbsolute(location) ||
              paths.normalize(location) != location ||
              location.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
            fail();
          }
          if (before) {
            final match = OldArtifactKind.values.where((e) => e.name == kind);
            if (match.isEmpty) {
              fail();
              return;
            }
            old.add((path: location, kind: match.first));
          } else {
            final match = NewArtifactKind.values.where((e) => e.name == kind);
            if (match.isEmpty) {
              fail();
              return;
            }
            next.add((path: location, kind: match.first));
          }
        }

        add(record.location, record.kind.name);
        for (final exposure in record.exposures) {
          add(exposure.path, 'skillLink');
        }
      }
      final first = InstallationRecord.fromJson(value.first);
      if (first.kind.name == 'skillCanonical' && value.length != 1) fail();
      final routeTargets = first.installationRoute!.targets
          .map((e) => e.name)
          .toSet();
      if (consumers.length != routeTargets.length ||
          !consumers.containsAll(routeTargets)) {
        fail();
      }
    }

    try {
      records(map['oldRecords'], true);
      records(map['newRecords'], false);
      final expected = PathActionDiff(paths)
          .compare(oldPaths: old, newPaths: next, occupiedPaths: []);
      for (var i = 0; i < expected.length; i++) {
        for (var j = i + 1; j < expected.length; j++) {
          if (paths.isWithin(expected[i].path, expected[j].path) ||
              paths.isWithin(expected[j].path, expected[i].path)) {
            fail();
          }
        }
      }
      final actions = map['actions'];
      if (actions is! List || actions.length != expected.length) {
        fail();
      }
      final seen = <String>{};
      final steps = <String>[];
      for (final action in actions as List) {
        if (action is! Map<String, dynamic>) {
          fail();
          continue;
        }
        keys(action, {'path', 'oldKind', 'newKind'});
        final path = action['path'];
        if (path is! String || !seen.add(path)) {
          fail();
          continue;
        }
        final matches = expected.where((e) => e.path == path);
        if (matches.length != 1) {
          fail();
          continue;
        }
        final match = matches.single;
        if (action['oldKind'] != match.oldKind?.name ||
            action['newKind'] != match.newKind?.name) {
          fail();
        }
        final index = seen.length - 1;
        if (match.oldKind != null) steps.add('$index-remove');
        if (match.newKind != null) steps.add('$index-publish');
      }
      final completed = map['completedActions'];
      if (completed is! List || completed.length > steps.length) {
        fail();
      }
      for (var i = 0; i < (completed as List).length; i++) {
        if (completed[i] != steps[i]) fail();
      }
      final phase = map['phase'];
      if (!(phase == 'prepared' && completed.isEmpty ||
          phase == 'applying' &&
              completed.isNotEmpty &&
              completed.length < steps.length ||
          ['published', 'committed', 'completed'].contains(phase) &&
              completed.length == steps.length ||
          phase == 'recoveryRequired')) {
        fail();
      }
    } on FormatException {
      rethrow;
    } on Object {
      fail();
    }
    return RouteJournalEvidence._(jsonEncode(map));
  }
}

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _sorted(value[key])};
  }
  if (value is List) return [for (final item in value) _sorted(item)];
  return value;
}

// Check duplicate member names before jsonDecode can discard them. This is
// deliberately bounded independently of the JSON decoder's recursion.
void _checkJsonKeys(String source) {
  var index = 0;
  void whitespace() {
    while (index < source.length && ' \n\r\t'.contains(source[index])) {
      index++;
    }
  }

  String string() {
    final start = index++;
    var escaped = false;
    while (index < source.length) {
      final c = source[index++];
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        return jsonDecode(source.substring(start, index)) as String;
      }
    }
    throw const FormatException('Unterminated JSON string.');
  }

  void value(int depth) {
    if (depth > 64) throw const FormatException('Journal nesting limit.');
    whitespace();
    if (index >= source.length) throw const FormatException('Invalid JSON.');
    final c = source[index];
    if (c == '"') {
      string();
      return;
    }
    if (c == '{') {
      index++;
      whitespace();
      final names = <String>{};
      if (index < source.length && source[index] == '}') {
        index++;
        return;
      }
      while (true) {
        whitespace();
        if (index >= source.length || source[index] != '"') {
          throw const FormatException('Invalid JSON key.');
        }
        if (!names.add(string())) {
          throw const FormatException('Duplicate JSON key.');
        }
        whitespace();
        if (index >= source.length || source[index++] != ':') {
          throw const FormatException('Invalid JSON object.');
        }
        value(depth + 1);
        whitespace();
        if (index >= source.length) {
          throw const FormatException('Invalid JSON object.');
        }
        if (source[index++] == '}') return;
        if (source[index - 1] != ',') {
          throw const FormatException('Invalid JSON object.');
        }
      }
    }
    if (c == '[') {
      index++;
      whitespace();
      if (index < source.length && source[index] == ']') {
        index++;
        return;
      }
      while (true) {
        value(depth + 1);
        whitespace();
        if (index >= source.length) {
          throw const FormatException('Invalid JSON array.');
        }
        if (source[index++] == ']') return;
        if (source[index - 1] != ',') {
          throw const FormatException('Invalid JSON array.');
        }
      }
    }
    while (index < source.length && !' \n\r\t,]}'.contains(source[index])) {
      index++;
    }
  }

  value(0);
  whitespace();
  if (index != source.length) throw const FormatException('Trailing JSON.');
}
