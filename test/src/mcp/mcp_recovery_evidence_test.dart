import 'dart:convert';

import 'package:agent_resource/src/mcp/mcp_native.dart';
import 'package:agent_resource/src/mcp/mcp_recovery_evidence.dart';
import 'package:agent_resource/src/mcp/mcp_types.dart';
import 'package:test/test.dart';

void main() {
  group('MCP recovery evidence', () {
    const identity = McpRegistrationIdentity(
      harness: McpHarness.codex,
      scope: McpScope.user,
      location: '/sandbox/codex/config.toml',
      name: 'github',
    );
    const hiddenValue = 'NOT-A-LIVE-VALUE';
    final fields = <String, Object?>{
      'command': 'github-mcp',
      'env': <String, Object?>{'TOKEN': hiddenValue},
    };

    test('keeps one selected entry with an integrity digest and retention', () {
      final evidence = McpBackupEvidence(
        backupId: 'mbk_0123456789abcdef0123456789abcdef',
        operation: 'replace',
        identity: identity,
        sourceFingerprint: 'source-fingerprint',
        fields: fields,
        planId: 'reviewed-plan',
        transactionId: 'mtx_0123456789abcdef0123456789abcdef',
      );

      expect(evidence.digest, mcpCanonicalDigest(fields));
      expect(evidence.retention, mcpEvidenceRetention);
      expect(evidence.access, mcpEvidenceAccess);
      expect(evidence.absent, isFalse);

      final decoded = McpBackupEvidence.decode(evidence.encode());
      expect(decoded, evidence);
      expect(decoded.fields, fields);
    });

    test(
      'never discloses the credential-bearing value in its redacted view',
      () {
        final evidence = McpBackupEvidence(
          backupId: 'mbk_0123456789abcdef0123456789abcdef',
          operation: 'replace',
          identity: identity,
          sourceFingerprint: 'source-fingerprint',
          fields: fields,
          planId: 'reviewed-plan',
          transactionId: 'mtx_0123456789abcdef0123456789abcdef',
        );
        final disclosed = jsonEncode(evidence.redactedJson());
        expect(disclosed, isNot(contains(hiddenValue)));
        expect(disclosed, contains('<redacted>'));
      },
    );

    test('refuses substituted entry bytes or markers', () {
      final evidence = McpBackupEvidence(
        backupId: 'mbk_0123456789abcdef0123456789abcdef',
        operation: 'replace',
        identity: identity,
        sourceFingerprint: 'source-fingerprint',
        fields: fields,
        planId: 'reviewed-plan',
        transactionId: 'mtx_0123456789abcdef0123456789abcdef',
      );
      final json = evidence.toJson();
      json['fields'] = <String, Object?>{'command': 'substituted'};
      expect(
        () => McpBackupEvidence.decode(jsonEncode(json)),
        throwsA(isA<FormatException>()),
      );

      final retained = evidence.toJson();
      retained['retention'] = 'discarded';
      expect(
        () => McpBackupEvidence.decode(jsonEncode(retained)),
        throwsA(isA<FormatException>()),
      );
    });

    test('derives recovery actions from the recorded phase', () {
      const transactionId = 'mtx_0123456789abcdef0123456789abcdef';
      McpTransactionRecord record(McpRecoveryPhase phase) =>
          McpTransactionRecord(
            transactionId: transactionId,
            backupId: 'mbk_0123456789abcdef0123456789abcdef',
            operation: 'replace',
            identity: identity,
            phase: phase,
            planId: 'reviewed-plan',
            preSourceFingerprint: 'before',
            preBaselineDigest: 'before-baseline',
            proposedFields: fields,
          );

      expect(
        record(McpRecoveryPhase.prepared).availableActions,
        <McpRecoveryAction>{McpRecoveryAction.rollback},
      );
      expect(
        record(McpRecoveryPhase.published).availableActions,
        <McpRecoveryAction>{
          McpRecoveryAction.rollback,
          McpRecoveryAction.complete,
        },
      );
      expect(
        record(McpRecoveryPhase.recoveryRequired).availableActions,
        <McpRecoveryAction>{McpRecoveryAction.rollback},
      );
      expect(record(McpRecoveryPhase.committed).availableActions, isEmpty);
      expect(record(McpRecoveryPhase.failedRestored).availableActions, isEmpty);
    });

    test('a transaction carries a fresh integrity digest across phases', () {
      final record = McpTransactionRecord(
        transactionId: 'mtx_0123456789abcdef0123456789abcdef',
        backupId: 'mbk_0123456789abcdef0123456789abcdef',
        operation: 'replace',
        identity: identity,
        phase: McpRecoveryPhase.prepared,
        planId: 'reviewed-plan',
        preSourceFingerprint: 'before',
        preBaselineDigest: 'before-baseline',
        proposedFields: fields,
      );
      final published = record.withPhase(
        McpRecoveryPhase.published,
        publishedSourceFingerprint: 'after',
        publishedBaselineDigest: 'after-baseline',
      );
      expect(published.phase, McpRecoveryPhase.published);
      expect(published.artifactDigest, isNot(record.artifactDigest));
      expect(McpTransactionRecord.decode(published.encode()), published);

      final tampered = published.toJson()..['phase'] = 'committed';
      expect(
        () => McpTransactionRecord.decode(jsonEncode(tampered)),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
