import 'dart:convert';

import '../auth/auth.dart';

import '../agent/identity_key_file.dart';
import '../crypto/idr_crypto.dart';
import '../dp/identity_store.dart';
import '../errors.dart';
import '../internal/logging.dart';
import 'enroll_client.dart';
import 'enrollment_models.dart';
import 'registration.dart';
import 'registration_client.dart';

/// DP enroll workflows: kickstart/admin CA, list/approve/reject, device pull.
class EnrollmentManager {
  EnrollmentManager({
    required EnrollClient enroll,
    required RegistrationClient registration,
    required DpIdentityStore identity,
    required IdrCrypto Function() requireCrypto,
  })  : _enroll = enroll,
        _registration = registration,
        _identity = identity,
        _requireCrypto = requireCrypto;

  final EnrollClient _enroll;
  final RegistrationClient _registration;
  final DpIdentityStore _identity;
  final IdrCrypto Function() _requireCrypto;

  List<EnrollmentRequest> pending = const [];

  /// Ensure DP entity + local admin CA keys (for Join approve).
  ///
  /// [package] is the DP package the entity root is registered with
  /// (`personal` | `enterprise`); only `enterprise` roots can issue zones.
  Future<void> ensureAdminCa({
    required IdrAuthSession session,
    required String entityId,
    Future<String> Function(IdrAuthSession session)? ensureEmailEntity,
    String package = 'personal',
  }) async {
    final id = entityId.trim().toLowerCase();
    if (id.isEmpty) throw StateError('entityId required');
    if (ensureEmailEntity != null) {
      await ensureEmailEntity(session);
    }
    await kickstartEntity(session: session, entityId: id, package: package);
  }

  Future<void> kickstartEntity({
    required IdrAuthSession session,
    required String entityId,
    String package = 'personal',
  }) async {
    final pkg = package == 'enterprise' ? 'enterprise' : 'personal';
    final existing = await _identity.loadAdminCa();
    if (existing != null &&
        (existing['issuerSki'] as String?)?.isNotEmpty == true &&
        existing['privateJwk'] is Map &&
        (existing['caCertPem'] as String?)?.contains('BEGIN CERTIFICATE') ==
            true) {
      // CAs saved before the package was recorded were always personal.
      final have = existing['package'] as String? ?? 'personal';
      if (have != pkg) {
        throw IdrTargetException(
          code: IdrTargetErrorCode.configInvalid,
          message: 'This machine\'s root CA was created for the $have '
              'package, not $pkg. Reset it before setting up $pkg.',
        );
      }
      return;
    }
    final crypto = _requireCrypto();
    final ca = crypto.generateEd25519();
    final admin = crypto.generateEd25519();
    final caSki = crypto.ski(ca.publicB64url);
    final adminSki = crypto.ski(admin.publicB64url);
    final caPrivateJwk = ed25519PrivateJwk(
      privatePem: ca.privatePem,
      publicJwk: ca.publicJwk,
    );
    final caCertPem = crypto.caCertPemFromPrivateJwk(
      privateJwk: caPrivateJwk,
      commonName: caSki,
    );
    final permissions = _kickstartPermissions(entityId, pkg);
    final rootCredential = _signedCredential(
      crypto: crypto,
      issuerPrivatePem: ca.privatePem,
      kind: 'entity_root',
      entityId: entityId,
      ski: caSki,
      publicJwk: ca.publicJwk,
      issuerSki: caSki,
      package: pkg,
      permissions: permissions,
    );
    final adminCredential = _signedCredential(
      crypto: crypto,
      issuerPrivatePem: ca.privatePem,
      kind: 'root_admin',
      entityId: entityId,
      ski: adminSki,
      publicJwk: admin.publicJwk,
      issuerSki: caSki,
      package: pkg,
      permissions: permissions,
      zone: '',
    );
    try {
      final kicked = await _enroll.kickstartEntity(
        session: session,
        entityId: entityId,
        package: pkg,
        rootPublicJwk: ca.publicJwk,
        adminPublicJwk: admin.publicJwk,
        rootCredential: rootCredential,
        adminCredential: adminCredential,
        caCertPem: caCertPem,
      );
      if (kicked['exists'] == true) {
        idrLog('kickstart-entity: DP entity already exists for $entityId');
        return;
      }
      await _identity.saveAdminCa(
        issuerSki: caSki,
        privateJwk: caPrivateJwk,
        entityId: entityId,
        caCertPem: caCertPem,
        commonName: caSki,
        package: pkg,
      );
    } catch (e) {
      idrLog('kickstart-entity: $e');
      rethrow;
    }
  }

  Future<List<EnrollmentRequest>> listPending({
    required IdrAuthSession session,
    required String entityId,
  }) async {
    final rows = await _enroll.listPending(
      session: session,
      entityId: entityId,
    );
    pending = rows.map(EnrollmentRequest.fromApi).toList();
    return List.unmodifiable(pending);
  }

  Future<void> reject({
    required IdrAuthSession session,
    required String enrollId,
  }) =>
      _enroll.reject(session: session, enrollId: enrollId);

  /// Admin: approve enrollment using local admin CA (signs CSR → leaf/chain).
  ///
  /// Looks up the pending row for [enrollId] (from [pending] or a fresh list)
  /// when PEMs are omitted. Builds a machine CapabilityCredential skeleton;
  /// the control plane completes signing when issuer JWK is present.
  Future<void> approve({
    required IdrAuthSession session,
    required String enrollId,
    required String entityId,
    CertSignKind kind = CertSignKind.leaf,
    String? leafPem,
    String? chainPem,
    Map<String, dynamic>? credential,
    String? issuerSki,
    Map<String, dynamic>? issuerPrivateJwk,
    String? payingPartyId,
    String? zone,
  }) async {
    final asked = zone?.trim().toLowerCase();
    if (asked != null &&
        asked.isNotEmpty &&
        await _identity.loadZoneCa(asked) == null) {
      throw _noZoneKey(asked);
    }
    EnrollmentRequest? req = _findPending(enrollId);
    if (req == null) {
      await listPending(session: session, entityId: entityId);
      req = _findPending(enrollId);
    }
    if (req == null) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.configMissing,
        message: 'Enrollment request not found.',
      );
    }
    if (req.isZoneKey) return _approveZoneKey(session, req);

    final admin = await _identity.loadAdminCa();
    var ski = issuerSki ?? admin?['issuerSki'] as String?;
    var priv = issuerPrivateJwk ??
        (admin?['privateJwk'] is Map
            ? Map<String, dynamic>.from(admin!['privateJwk'] as Map)
            : null);
    // Under a zone: the zone CA signs, and the chain runs leaf → zone → root.
    // A request made into a zone is signed under that zone.
    String? issuerChainPem;
    final zoneKey = (zone ?? req.zone)?.trim().toLowerCase();
    if (zoneKey != null && zoneKey.isNotEmpty) {
      final zoneCa = await _identity.loadZoneCa(zoneKey);
      if (zoneCa == null) throw _noZoneKey(zoneKey);
      ski = zoneCa['ski'] as String?;
      priv = Map<String, dynamic>.from(zoneCa['privateJwk'] as Map);
      issuerChainPem = zoneCa['chainPem'] as String?;
    }
    if (ski == null || ski.isEmpty || priv == null) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.configMissing,
        message: IdrTargetErrorMessages.configMissing,
      );
    }

    var leaf = leafPem?.trim() ?? '';
    var chain = chainPem?.trim() ?? '';
    if (leaf.isEmpty || chain.isEmpty) {
      final csr = req.csrPem.trim();
      if (csr.isEmpty) {
        throw const IdrTargetException(
          code: IdrTargetErrorCode.configMissing,
          message: IdrTargetErrorMessages.enrollmentCertificatesRequired,
        );
      }
      // Intermediate signing uses the same leaf path until Entity-CA
      // intermediate issuance is wired; kind is recorded by the caller.
      final signed = _requireCrypto().signCsr(
        csrPem: csr,
        caPrivateJwk: priv,
        issuerSki: ski,
        host: req.verifiedFqhn,
        issuerChainPem: issuerChainPem,
      );
      leaf = signed.leafPem;
      chain = signed.chainPem;
    }

    final cred = credential ??
        <String, dynamic>{
          'version': 1,
          'kind': kind == CertSignKind.intermediate ? 'intermediate' : 'machine',
          'entityId': req.entityId ?? entityId,
          'ski': req.subjectSki ?? 'pending',
          if (req.publicJwk != null) 'publicJwk': req.publicJwk,
          if (req.verifiedFqhn != null) 'host': req.verifiedFqhn,
          if (zoneKey != null && zoneKey.isNotEmpty) 'zone': zoneKey,
        };

    await _enroll.approve(
      session: session,
      enrollId: enrollId,
      leafPem: leaf,
      chainPem: chain,
      credential: cred,
      issuerSki: ski,
      issuerPrivateJwk: priv,
      payingPartyId: payingPartyId,
    );
    pending = pending.where((r) => r.id != enrollId).toList();
  }

  /// Root admin: sign a zone key request (a zone admin's key, or a new
  /// sub-zone): a zone CA cert for the requester's key and a root-signed
  /// `zone_authority` credential. An existing zone's admin key carries that
  /// zone's current permissions.
  Future<void> _approveZoneKey(
    IdrAuthSession session,
    EnrollmentRequest req,
  ) async {
    final zone = req.zone;
    final publicJwk = req.publicJwk;
    final ski = req.subjectSki;
    if (zone == null || publicJwk == null || ski == null) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.configMissing,
        message: 'This zone key request is incomplete; ask for a new one.',
      );
    }
    final root = await _requireEnterpriseRoot();
    final crypto = _requireCrypto();
    final certPem = crypto.signIntermediateCa(
      childPublicJwk: publicJwk,
      childCommonName: ski,
      parentPrivateJwk: root.privateJwk,
      parentCommonName: root.root['commonName'] as String? ?? root.ski,
    );
    final record = (await _enroll.listDelegates(session: session))
        .where((z) => z['zone'] == zone)
        .firstOrNull?['credential'];
    final credential = _signedCredential(
      crypto: crypto,
      issuerPrivatePem: ed25519Pkcs8PemFromPrivateJwk(root.privateJwk),
      kind: 'zone_authority',
      entityId: root.entityId,
      ski: ski,
      publicJwk: publicJwk,
      issuerSki: root.ski,
      package: 'enterprise',
      permissions: record is Map
          ? [
              for (final p in (record['permissions'] as List? ?? const [])
                  .cast<Map>())
                Map<String, dynamic>.from(p),
            ]
          : _zonePermissions(root.entityId, zone),
      zone: zone,
    );
    await _enroll.approve(
      session: session,
      enrollId: req.id,
      leafPem: certPem,
      chainPem: '${certPem.trim()}\n${root.certPem.trim()}\n',
      credential: credential,
      issuerSki: root.ski,
    );
    pending = pending.where((r) => r.id != req.id).toList();
  }

  /// Zone admin (or sub-zone creator): make a zone key here and ask the root
  /// admin to sign it. The private key never leaves this machine. Returns
  /// `approved` (already signed), or `pending`.
  Future<String> requestZoneKey({
    required IdrAuthSession session,
    required String entityId,
    required String zone,
  }) async {
    final key = zone.trim().toLowerCase();
    if (await _identity.loadZoneCa(key) != null) return 'approved';
    if ((await _identity.loadZoneKeyRequests()).containsKey(key)) {
      final status = await pullZoneKey(key);
      if (status != 'rejected') return status;
    }
    final crypto = _requireCrypto();
    final keys = crypto.generateEd25519();
    final ski = crypto.ski(keys.publicB64url);
    final created = await _enroll.create(
      session: session,
      entityId: entityId,
      csrPem: crypto.buildCsr(
        privatePem: keys.privatePem,
        fqhn: '$key.zone--$entityId',
      ),
      publicJwk: keys.publicJwk,
      kind: 'zone_authority',
      subjectSki: ski,
      zone: key,
    );
    await _identity.saveZoneKeyRequest(key, {
      'ski': created['subjectSki'] ?? ski,
      'privateJwk': ed25519PrivateJwk(
        privatePem: keys.privatePem,
        publicJwk: keys.publicJwk,
      ),
      'pullToken': created['pullToken'],
      'enrollId': created['enrollId'],
    });
    return 'pending';
  }

  /// Zone keys asked for here and not signed yet.
  Future<List<String>> zoneKeyRequests() async =>
      (await _identity.loadZoneKeyRequests()).keys.toList()..sort();

  /// Fetch a requested zone key once the root signed it: `approved` (now
  /// usable here), `rejected` (request dropped), `pending`, or `none`.
  Future<String> pullZoneKey(String zone) async {
    final asked = (await _identity.loadZoneKeyRequests())[zone];
    if (asked == null) {
      return await _identity.loadZoneCa(zone) != null ? 'approved' : 'none';
    }
    final Map<String, dynamic> pulled;
    try {
      pulled = await _enroll.pull(pullToken: asked['pullToken'] as String);
    } catch (e) {
      idrLog('zone key pull: $e');
      return 'pending';
    }
    switch (pulled['status']) {
      case 'rejected':
        await _identity.saveZoneKeyRequest(zone, null);
        return 'rejected';
      case 'approved':
        final certPem = pulled['certPem'] as String?;
        if (certPem == null) return 'pending';
        await _identity.saveZoneCa(zone, {
          'ski': pulled['ski'] ?? asked['ski'],
          'privateJwk': asked['privateJwk'],
          'certPem': certPem,
          'chainPem': pulled['chainPem'] as String? ?? certPem,
          'deviceId': asked['enrollId'],
          'issuedAt': DateTime.now().toUtc().toIso8601String(),
        });
        await _identity.saveZoneKeyRequest(zone, null);
        return 'approved';
      default:
        return 'pending';
    }
  }

  /// Root admin: issue a zone CA under the enterprise root and register it.
  ///
  /// Generates the zone key here, signs a zone CA cert (path length 0) and a
  /// `zone_authority` credential with the root CA key, registers both via
  /// `issue-delegate`, then stores the zone key locally. Idempotent per zone.
  Future<ZoneAuthority> issueZoneAuthority({
    required IdrAuthSession session,
    required String zone,
  }) async {
    final key = zone.trim().toLowerCase();
    if (key.isEmpty) throw StateError('zone required');

    final existing = await _identity.loadZoneCa(key);
    if (existing != null) return _zoneAuthority(key, existing);

    final (
      :root,
      ski: rootSki,
      certPem: rootCertPem,
      :entityId,
      privateJwk: rootPrivateJwk,
    ) = await _requireEnterpriseRoot();

    final crypto = _requireCrypto();
    final zoneKeys = crypto.generateEd25519();
    final zoneSki = crypto.ski(zoneKeys.publicB64url);
    final zoneCertPem = crypto.signIntermediateCa(
      childPublicJwk: zoneKeys.publicJwk,
      childCommonName: zoneSki,
      parentPrivateJwk: rootPrivateJwk,
      parentCommonName: root['commonName'] as String? ?? rootSki,
    );
    final credential = _signedCredential(
      crypto: crypto,
      issuerPrivatePem: ed25519Pkcs8PemFromPrivateJwk(rootPrivateJwk),
      kind: 'zone_authority',
      entityId: entityId,
      ski: zoneSki,
      publicJwk: zoneKeys.publicJwk,
      issuerSki: rootSki,
      package: 'enterprise',
      permissions: _zonePermissions(entityId, key),
      zone: key,
    );

    final issued = await _enroll.issueDelegate(
      session: session,
      issuerSki: rootSki,
      credential: credential,
      zone: key,
      zoneCertPem: zoneCertPem,
    );
    final entry = <String, dynamic>{
      'ski': zoneSki,
      'privateJwk': ed25519PrivateJwk(
        privatePem: zoneKeys.privatePem,
        publicJwk: zoneKeys.publicJwk,
      ),
      'certPem': zoneCertPem,
      'chainPem': '${zoneCertPem.trim()}\n${rootCertPem.trim()}\n',
      'deviceId': issued['deviceId'],
      'issuedAt': DateTime.now().toUtc().toIso8601String(),
    };
    await _identity.saveZoneCa(key, entry);
    idrLog('zone authority issued: zone=$key ski=$zoneSki');
    return _zoneAuthority(key, entry);
  }

  /// The enterprise root CA held on this machine (zones are issued and
  /// re-signed with it).
  Future<
      ({
        Map<String, dynamic> root,
        String ski,
        String certPem,
        String entityId,
        Map<String, dynamic> privateJwk,
      })> _requireEnterpriseRoot() async {
    final root = await _identity.loadAdminCa();
    final ski = root?['issuerSki'] as String?;
    final certPem = root?['caCertPem'] as String?;
    final entityId = root?['entityId'] as String?;
    if (root == null ||
        ski == null ||
        root['privateJwk'] is! Map ||
        certPem == null ||
        entityId == null) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.configMissing,
        message: 'This machine has no root CA. Set it up as the root admin first.',
      );
    }
    if (root['package'] != 'enterprise') {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.configInvalid,
        message: 'Zone certificates need an enterprise root CA; this machine\'s '
            'root CA is on the personal package.',
      );
    }
    return (
      root: root,
      ski: ski,
      certPem: certPem,
      entityId: entityId,
      privateJwk: Map<String, dynamic>.from(root['privateJwk'] as Map),
    );
  }

  /// Root admin: set the services a zone's members may use (`["*"]` = all).
  ///
  /// Re-signs the zone's current credential (from billing) with the root key,
  /// changing only the `acl.service` service list. Members inherit it; the
  /// zone key and certificate are unchanged, so nobody re-enrolls.
  Future<({String zone, List<String> allowedServices, int policyVersion})>
      setZonePolicy({
    required IdrAuthSession session,
    required String zone,
    required List<String> services,
  }) async {
    final key = zone.trim().toLowerCase();
    final allowed = normalizeServices(services);
    final root = await _requireEnterpriseRoot();

    final current = (await _enroll.listDelegates(session: session))
        .where((z) => z['zone'] == key)
        .firstOrNull;
    final cred = current?['credential'];
    if (cred is! Map) {
      throw IdrTargetException(
        code: IdrTargetErrorCode.configMissing,
        message: 'Zone $key has no certificate on billing. Issue it first.',
      );
    }
    if (cred['issuerSki'] != root.ski) {
      throw IdrTargetException(
        code: IdrTargetErrorCode.configInvalid,
        message: 'Zone $key was issued by another root CA than this machine\'s.',
      );
    }

    final permissions = <Map<String, dynamic>>[
      for (final p in (cred['permissions'] as List? ?? const []).cast<Map>())
        _withServices(Map<String, dynamic>.from(p), allowed),
    ];
    if (!permissions.any((p) => p['action'] == 'acl.service')) {
      permissions.add({
        'action': 'acl.service',
        'scope': {
          'entity': root.entityId,
          'service': allowed,
          'transport': ['relay', 'webrtc'],
        },
        'delegable': true,
      });
    }

    final crypto = _requireCrypto();
    final signed = _signedCredential(
      crypto: crypto,
      issuerPrivatePem: ed25519Pkcs8PemFromPrivateJwk(root.privateJwk),
      kind: cred['kind'] as String,
      entityId: cred['entityId'] as String,
      ski: cred['ski'] as String,
      publicJwk: Map<String, dynamic>.from(cred['publicJwk'] as Map),
      issuerSki: root.ski,
      package: cred['package'] as String? ?? 'enterprise',
      permissions: permissions,
      zone: cred['zone'] as String?,
      host: cred['host'] as String?,
    );
    final stored = await _enroll.setZonePolicy(
      session: session,
      credential: signed,
    );
    return (
      zone: key,
      allowedServices: (stored['allowedServices'] as List? ?? allowed)
          .map((e) => '$e')
          .toList(),
      policyVersion: (stored['policyVersion'] as num?)?.toInt() ?? 0,
    );
  }

  /// [p] with its `scope.service` set to [services] when it is `acl.service`.
  static Map<String, dynamic> _withServices(
    Map<String, dynamic> p,
    List<String> services,
  ) =>
      p['action'] != 'acl.service'
          ? p
          : {
              ...p,
              'scope': {
                ...Map<String, dynamic>.from(p['scope'] as Map? ?? const {}),
                'service': services,
              },
            };

  /// Service names for a policy: lowercase, unique, sorted; `*` alone = all.
  static List<String> normalizeServices(List<String> services) {
    final names = {
      for (final s in services)
        for (final part in s.split(','))
          if (part.trim().isNotEmpty) part.trim().toLowerCase(),
    };
    if (names.isEmpty) {
      throw ArgumentError('at least one service (or "*") is required');
    }
    if (names.contains('*')) return const ['*'];
    final bad = names.where((n) => !RegExp(r'^[a-z0-9][a-z0-9._-]*$').hasMatch(n));
    if (bad.isNotEmpty) throw ArgumentError('invalid service name: ${bad.first}');
    return names.toList()..sort();
  }

  /// Zone CAs held on this machine.
  Future<List<ZoneAuthority>> localZoneAuthorities() async => [
        for (final e in (await _identity.loadZoneCas()).entries)
          _zoneAuthority(e.key, e.value),
      ];

  static ZoneAuthority _zoneAuthority(String zone, Map<String, dynamic> e) => (
        zone: zone,
        ski: e['ski'] as String,
        certPem: e['certPem'] as String,
        deviceId: e['deviceId'] as String?,
        issuedAt: DateTime.tryParse(e['issuedAt'] as String? ?? '') ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      );

  /// Root's grant narrowed to [zone]: same actions, names under the zone.
  /// No `zone.delegate`: zone CAs have path length 0 and never sub-delegate.
  static List<Map<String, dynamic>> _zonePermissions(
    String entityId,
    String zone,
  ) =>
      [
        for (final p in _kickstartPermissions(entityId, 'personal'))
          {
            ...p,
            'scope': {
              ...(p['scope'] as Map<String, dynamic>),
              if ((p['scope'] as Map).containsKey('name')) 'name': zone,
            },
          },
      ];

  /// Device: poll enroll-pull. Returns `approved`, `rejected`, or `pending`.
  Future<String> pull({
    required String pullToken,
    required IdrTargetRegistration? registration,
    required Future<void> Function(IdrTargetRegistration next) onRegistrationUpdated,
  }) async {
    try {
      final pulled = await _enroll.pull(pullToken: pullToken);
      final status = pulled['status'] as String?;
      if (status == 'rejected') return 'rejected';
      if (status != 'approved') return 'pending';
      final credential = Map<String, dynamic>.from(
        (pulled['credential'] as Map?)?.cast<String, dynamic>() ?? {},
      );
      if (credential.isEmpty) return 'pending';
      final crypto = _requireCrypto();
      final machine = await _identity.ensureMachineKey(crypto);
      final ski =
          (pulled['ski'] as String?) ?? crypto.ski(machine.publicB64url);
      if (pulled['certPem'] != null) {
        credential['certPem'] = pulled['certPem'];
      }
      if (pulled['chainPem'] != null) {
        credential['chainPem'] = pulled['chainPem'];
      }
      if (pulled['platformCertPem'] != null) {
        credential['platformCertPem'] = pulled['platformCertPem'];
      }
      if (pulled['platformRootPem'] != null) {
        credential['platformRootPem'] = pulled['platformRootPem'];
      }
      // Legacy nested shape from enroll-pull when top-level PEMs are absent.
      final nested = pulled['platformCertCosign'];
      if (nested is Map) {
        final map = nested.cast<String, dynamic>();
        if (credential['platformCertPem'] == null &&
            map['platformCertPem'] != null) {
          credential['platformCertPem'] = map['platformCertPem'];
        }
        if (credential['platformRootPem'] == null &&
            map['platformRootPem'] != null) {
          credential['platformRootPem'] = map['platformRootPem'];
        }
      }
      final fqhn =
          (pulled['host'] as String?) ?? registration?.verifiedFqhn;
      credential['ski'] ??= ski;
      credential['publicJwk'] ??= machine.publicJwk;
      credential['entityId'] ??= registration?.entityId;
      if (fqhn != null && fqhn.isNotEmpty) {
        credential['host'] ??= fqhn;
      }
      final signed = await ensureSignedMachineCredential(credential);
      await _identity.saveMachineIdentity(
        privatePem: machine.privatePem,
        publicB64url: machine.publicB64url,
        publicJwk: machine.publicJwk,
        credential: signed,
        fqhn: fqhn,
        ski: ski,
      );
      await clearPullToken(
        registration: registration,
        fqhn: fqhn,
        ski: ski,
        onRegistrationUpdated: onRegistrationUpdated,
      );
      return 'approved';
    } catch (e) {
      idrLog('enroll-pull: $e');
      final identity = await _identity.loadMachineIdentity();
      final cred =
          (identity?['credential'] as Map?)?.cast<String, dynamic>();
      if (cred != null &&
          isCompleteMachineCredential(Map<String, dynamic>.from(cred))) {
        await clearPullToken(
          registration: registration,
          fqhn: identity?['fqhn'] as String?,
          ski: identity?['ski'] as String?,
          onRegistrationUpdated: onRegistrationUpdated,
        );
        return 'approved';
      }
      return 'pending';
    }
  }

  Future<void> clearPullToken({
    required IdrTargetRegistration? registration,
    String? fqhn,
    String? ski,
    required Future<void> Function(IdrTargetRegistration next)
        onRegistrationUpdated,
  }) async {
    final reg = registration;
    if (reg == null || reg.enrollPullToken == null) return;
    final next = IdrTargetRegistration(
      entityId: reg.entityId,
      hostLabel: reg.hostLabel,
      verifiedFqhn: fqhn ?? reg.verifiedFqhn,
      machineSki: ski ?? reg.machineSki,
      payingPartyId: reg.payingPartyId,
      seatId: reg.seatId,
      enrollPullToken: null,
    );
    await _registration.save(next);
    await onRegistrationUpdated(next);
  }

  /// Clear local Target enroll wait after reject (admin dual-role reset).
  Future<IdrTargetRegistration?> clearPendingTargetEnrollment(
    IdrTargetRegistration? registration,
  ) async {
    final reg = registration;
    if (reg == null) return null;
    final cleared = IdrTargetRegistration(
      entityId: reg.entityId,
      hostLabel: '',
      verifiedFqhn: '',
      machineSki: reg.machineSki,
      payingPartyId: reg.payingPartyId,
      seatId: null,
      enrollPullToken: null,
    );
    await _registration.save(cleared);
    return cleared;
  }

  static IdrTargetException _noZoneKey(String zone) => IdrTargetException(
        code: IdrTargetErrorCode.configMissing,
        message: 'No key for zone $zone on this machine. The root admin '
            'machine issues zones; a zone admin gets its key at setup.',
      );

  EnrollmentRequest? _findPending(String enrollId) {
    for (final r in pending) {
      if (r.id == enrollId) return r;
    }
    return null;
  }

  /// Sign leaf stores a platform cosign without an issuer signature.
  /// Fill issuerSki, signature, and validity from the local admin CA.
  Future<Map<String, dynamic>> ensureSignedMachineCredential(
    Map<String, dynamic> credential,
  ) async {
    final nbf = credential['notBefore'];
    final exp = credential['notAfter'];
    if (isCompleteMachineCredential(credential) &&
        nbf is String &&
        nbf.isNotEmpty &&
        exp is String &&
        exp.isNotEmpty) {
      return credential;
    }
    final admin = await _identity.loadAdminCa();
    final caSki = admin?['issuerSki'] as String?;
    final priv = admin?['privateJwk'];
    final publicJwk = credential['publicJwk'];
    final ski = credential['ski'] as String?;
    final entityId = credential['entityId'] as String?;
    final host = credential['host'] as String?;
    if (caSki == null ||
        caSki.isEmpty ||
        priv is! Map ||
        publicJwk is! Map ||
        ski == null ||
        ski.isEmpty ||
        entityId == null ||
        entityId.isEmpty ||
        host == null ||
        host.isEmpty) {
      return credential;
    }
    final permissions = <Map<String, dynamic>>[];
    final rawPerms = credential['permissions'];
    if (rawPerms is List) {
      for (final item in rawPerms) {
        if (item is Map) {
          permissions.add(Map<String, dynamic>.from(item));
        }
      }
    }
    final signed = _signedCredential(
      crypto: _requireCrypto(),
      issuerPrivatePem: ed25519Pkcs8PemFromPrivateJwk(
        Map<String, dynamic>.from(priv),
      ),
      kind: (credential['kind'] as String?) ?? 'machine',
      entityId: entityId,
      ski: ski,
      publicJwk: Map<String, dynamic>.from(publicJwk),
      issuerSki: caSki,
      package: (credential['package'] as String?) ?? 'personal',
      permissions: permissions,
      host: host,
    );
    for (final key in const [
      'platformCosign',
      'certPem',
      'chainPem',
      'platformCertPem',
      'platformRootPem',
      'seatId',
    ]) {
      final value = credential[key];
      if (value != null) signed[key] = value;
    }
    return signed;
  }

  static bool isCompleteMachineCredential(Map<String, dynamic> credential) {
    final issuer = credential['issuerSki'] ?? credential['issuer_ski'];
    final sig = credential['signature'];
    final host = credential['host'];
    return issuer is String &&
        issuer.isNotEmpty &&
        sig is String &&
        sig.isNotEmpty &&
        host is String &&
        host.isNotEmpty;
  }

  static List<Map<String, dynamic>> _kickstartPermissions(
    String entityId,
    String package,
  ) {
    final actions = package == 'enterprise'
        ? const [
            'admin.invite',
            'cert.issue',
            'zone.ns',
            'zone.delegate',
            'machine.bind',
            'machine.connect',
            'seat.bind',
            'entity.read',
            'presence.register',
            'presence.ensure_relay',
            'session.accept',
            'session.request',
            'turn.mint',
            'acl.service',
            'domain.alias',
          ]
        : const [
            'cert.issue',
            'machine.bind',
            'machine.connect',
            'seat.bind',
            'entity.read',
            'presence.register',
            'presence.ensure_relay',
            'session.accept',
            'session.request',
            'turn.mint',
            'acl.service',
            'domain.alias',
          ];
    return [
      for (final action in actions)
        {
          'action': action,
          'scope': action == 'acl.service'
              ? {
                  'entity': entityId,
                  'service': ['*'],
                  'transport': ['relay', 'webrtc'],
                }
              : action == 'seat.bind' ||
                      action == 'entity.read' ||
                      action == 'admin.invite'
                  ? {'entity': entityId}
                  : {'entity': entityId, 'name': ''},
          'delegable': true,
        },
    ];
  }

  static Map<String, dynamic> _signedCredential({
    required IdrCrypto crypto,
    required String issuerPrivatePem,
    required String kind,
    required String entityId,
    required String ski,
    required Map<String, dynamic> publicJwk,
    required String issuerSki,
    required String package,
    required List<Map<String, dynamic>> permissions,
    String? zone,
    String? host,
  }) {
    final now = DateTime.now().toUtc();
    final unsigned = <String, dynamic>{
      'version': 1,
      'kind': kind,
      'entityId': entityId,
      'ski': ski,
      'publicJwk': publicJwk,
      'permissions': permissions,
      'zone': zone,
      'host': host,
      'issuerSki': issuerSki,
      'notBefore': now.toIso8601String(),
      'notAfter': now.add(const Duration(days: 365)).toIso8601String(),
      'package': package,
    };
    final payload = utf8.encode(jsonEncode(unsigned));
    final header =
        base64Url.encode(utf8.encode('{"alg":"EdDSA"}')).replaceAll('=', '');
    final payloadB64 = base64Url.encode(payload).replaceAll('=', '');
    final signingInput = '$header.$payloadB64';
    final sig = crypto.sign(
      privatePem: issuerPrivatePem,
      message: utf8.encode(signingInput),
    );
    return {...unsigned, 'signature': '$signingInput.$sig'};
  }
}
