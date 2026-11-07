import 'dart:convert';

import 'package:agent_resource/src/conversion/conversion_evidence.dart';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

void main() {
  group('ConversionEvidence', () {
    Map<String, Object?> participantJson({
      String role = 'source',
      String intent = 'retired',
      String artifactKind = 'skill-copy',
      String location = '/work/project/.claude/skills/demo',
      String? nativeRoot = '/work/project/.claude/skills',
      Map<String, Object?>? ownershipAfter,
      Map<String, Object?>? baseline,
      Map<String, Object?>? payload,
    }) => <String, Object?>{
      'role': role,
      'intent': intent,
      'artifactKind': artifactKind,
      'nativeForm': 'claude-skill',
      'nativeProfile': 'claude',
      'location': location,
      'nativeRoot': nativeRoot,
      'scope': 'project',
      'identity': <String, Object?>{
        'installationId': 'ins_0123456789abcdef0123456789abcdef',
        'receiptId': null,
        'lineageId': null,
        'predecessorId': null,
        'convertedFromId': null,
      },
      'ownershipBefore': <String, Object?>{
        'managed': true,
        'installationId': 'ins_0123456789abcdef0123456789abcdef',
        'receiptId': null,
        'nativeForm': 'claude-skill',
        'nativeProfile': 'claude',
        'location': location,
        'nativeRoot': nativeRoot,
        'scope': 'project',
        'baselineDigest': null,
        'provenance': <String, Object?>{},
      },
      'ownershipAfter':
          ownershipAfter ??
          <String, Object?>{
            'managed': true,
            'installationId': 'ins_0123456789abcdef0123456789abcdef',
            'receiptId': null,
            'nativeForm': 'claude-skill',
            'nativeProfile': 'claude',
            'location': location,
            'nativeRoot': nativeRoot,
            'scope': 'project',
            'baselineDigest': null,
            'provenance': <String, Object?>{},
          },
      'membershipBefore': null,
      'membershipAfter': null,
      'baseline': baseline,
      'payload': payload,
      'staging': null,
      'publication': null,
      'authority': null,
    };

    Map<String, Object?> document({
      Map<String, Object?>? source,
      Map<String, Object?>? target,
      int schemaVersion = conversionEvidenceSchemaVersion,
      String digest = '',
    }) {
      final body = <String, Object?>{
        'schemaVersion': schemaVersion,
        'transactionId': 'cvx_0123456789abcdef0123456789abcdef',
        'operation': 'convert',
        'phase': 'prepared',
        'createdScope': 'project',
        'source': source ?? participantJson(),
        'target':
            target ??
            participantJson(
              role: 'target',
              intent: 'created',
              location: '/work/project/.claude/skills/demo',
            ),
        'approvals': <String, Object?>{'role': true},
        'observations': <String, Object?>{'absence': true},
      };
      return <String, Object?>{...body, 'digest': digest};
    }

    String encode(Map<String, Object?> body) {
      final content = Map<String, Object?>.of(body)..remove('digest');
      return jsonEncode(<String, Object?>{
        ...body,
        'digest': sha256Of(content),
      });
    }

    test('a complete document binds and round-trips', () {
      final encoded = encode(document());
      final evidence = ConversionEvidence.decode(encoded);
      expect(evidence.transactionId, 'cvx_0123456789abcdef0123456789abcdef');
      expect(evidence.phase, ConversionEvidencePhase.prepared);
      expect(evidence.source.role, ConversionParticipantRole.source);
      expect(evidence.target.role, ConversionParticipantRole.target);
      expect(evidence.approvals['role'], isTrue);
      expect(evidence.encode(), encoded);
    });

    test('a tampered document does not bind', () {
      final body = document();
      final encoded = jsonEncode(<String, Object?>{
        ...body,
        'digest': sha256Of(body),
      });
      final tampered = encoded.replaceFirst('"prepared"', '"committed"');
      expect(
        () => ConversionEvidence.decode(tampered),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unknown schema version fails closed', () {
      final body = document(schemaVersion: 99);
      expect(
        () => ConversionEvidence.decode(encode(body)),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unknown field fails closed', () {
      final body = document();
      final encoded = jsonEncode(<String, Object?>{
        ...body,
        'agentResourceType': 'prompt',
        'digest': sha256Of(body),
      });
      expect(
        () => ConversionEvidence.decode(encoded),
        throwsA(isA<FormatException>()),
      );
    });

    test('an oversized document is refused before it is parsed', () {
      final body = document();
      body['observations'] = <String, Object?>{
        'padding': 'x' * (maxConversionEvidenceBytes + 16),
      };
      expect(
        () => ConversionEvidence.decode(jsonEncode(body)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a deeply nested document is refused', () {
      Object? nested = 'leaf';
      for (var depth = 0; depth < maxConversionEvidenceDepth + 4; depth++) {
        nested = <String, Object?>{'nested': nested};
      }
      final body = document();
      body['observations'] = <String, Object?>{'deep': nested};
      expect(
        () => ConversionEvidence.decode(jsonEncode(body)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a node heavy document is refused', () {
      final body = document();
      body['observations'] = <String, Object?>{
        'many': <Object?>[for (var index = 0; index < 4000; index++) index],
      };
      expect(
        () => ConversionEvidence.decode(jsonEncode(body)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a participant outside its native root is refused', () {
      final body = document(
        source: participantJson(location: '/work/elsewhere/demo'),
      );
      expect(
        () => ConversionEvidence.decode(encode(body)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a payload that does not bind the baseline is refused', () {
      final baseline = ConversionBaseline(
        entries: const <Map<String, Object?>>[
          <String, Object?>{
            'path': 'SKILL.md',
            'type': 'file',
            'length': 10,
            'sha256': 'abc',
          },
        ],
      );
      final body = document(
        source: participantJson(
          baseline: baseline.toJson(),
          payload: <String, Object?>{
            'path': '/work/state/backups/artifact',
            'digest': 'different',
            'length': 10,
            'protected': true,
          },
        ),
      );
      expect(
        () => ConversionEvidence.decode(encode(body)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a payload that binds the baseline is accepted', () {
      final baseline = ConversionBaseline(
        entries: const <Map<String, Object?>>[
          <String, Object?>{
            'path': 'SKILL.md',
            'type': 'file',
            'length': 10,
            'sha256': 'abc',
          },
        ],
      );
      final body = document(
        source: participantJson(
          baseline: baseline.toJson(),
          payload: <String, Object?>{
            'path': '/work/state/backups/artifact',
            'digest': baseline.digest,
            'length': 10,
            'protected': true,
          },
        ),
      );
      expect(ConversionEvidence.decode(encode(body)).source.payload, isNotNull);
    });

    test('a Pi template representation requires a tracked conversion', () {
      final body = document(
        target: participantJson(
          role: 'target',
          intent: 'created',
          artifactKind: 'prompt-template',
          location: '/work/project/.pi/prompts/demo.md',
          nativeRoot: '/work/project/.pi/prompts',
          ownershipAfter: <String, Object?>{
            'managed': false,
            'installationId': null,
            'receiptId': 'rcp_0123456789abcdef0123456789abcdef',
            'nativeForm': 'pi-prompt-template',
            'nativeProfile': 'pi',
            'location': '/work/project/.pi/prompts/demo.md',
            'nativeRoot': '/work/project/.pi/prompts',
            'scope': 'project',
            'baselineDigest': null,
            'provenance': <String, Object?>{},
          },
        ),
      );
      expect(
        () => ConversionEvidence.decode(encode(body)),
        throwsA(isA<FormatException>()),
      );
    });

    test('the artifact kinds stay native', () {
      expect(conversionArtifactKinds, contains('skill-copy'));
      expect(conversionArtifactKinds, contains('agent-file'));
      expect(conversionArtifactKinds, contains('prompt-template'));
      expect(conversionArtifactKinds, isNot(contains('prompt')));
    });

    test('a payload without a verified baseline is refused', () {
      final body = document(
        source: participantJson(
          payload: <String, Object?>{
            'path': '/work/state/backups/artifact',
            'digest': 'abc',
            'length': 10,
            'protected': true,
          },
        ),
      );
      expect(
        () => ConversionEvidence.decode(encode(body)),
        throwsA(isA<FormatException>()),
      );
    });

    test('an unprotected payload is refused', () {
      final baseline = ConversionBaseline(
        entries: const <Map<String, Object?>>[
          <String, Object?>{
            'path': 'SKILL.md',
            'type': 'file',
            'length': 10,
            'sha256': 'abc',
          },
        ],
      );
      final body = document(
        source: participantJson(
          baseline: baseline.toJson(),
          payload: <String, Object?>{
            'path': '/work/state/backups/artifact',
            'digest': baseline.digest,
            'length': 10,
            'protected': false,
          },
        ),
      );
      expect(
        () => ConversionEvidence.decode(encode(body)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a location outside the recorded authority root is refused', () {
      final body = document(
        target: participantJson(
          role: 'target',
          intent: 'created',
          location: '/work/project/.codex/skills/demo',
          nativeRoot: '/work/project/.codex/skills',
          ownershipAfter: <String, Object?>{
            'managed': true,
            'installationId': 'ins_0123456789abcdef0123456789abcdef',
            'receiptId': null,
            'nativeForm': 'claude-skill',
            'nativeProfile': 'claude',
            'location': '/work/project/.codex/skills/demo',
            'nativeRoot': '/work/project/.codex/skills',
            'scope': 'project',
            'baselineDigest': null,
            'provenance': <String, Object?>{},
          },
        ),
      );
      final target = body['target']! as Map<String, Object?>;
      target['authority'] = <String, Object?>{
        'scope': 'project',
        'projectRoot': '/work/project',
        'nativeRoot': '/work/project/.claude/skills',
        'approved': true,
      };
      expect(
        () => ConversionEvidence.decode(encode(body)),
        throwsA(isA<FormatException>()),
      );
    });

    test('a participant without its required ownership record is refused', () {
      final body = document();
      final source = body['source']! as Map<String, Object?>;
      source['ownershipBefore'] = null;
      expect(
        () => ConversionEvidence.decode(encode(body)),
        throwsA(isA<FormatException>()),
      );
      final other = document();
      final target = other['target']! as Map<String, Object?>;
      target['ownershipAfter'] = null;
      expect(
        () => ConversionEvidence.decode(encode(other)),
        throwsA(isA<FormatException>()),
      );
    });

    test('an invalid transaction identifier is refused', () {
      final body = document();
      body['transactionId'] = 'txn_1';
      expect(
        () => ConversionEvidence.decode(encode(body)),
        throwsA(isA<FormatException>()),
      );
    });
  });
}

String sha256Of(Map<String, Object?> body) {
  return sha256.convert(utf8.encode(jsonEncode(_canonical(body)))).toString();
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.toList()
      ..sort((left, right) => left.toString().compareTo(right.toString()));
    return <String, Object?>{
      for (final key in keys) key.toString(): _canonical(value[key]),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) _canonical(item)];
  }
  return value;
}
