import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The schema version of the conversion evidence document.
const int conversionEvidenceSchemaVersion = 1;

/// The largest conversion evidence document that is read or written.
const int maxConversionEvidenceBytes = 4 * 1024 * 1024;

/// The largest nesting depth of a conversion evidence document.
const int maxConversionEvidenceDepth = 24;

/// The largest number of nodes of a conversion evidence document.
const int maxConversionEvidenceNodes = 20000;

/// The native artifact kinds a conversion participant may own.
///
/// The kinds stay native: a converted resource keeps the ownership of the
/// artifact it is. There is no universal Prompt kind. The Pi template kind
/// exists only for an approved tracked conversion.
const List<String> conversionArtifactKinds = <String>[
  'skill-copy',
  'skill-link',
  'skill-canonical',
  'agent-file',
  'prompt-template',
];

/// The role of a participant in a conversion transaction.
enum ConversionParticipantRole { source, target }

/// The intended effect on a participant.
enum ConversionParticipantIntent {
  /// The participant keeps its identity and content.
  retained,

  /// The participant moves to another location.
  relocated,

  /// The participant changes its native form in place.
  reclassified,

  /// The participant is retired by the conversion.
  retired,

  /// The participant is created by the conversion.
  created,
}

/// The phase of a conversion transaction.
enum ConversionEvidencePhase {
  prepared,
  published,
  committed,
  reconciled,
  completed,
  rolledBack,
  recoveryRequired,
}

/// The identity of one participant.
///
/// A managed participant owns an installation identifier. An unmanaged
/// authoring participant owns only a receipt: a receipt never adopts a source
/// or an output.
final class ConversionIdentity {
  const ConversionIdentity({
    this.installationId,
    this.receiptId,
    this.lineageId,
    this.predecessorId,
    this.convertedFromId,
  });

  factory ConversionIdentity.fromJson(Object? value) {
    final map = _object(value, 'identity');
    _knownKeys(map, const {
      'installationId',
      'receiptId',
      'lineageId',
      'predecessorId',
      'convertedFromId',
    }, 'identity');
    return ConversionIdentity(
      installationId: _nullableString(map, 'installationId'),
      receiptId: _nullableString(map, 'receiptId'),
      lineageId: _nullableString(map, 'lineageId'),
      predecessorId: _nullableString(map, 'predecessorId'),
      convertedFromId: _nullableString(map, 'convertedFromId'),
    );
  }

  final String? installationId;
  final String? receiptId;
  final String? lineageId;

  /// The installation identifier this participant replaces.
  final String? predecessorId;

  /// The installation identifier this participant was converted from.
  final String? convertedFromId;

  /// Whether the participant is an ongoing managed installation.
  bool get managed => installationId != null;

  Map<String, Object?> toJson() => <String, Object?>{
    'installationId': installationId,
    'receiptId': receiptId,
    'lineageId': lineageId,
    'predecessorId': predecessorId,
    'convertedFromId': convertedFromId,
  };
}

/// The ownership of one participant before or after the conversion.
final class ConversionOwnership {
  const ConversionOwnership({
    required this.managed,
    required this.nativeForm,
    required this.location,
    required this.scope,
    this.installationId,
    this.receiptId,
    this.nativeProfile,
    this.nativeDestination,
    this.nativeRoot,
    this.baselineDigest,
    this.provenance = const <String, Object?>{},
  });

  factory ConversionOwnership.fromJson(Object? value) {
    final map = _object(value, 'ownership');
    _knownKeys(map, const {
      'managed',
      'installationId',
      'receiptId',
      'nativeForm',
      'nativeProfile',
      'nativeDestination',
      'location',
      'nativeRoot',
      'scope',
      'baselineDigest',
      'provenance',
    }, 'ownership');
    final managed = _bool(map, 'managed');
    final installationId = _nullableString(map, 'installationId');
    final receiptId = _nullableString(map, 'receiptId');
    final ownership = ConversionOwnership(
      managed: managed,
      installationId: installationId,
      receiptId: receiptId,
      nativeForm: _string(map, 'nativeForm'),
      nativeProfile: _nullableString(map, 'nativeProfile'),
      nativeDestination: _nullableString(map, 'nativeDestination'),
      location: _absolutePath(_string(map, 'location')),
      nativeRoot: map['nativeRoot'] == null
          ? null
          : _absolutePath(_string(map, 'nativeRoot')),
      scope: _enumValue(_string(map, 'scope'), const ['project', 'user']),
      baselineDigest: _nullableString(map, 'baselineDigest'),
      provenance: _object(map['provenance'], 'provenance'),
    );
    ownership.validate();
    return ownership;
  }

  /// Whether the ownership is an ongoing managed installation.
  final bool managed;
  final String? installationId;
  final String? receiptId;
  final String nativeForm;
  final String? nativeProfile;

  /// The native destination of the owned artifact.
  ///
  /// The destination is a native concept of the artifact kind: an Agent owns
  /// `native` or `shared`, a Skill owns `claude`, `codex` or `shared`. It is
  /// recorded explicitly so a reconciled record binds the destination of the
  /// target instead of guessing it from another dimension.
  final String? nativeDestination;

  final String location;
  final String? nativeRoot;
  final String scope;
  final String? baselineDigest;

  /// The retained provenance of the artifact.
  final Map<String, Object?> provenance;

  /// Checks that the ownership is internally consistent.
  void validate() {
    if (managed && installationId == null) {
      throw const FormatException(
        'Managed ownership requires an installation identifier.',
      );
    }
    if (!managed && installationId != null) {
      throw const FormatException(
        'Unmanaged ownership cannot carry an installation identifier.',
      );
    }
    if (!managed && receiptId == null) {
      throw const FormatException(
        'Unmanaged ownership requires an authoring receipt.',
      );
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'managed': managed,
    'installationId': installationId,
    'receiptId': receiptId,
    'nativeForm': nativeForm,
    'nativeProfile': nativeProfile,
    if (nativeDestination != null) 'nativeDestination': nativeDestination,
    'location': location,
    'nativeRoot': nativeRoot,
    'scope': scope,
    'baselineDigest': baselineDigest,
    'provenance': provenance,
  };
}

/// The upstream membership of one participant before or after the conversion.
final class ConversionMembership {
  const ConversionMembership({
    required this.kind,
    required this.state,
    this.memberId,
    this.source,
  });

  factory ConversionMembership.fromJson(Object? value) {
    final map = _object(value, 'membership');
    _knownKeys(map, const {
      'kind',
      'state',
      'memberId',
      'source',
    }, 'membership');
    return ConversionMembership(
      kind: _string(map, 'kind'),
      state: _enumValue(_string(map, 'state'), const [
        'active',
        'retired',
        'detached',
      ]),
      memberId: _nullableString(map, 'memberId'),
      source: _nullableString(map, 'source'),
    );
  }

  /// The membership kind, such as a pack membership.
  final String kind;

  /// The membership state after the observation.
  final String state;

  final String? memberId;
  final String? source;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'state': state,
    'memberId': memberId,
    'source': source,
  };
}

/// The verified baseline manifest of one participant.
final class ConversionBaseline {
  const ConversionBaseline({required this.entries});

  factory ConversionBaseline.fromJson(Object? value) {
    final map = _object(value, 'baseline');
    _knownKeys(map, const {'digest', 'entries'}, 'baseline');
    final entries = <Map<String, Object?>>[];
    final raw = _list(map['entries'], 'baseline entries');
    for (final entry in raw) {
      final item = _object(entry, 'baseline entry');
      _knownKeys(item, const {
        'path',
        'type',
        'length',
        'sha256',
      }, 'baseline entry');
      entries.add(<String, Object?>{
        'path': _string(item, 'path'),
        'type': _enumValue(_string(item, 'type'), const [
          'file',
          'directory',
          'link',
        ]),
        'length': _nonNegativeInteger(item, 'length'),
        'sha256': _nullableString(item, 'sha256'),
      });
    }
    final baseline = ConversionBaseline(entries: entries);
    final digest = _string(map, 'digest');
    if (digest != baseline.digest) {
      throw const FormatException('The baseline digest does not bind.');
    }
    return baseline;
  }

  final List<Map<String, Object?>> entries;

  /// The digest that binds the manifest entries.
  String get digest =>
      sha256.convert(utf8.encode(jsonEncode(entries))).toString();

  Map<String, Object?> toJson() => <String, Object?>{
    'digest': digest,
    'entries': entries,
  };
}

/// The protected independent copy of the source payload.
final class ConversionPayloadReference {
  const ConversionPayloadReference({
    required this.path,
    required this.digest,
    required this.length,
    this.protected = true,
  });

  factory ConversionPayloadReference.fromJson(Object? value) {
    final map = _object(value, 'payload');
    _knownKeys(map, const {'path', 'digest', 'length', 'protected'}, 'payload');
    return ConversionPayloadReference(
      path: _absolutePath(_string(map, 'path')),
      digest: _string(map, 'digest'),
      length: _nonNegativeInteger(map, 'length'),
      protected: map.containsKey('protected') ? _bool(map, 'protected') : true,
    );
  }
  final String path;
  final String digest;
  final int length;

  /// Whether the payload is held in protected application storage.
  final bool protected;

  /// Checks that the payload is a protected copy.
  void validate() {
    if (!protected) {
      throw const FormatException(
        'The independent source payload must be protected.',
      );
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'digest': digest,
    'length': length,
    'protected': protected,
  };
}

/// The staged or published native target evidence.
final class ConversionPublicationEvidence {
  const ConversionPublicationEvidence({
    required this.path,
    required this.digest,
    this.verified = false,
  });

  factory ConversionPublicationEvidence.fromJson(Object? value) {
    final map = _object(value, 'publication');
    _knownKeys(map, const {'path', 'digest', 'verified'}, 'publication');
    return ConversionPublicationEvidence(
      path: _absolutePath(_string(map, 'path')),
      digest: _string(map, 'digest'),
      verified: map.containsKey('verified') ? _bool(map, 'verified') : false,
    );
  }

  final String path;
  final String digest;
  final bool verified;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'digest': digest,
    'verified': verified,
  };
}

/// The authority under which a participant is observed.
final class ConversionAuthority {
  const ConversionAuthority({
    required this.scope,
    required this.projectRoot,
    required this.nativeRoot,
    this.approved = false,
  });

  factory ConversionAuthority.fromJson(Object? value) {
    final map = _object(value, 'authority');
    _knownKeys(map, const {
      'scope',
      'projectRoot',
      'nativeRoot',
      'approved',
    }, 'authority');
    return ConversionAuthority(
      scope: _enumValue(_string(map, 'scope'), const ['project', 'user']),
      projectRoot: _absolutePath(_string(map, 'projectRoot')),
      nativeRoot: _absolutePath(_string(map, 'nativeRoot')),
      approved: map.containsKey('approved') ? _bool(map, 'approved') : false,
    );
  }

  final String scope;
  final String projectRoot;
  final String nativeRoot;
  final bool approved;

  Map<String, Object?> toJson() => <String, Object?>{
    'scope': scope,
    'projectRoot': projectRoot,
    'nativeRoot': nativeRoot,
    'approved': approved,
  };
}

/// One participant of a conversion transaction.
final class ConversionParticipant {
  const ConversionParticipant({
    required this.role,
    required this.intent,
    required this.artifactKind,
    required this.location,
    required this.scope,
    this.nativeForm,
    this.nativeProfile,
    this.nativeRoot,
    this.identity,
    this.ownershipBefore,
    this.ownershipAfter,
    this.membershipBefore,
    this.membershipAfter,
    this.baseline,
    this.payload,
    this.staging,
    this.publication,
    this.authority,
  });

  factory ConversionParticipant.fromJson(Object? value) {
    final map = _object(value, 'participant');
    _knownKeys(map, const {
      'role',
      'intent',
      'artifactKind',
      'nativeForm',
      'nativeProfile',
      'location',
      'nativeRoot',
      'scope',
      'identity',
      'ownershipBefore',
      'ownershipAfter',
      'membershipBefore',
      'membershipAfter',
      'baseline',
      'payload',
      'staging',
      'publication',
      'authority',
    }, 'participant');
    final participant = ConversionParticipant(
      role: ConversionParticipantRole.values.firstWhere(
        (value) => value.name == _string(map, 'role'),
        orElse: () => throw const FormatException('Unknown participant role.'),
      ),
      intent: ConversionParticipantIntent.values.firstWhere(
        (value) => value.name == _string(map, 'intent'),
        orElse: () =>
            throw const FormatException('Unknown participant intent.'),
      ),
      artifactKind: _string(map, 'artifactKind'),
      nativeForm: _nullableString(map, 'nativeForm'),
      nativeProfile: _nullableString(map, 'nativeProfile'),
      location: _absolutePath(_string(map, 'location')),
      nativeRoot: map['nativeRoot'] == null
          ? null
          : _absolutePath(_string(map, 'nativeRoot')),
      scope: _enumValue(_string(map, 'scope'), const ['project', 'user']),
      identity: map['identity'] == null
          ? null
          : ConversionIdentity.fromJson(map['identity']),
      ownershipBefore: map['ownershipBefore'] == null
          ? null
          : ConversionOwnership.fromJson(map['ownershipBefore']),
      ownershipAfter: map['ownershipAfter'] == null
          ? null
          : ConversionOwnership.fromJson(map['ownershipAfter']),
      membershipBefore: map['membershipBefore'] == null
          ? null
          : ConversionMembership.fromJson(map['membershipBefore']),
      membershipAfter: map['membershipAfter'] == null
          ? null
          : ConversionMembership.fromJson(map['membershipAfter']),
      baseline: map['baseline'] == null
          ? null
          : ConversionBaseline.fromJson(map['baseline']),
      payload: map['payload'] == null
          ? null
          : ConversionPayloadReference.fromJson(map['payload']),
      staging: map['staging'] == null
          ? null
          : ConversionPublicationEvidence.fromJson(map['staging']),
      publication: map['publication'] == null
          ? null
          : ConversionPublicationEvidence.fromJson(map['publication']),
      authority: map['authority'] == null
          ? null
          : ConversionAuthority.fromJson(map['authority']),
    );
    participant.validate();
    return participant;
  }

  final ConversionParticipantRole role;
  final ConversionParticipantIntent intent;
  final String artifactKind;
  final String? nativeForm;
  final String? nativeProfile;
  final String location;
  final String? nativeRoot;
  final String scope;
  final ConversionIdentity? identity;
  final ConversionOwnership? ownershipBefore;
  final ConversionOwnership? ownershipAfter;
  final ConversionMembership? membershipBefore;
  final ConversionMembership? membershipAfter;
  final ConversionBaseline? baseline;
  final ConversionPayloadReference? payload;
  final ConversionPublicationEvidence? staging;
  final ConversionPublicationEvidence? publication;
  final ConversionAuthority? authority;

  /// Whether the participant keeps an ongoing managed installation.
  bool get managed =>
      ownershipAfter?.managed == true ||
      ownershipBefore?.managed == true ||
      identity?.managed == true;

  /// Checks the internal consistency of the participant.
  void validate() {
    if (!conversionArtifactKinds.contains(artifactKind)) {
      throw FormatException(
        'Unsupported conversion artifact kind: $artifactKind',
      );
    }
    ownershipBefore?.validate();
    ownershipAfter?.validate();
    payload?.validate();
    if (role == ConversionParticipantRole.source && ownershipBefore == null) {
      throw const FormatException(
        'The source participant requires its ownership before.',
      );
    }
    if (role == ConversionParticipantRole.target && ownershipAfter == null) {
      throw const FormatException(
        'The target participant requires its ownership after.',
      );
    }
    final roots = <String>[
      ?nativeRoot,
      ?ownershipBefore?.nativeRoot,
      ?ownershipAfter?.nativeRoot,
      ?authority?.nativeRoot,
    ];
    for (final root in roots) {
      if (!_isWithin(location, root)) {
        throw const FormatException(
          'The participant location escapes its recorded native root.',
        );
      }
    }
    if (ownershipBefore != null && ownershipBefore!.location != location) {
      throw const FormatException(
        'The ownership before does not describe the participant location.',
      );
    }
    if (ownershipAfter != null && ownershipAfter!.location != location) {
      throw const FormatException(
        'The ownership after does not describe the participant location.',
      );
    }
    final participantIdentity = identity;
    if (participantIdentity != null && ownershipAfter != null) {
      if (participantIdentity.managed != ownershipAfter!.managed) {
        throw const FormatException(
          'The participant identity does not agree with its ownership.',
        );
      }
      if (participantIdentity.managed &&
          participantIdentity.installationId !=
              ownershipAfter!.installationId) {
        throw const FormatException(
          'The participant identity does not bind its ownership.',
        );
      }
    }
    if (payload != null) {
      if (baseline == null) {
        throw const FormatException(
          'The independent source payload requires a verified baseline.',
        );
      }
      if (payload!.digest != baseline!.digest) {
        throw const FormatException(
          'The protected payload does not bind the verified baseline.',
        );
      }
    }
    if (role == ConversionParticipantRole.target &&
        artifactKind == 'prompt-template' &&
        !ownershipAfter!.managed) {
      throw const FormatException(
        'A Pi template representation requires a tracked conversion.',
      );
    }
  }

  /// A copy of the participant with the selected observations replaced.
  ConversionParticipant copyWith({
    ConversionParticipantIntent? intent,
    ConversionOwnership? ownershipBefore,
    ConversionOwnership? ownershipAfter,
    ConversionMembership? membershipBefore,
    ConversionMembership? membershipAfter,
    ConversionIdentity? identity,
    ConversionBaseline? baseline,
    ConversionPayloadReference? payload,
    ConversionPublicationEvidence? staging,
    ConversionPublicationEvidence? publication,
    ConversionAuthority? authority,
  }) => ConversionParticipant(
    role: role,
    intent: intent ?? this.intent,
    artifactKind: artifactKind,
    nativeForm: nativeForm,
    nativeProfile: nativeProfile,
    location: location,
    nativeRoot: nativeRoot,
    scope: scope,
    identity: identity ?? this.identity,
    ownershipBefore: ownershipBefore ?? this.ownershipBefore,
    ownershipAfter: ownershipAfter ?? this.ownershipAfter,
    membershipBefore: membershipBefore ?? this.membershipBefore,
    membershipAfter: membershipAfter ?? this.membershipAfter,
    baseline: baseline ?? this.baseline,
    payload: payload ?? this.payload,
    staging: staging ?? this.staging,
    publication: publication ?? this.publication,
    authority: authority ?? this.authority,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'role': role.name,
    'intent': intent.name,
    'artifactKind': artifactKind,
    'nativeForm': nativeForm,
    'nativeProfile': nativeProfile,
    'location': location,
    'nativeRoot': nativeRoot,
    'scope': scope,
    'identity': identity?.toJson(),
    'ownershipBefore': ownershipBefore?.toJson(),
    'ownershipAfter': ownershipAfter?.toJson(),
    'membershipBefore': membershipBefore?.toJson(),
    'membershipAfter': membershipAfter?.toJson(),
    'baseline': baseline?.toJson(),
    'payload': payload?.toJson(),
    'staging': staging?.toJson(),
    'publication': publication?.toJson(),
    'authority': authority?.toJson(),
  };
}

/// The complete evidence of one conversion transaction.
final class ConversionEvidence {
  const ConversionEvidence({
    required this.transactionId,
    required this.operation,
    required this.phase,
    required this.createdScope,
    required this.source,
    required this.target,
    this.approvals = const <String, bool>{},
    this.observations = const <String, Object?>{},
  });

  factory ConversionEvidence.fromJson(Object? value) {
    final map = _object(value, 'conversion evidence');
    _knownKeys(map, const {
      'schemaVersion',
      'transactionId',
      'operation',
      'phase',
      'createdScope',
      'source',
      'target',
      'approvals',
      'observations',
      'digest',
    }, 'conversion evidence');
    if (_integer(map, 'schemaVersion') != conversionEvidenceSchemaVersion) {
      throw const FormatException(
        'Unsupported conversion evidence schema version.',
      );
    }
    final transactionId = _string(map, 'transactionId');
    if (!RegExp(r'^cvx_[a-f0-9]{32}$').hasMatch(transactionId)) {
      throw const FormatException('Invalid conversion transaction identifier.');
    }
    final approvals = <String, bool>{};
    final rawApprovals = _object(map['approvals'], 'approvals');
    for (final entry in rawApprovals.entries) {
      if (entry.value is! bool) {
        throw const FormatException('An approval must be a boolean.');
      }
      approvals[entry.key] = entry.value! as bool;
    }
    final evidence = ConversionEvidence(
      transactionId: transactionId,
      operation: _enumValue(_string(map, 'operation'), const ['convert']),
      phase: ConversionEvidencePhase.values.firstWhere(
        (value) => value.name == _string(map, 'phase'),
        orElse: () =>
            throw const FormatException('Unknown conversion evidence phase.'),
      ),
      createdScope: _enumValue(_string(map, 'createdScope'), const [
        'project',
        'user',
      ]),
      source: ConversionParticipant.fromJson(map['source']),
      target: ConversionParticipant.fromJson(map['target']),
      approvals: approvals,
      observations: _object(map['observations'], 'observations'),
    );
    if (evidence.source.role != ConversionParticipantRole.source ||
        evidence.target.role != ConversionParticipantRole.target) {
      throw const FormatException(
        'The conversion participants are misassigned.',
      );
    }
    final digest = _string(map, 'digest');
    if (digest != evidence.digest) {
      throw const FormatException(
        'The conversion evidence digest does not bind.',
      );
    }
    return evidence;
  }

  final String transactionId;
  final String operation;
  final ConversionEvidencePhase phase;
  final String createdScope;
  final ConversionParticipant source;
  final ConversionParticipant target;
  final Map<String, bool> approvals;
  final Map<String, Object?> observations;

  /// The digest that binds the evidence document.
  String get digest {
    final body = <String, Object?>{
      'schemaVersion': conversionEvidenceSchemaVersion,
      'transactionId': transactionId,
      'operation': operation,
      'phase': phase.name,
      'createdScope': createdScope,
      'source': source.toJson(),
      'target': target.toJson(),
      'approvals': approvals,
      'observations': observations,
    };
    return sha256
        .convert(utf8.encode(jsonEncode(_canonicalJson(body))))
        .toString();
  }

  /// A copy of the evidence with later transaction observations.
  ConversionEvidence copyWith({
    ConversionEvidencePhase? phase,
    ConversionParticipant? source,
    ConversionParticipant? target,
    Map<String, Object?>? observations,
  }) => ConversionEvidence(
    transactionId: transactionId,
    operation: operation,
    phase: phase ?? this.phase,
    createdScope: createdScope,
    source: source ?? this.source,
    target: target ?? this.target,
    approvals: approvals,
    observations: observations ?? this.observations,
  );

  /// A copy of the evidence in another phase.
  ConversionEvidence withPhase(ConversionEvidencePhase phase) =>
      copyWith(phase: phase);

  /// The immutable participant intent before staging or native publication.
  ConversionEvidence get initialIntent => copyWith(
    phase: ConversionEvidencePhase.prepared,
    source: ConversionParticipant.fromJson({
      ...source.toJson(),
      'payload': null,
    }),
    target: ConversionParticipant.fromJson({
      ...target.toJson(),
      'staging': null,
      'publication': null,
    }),
    observations: {...observations, 'coordinatorSourceRemoval': false},
  );

  /// The serialized evidence document.
  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': conversionEvidenceSchemaVersion,
    'transactionId': transactionId,
    'operation': operation,
    'phase': phase.name,
    'createdScope': createdScope,
    'source': source.toJson(),
    'target': target.toJson(),
    'approvals': approvals,
    'observations': observations,
    'digest': digest,
  };

  /// The encoded evidence document.
  String encode() => jsonEncode(toJson());

  /// Reads an evidence document from its encoded form.
  ///
  /// The document is bounded before it is parsed. Unknown keys, an unknown
  /// schema version, a corrupt digest and an inconsistent participant fail
  /// closed: they are never evidence of a free state.
  static ConversionEvidence decode(String encoded) {
    final bytes = utf8.encode(encoded);
    if (bytes.length > maxConversionEvidenceBytes) {
      throw const FormatException(
        'The conversion evidence document exceeds its byte limit.',
      );
    }
    final Object? decoded;
    try {
      if (_lexicalDepth(encoded) > maxConversionEvidenceDepth) {
        throw const FormatException(
          'The conversion evidence exceeds its depth limit.',
        );
      }
      decoded = jsonDecode(encoded);
    } on FormatException {
      rethrow;
    } on Object {
      throw const FormatException('The conversion evidence is not valid JSON.');
    }
    _checkBudget(decoded);
    return ConversionEvidence.fromJson(decoded);
  }
}

/// Recursively sorts JSON-compatible values so the digest of an evidence
/// document is stable across semantically equivalent map insertion orders.
Object? _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.toList()
      ..sort((left, right) => left.toString().compareTo(right.toString()));
    return <String, Object?>{
      for (final key in keys) key.toString(): _canonicalJson(value[key]),
    };
  }
  if (value is List) {
    return <Object?>[for (final item in value) _canonicalJson(item)];
  }
  return value;
}

/// The nesting depth of an encoded document, counted before it is parsed.
///
/// The count is lexical: it follows the brackets outside the string literals
/// so that a deeply nested document is refused instead of reaching the
/// recursive parser.
int _lexicalDepth(String encoded) {
  var depth = 0;
  var deepest = 0;
  var inString = false;
  var escaped = false;
  for (var index = 0; index < encoded.length; index++) {
    final code = encoded.codeUnitAt(index);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (code == 0x5C) {
        escaped = true;
      } else if (code == 0x22) {
        inString = false;
      }
      continue;
    }
    if (code == 0x22) {
      inString = true;
      continue;
    }
    if (code == 0x7B || code == 0x5B) {
      depth++;
      if (depth > deepest) deepest = depth;
    } else if (code == 0x7D || code == 0x5D) {
      depth--;
    }
  }
  return deepest;
}

void _checkBudget(Object? value) {
  var nodes = 0;
  void walk(Object? node, int depth) {
    if (++nodes > maxConversionEvidenceNodes) {
      throw const FormatException(
        'The conversion evidence exceeds its node limit.',
      );
    }
    if (depth > maxConversionEvidenceDepth) {
      throw const FormatException(
        'The conversion evidence exceeds its depth limit.',
      );
    }
    if (node is Map) {
      for (final entry in node.entries) {
        walk(entry.key, depth + 1);
        walk(entry.value, depth + 1);
      }
    } else if (node is List) {
      for (final item in node) {
        walk(item, depth + 1);
      }
    }
  }

  walk(value, 0);
}

bool _isWithin(String path, String root) {
  final normalizedRoot = root.replaceAll('\\', '/');
  final normalizedPath = path.replaceAll('\\', '/');
  if (normalizedPath == normalizedRoot) return true;
  return normalizedPath.startsWith(
    normalizedRoot.endsWith('/') ? normalizedRoot : '$normalizedRoot/',
  );
}

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map<String, Object?>) {
    throw FormatException('The $label must be an object.');
  }
  return value;
}

List<Object?> _list(Object? value, String label) {
  if (value is! List<Object?>) {
    throw FormatException('The $label must be a list.');
  }
  return value;
}

void _knownKeys(Map<String, Object?> map, Set<String> allowed, String label) {
  for (final key in map.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('Unknown $label field: $key');
    }
  }
}

String _string(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('The $key must be a nonblank string.');
  }
  return value;
}

String? _nullableString(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value == null) return null;
  if (value is! String || value.isEmpty) {
    throw FormatException('The $key must be a nonblank string.');
  }
  return value;
}

bool _bool(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! bool) {
    throw FormatException('The $key must be a boolean.');
  }
  return value;
}

int _integer(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! int) {
    throw FormatException('The $key must be an integer.');
  }
  return value;
}

int _nonNegativeInteger(Map<String, Object?> map, String key) {
  final value = _integer(map, key);
  if (value < 0) {
    throw FormatException('The $key must not be negative.');
  }
  return value;
}

String _enumValue(String value, List<String> allowed) {
  if (!allowed.contains(value)) {
    throw FormatException('Unsupported value: $value');
  }
  return value;
}

String _absolutePath(String value) {
  if (!value.startsWith('/') && !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value)) {
    throw const FormatException('A recorded path must be absolute.');
  }
  return value;
}
