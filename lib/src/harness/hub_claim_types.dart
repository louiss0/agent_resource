/// The shape shared by the Agent and MCP hub-and-spoke claim models.
///
/// Each hub keeps its own claim kinds, provenance extras and native transport
/// details. The wire shape of one claim, its provenance and a canonical
/// registration is defined once here so the two hubs cannot drift apart.
library;

abstract class HubClaimProvenance<H> {
  const HubClaimProvenance({
    required this.sourceHarness,
    required this.sourceProfile,
    required this.sourcePath,
  });

  final H sourceHarness;
  final String sourceProfile;
  final String sourcePath;

  /// The stable wire spelling, supplied by the concrete hub.
  String get sourceHarnessWire;

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceHarness': sourceHarnessWire,
    'sourceProfile': sourceProfile,
    'sourcePath': sourcePath,
  };
}

abstract interface class HubClaimWire {
  Map<String, Object?> toJsonBase();
}

abstract class HubClaim<K extends Enum, P extends HubClaimProvenance<Object?>>
    implements HubClaimWire {
  const HubClaim({
    required this.canonicalPath,
    required this.sourcePath,
    required this.kind,
    required this.value,
    required this.provenance,
    this.detail,
  });

  final String canonicalPath;
  final String sourcePath;
  final K kind;
  final Object? value;
  final P provenance;
  final String? detail;

  @override
  Map<String, Object?> toJsonBase() => <String, Object?>{
    'canonicalPath': canonicalPath,
    'sourcePath': sourcePath,
    'kind': kind.name,
    'provenance': provenance.toJson(),
    if (detail != null) 'detail': detail,
  };
}

abstract interface class HubClaimsWire {
  Map<String, Object?> toJsonBase();
}

abstract class HubClaims<H, C extends HubClaimWire> implements HubClaimsWire {
  const HubClaims({
    required this.sourceHarness,
    required this.sourceProfile,
    required this.claims,
    required this.nativeFields,
  });

  final H sourceHarness;
  final String sourceProfile;
  final List<C> claims;
  final Map<String, Object?> nativeFields;

  /// The stable wire spelling, supplied by the concrete hub.
  String get sourceHarnessWire;

  @override
  Map<String, Object?> toJsonBase() => <String, Object?>{
    'sourceHarness': sourceHarnessWire,
    'sourceProfile': sourceProfile,
    'claims': <Object?>[for (final claim in claims) claim.toJsonBase()],
  };
}
