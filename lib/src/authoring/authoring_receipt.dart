import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:mamba/mamba.dart';

import '../services/lifecycle_state_service.dart';

/// The directory that holds the authoring receipts of one state root.
const String authoringReceiptDirectoryName = 'authoring-receipts';

/// The identifier of the authoring receipt of one publication.
///
/// The identifier is derived from the reviewed plan and the published
/// location, so the same publication always carries the same receipt.
String authoringReceiptId(String planId, String target) {
  final digest = sha256.convert(utf8.encode('$planId|$target')).toString();
  return 'rcp_${digest.substring(0, 32)}';
}

/// The protected document of one authoring receipt.
///
/// The receipt records the authoring act, the published location and the
/// honest provenance of the output. It is not an installation record: it
/// never adopts a source and it never binds an update source.
Map<String, Object?> authoringReceiptDocument({
  required String receiptId,
  required String planId,
  required String operation,
  required String kind,
  required String profile,
  required String target,
  String? root,
  String? form,
  String? derivedFrom,
  String? sourceInstallationId,
}) => <String, Object?>{
  'schemaVersion': 1,
  'receiptId': receiptId,
  'planId': planId,
  'operation': operation,
  'kind': kind,
  'profile': profile,
  'ownership': 'authorOnly',
  'target': target,
  'root': root,
  'form': form,
  'derivedFrom': derivedFrom,
  'sourceInstallationId': sourceInstallationId,
  'inheritedTracking': false,
  'packMembership': null,
  'originStatus': 'unknown',
};

/// Writes one protected authoring receipt.
///
/// The receipt is written next to the other management evidence of the
/// selected scope. It is bounded and private.
void writeAuthoringReceipt({
  required LifecycleStateService state,
  required String stateRoot,
  required Map<String, Object?> document,
}) {
  final receiptId = document['receiptId'];
  if (receiptId is! String || receiptId.isEmpty) {
    throw MambaException(
      'The authoring receipt has no identifier.',
      exitCode: 4,
    );
  }
  final path = state.io.fs.path.join(
    stateRoot,
    authoringReceiptDirectoryName,
    '$receiptId.json',
  );
  state.writeProtectedDocument(path, utf8.encode(jsonEncode(document)));
}
