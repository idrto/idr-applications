import 'dart:convert';

import '../auth/auth.dart';

import '../crypto/idr_crypto.dart';
import '../dp/identity_store.dart';
import '../errors.dart';
import '../internal/logging.dart';
import 'enroll_client.dart';
import 'registration.dart';
import 'registration_client.dart';

/// Entity/host registration workflows (HTTP stays in [RegistrationClient]).
///
/// Owns ensure/lookup entity, host register + SKI rotate, persist, CSR +
/// enroll-create. Enrollment pull/approve live in EnrollmentManager.
class RegistrationManager {
  RegistrationManager({
    required RegistrationClient client,
    required EnrollClient enroll,
    required DpIdentityStore identity,
    required IdrCrypto Function() requireCrypto,
    required Future<void> Function({
      required IdrAuthSession session,
      required String entityId,
    }) ensureAdminCa,
  })  : _client = client,
        _enroll = enroll,
        _identity = identity,
        _requireCrypto = requireCrypto,
        _ensureAdminCa = ensureAdminCa;

  final RegistrationClient _client;
  final EnrollClient _enroll;
  final DpIdentityStore _identity;
  final IdrCrypto Function() _requireCrypto;
  final Future<void> Function({
    required IdrAuthSession session,
    required String entityId,
  }) _ensureAdminCa;

  Future<IdrTargetRegistration?> load() => _client.load();

  Future<void> save(IdrTargetRegistration reg) => _client.save(reg);

  Future<void> clear() => _client.clear();

  Future<({bool exists, String entityId})> probePersonalEntity(
    IdrAuthSession session,
  ) async {
    final r = await _client.lookupEmailEntity(session);
    return (exists: r.exists, entityId: r.entityId);
  }

  Future<({bool available, String verifiedFqhn})> isHostAvailable({
    required IdrAuthSession session,
    required String hostLabel,
    String? entityId,
    String? zone,
  }) async {
    final label = hostLabel.trim().toLowerCase();
    if (label.isEmpty || label.contains('--')) {
      return (available: false, verifiedFqhn: '');
    }
    final eid = (entityId ?? session.email).trim().toLowerCase();
    if (eid.isEmpty) {
      throw StateError('entityId required for host availability');
    }
    final r = await _client.checkHostAvailable(
      session: session,
      entityId: eid,
      hostLabel: label,
      zone: zone,
    );
    return (available: r.available, verifiedFqhn: r.verifiedFqhn);
  }

  /// Register personal entity + host + CSR enroll-create.
  ///
  /// Returns registration with [IdrTargetRegistration.enrollPullToken] when
  /// enroll-create succeeds. Does not pull or mint entitlement.
  Future<IdrTargetRegistration> registerHost({
    required IdrAuthSession session,
    required String label,
    String? payingPartyId,
    String? joinEntityId,
    String? zone,
  }) async {
    // Joining an existing entity (Enterprise Target, not the owner): the
    // entity root belongs to the owner, so never kickstart it from here.
    final join = joinEntityId?.trim().toLowerCase();
    final entityId = join != null && join.isNotEmpty
        ? join
        : await _client.ensureEmailEntity(session);
    final crypto = _requireCrypto();
    if (join == null || join.isEmpty) {
      await _ensureAdminCa(session: session, entityId: entityId);
    } else if (!await _enroll.entityExists(session: session, entityId: entityId)) {
      throw IdrTargetException(
        code: IdrTargetErrorCode.hostRejected,
        message: 'Entity $entityId does not exist. The organization owner '
            'must run `idrt enterprise setup --role admin` first.',
      );
    }

    var machine = await _identity.ensureMachineKey(
      crypto,
      forHostLabel: label,
    );
    var ski = crypto.ski(machine.publicB64url);

    IdrTargetRegistration reg;
    try {
      reg = await _client.registerHost(
        session: session,
        entityId: entityId,
        hostLabel: label,
        machineSki: ski,
        payingPartyId: payingPartyId,
        publicJwkJson: jsonEncode(machine.publicJwk),
        zone: zone,
      );
    } catch (e) {
      if (!isMachineSkiConflict(e)) rethrow;
      idrLog('registerHost SKI conflict — rotating machine key');
      machine = await _identity.rotateMachineKey(crypto);
      ski = crypto.ski(machine.publicB64url);
      reg = await _client.registerHost(
        session: session,
        entityId: entityId,
        hostLabel: label,
        machineSki: ski,
        payingPartyId: payingPartyId,
        publicJwkJson: jsonEncode(machine.publicJwk),
        zone: zone,
      );
    }

    Future<Map<String, dynamic>> enrollCreate() => _enroll.create(
      session: session,
      entityId: entityId,
      host: reg.verifiedFqhn,
      csrPem: crypto.buildCsr(
        privatePem: machine.privatePem,
        fqhn: reg.verifiedFqhn,
      ),
      publicJwk: machine.publicJwk,
      kind: 'machine_target',
      subjectSki: ski,
      zone: zone,
    );

    Map<String, dynamic> enroll;
    try {
      enroll = await enrollCreate();
    } catch (e) {
      // Re-registering under a new name (e.g. now with its zone): this key
      // already backs the old device. A new name gets a new key.
      if (!isMachineSkiConflict(e)) rethrow;
      idrLog('enroll-create SKI conflict — rotating machine key');
      machine = await _identity.rotateMachineKey(crypto);
      ski = crypto.ski(machine.publicB64url);
      enroll = await enrollCreate();
    }
    final pullToken = enroll['pullToken'] as String?;

    final credential = <String, dynamic>{
      'version': 1,
      'kind': 'machine',
      'entityId': entityId,
      'ski': ski,
      'publicJwk': machine.publicJwk,
      'host': reg.verifiedFqhn,
    };
    await _identity.saveMachineIdentity(
      privatePem: machine.privatePem,
      publicB64url: machine.publicB64url,
      publicJwk: machine.publicJwk,
      credential: credential,
      fqhn: reg.verifiedFqhn,
      ski: ski,
    );

    final withEnroll = IdrTargetRegistration(
      entityId: reg.entityId,
      hostLabel: reg.hostLabel,
      verifiedFqhn: reg.verifiedFqhn,
      machineSki: ski,
      payingPartyId: payingPartyId ?? reg.payingPartyId,
      seatId: reg.seatId,
      enrollPullToken: pullToken,
    );
    await _client.save(withEnroll);
    return withEnroll;
  }

  /// SKI already bound / host CONFLICT — rotate local machine key and retry.
  static bool isMachineSkiConflict(Object e) {
    if (e is IdrTargetException) {
      if (e.code == IdrTargetErrorCode.hostAlreadyRegistered ||
          e.code == IdrTargetErrorCode.duplicateHost) {
        return true;
      }
    }
    final msg = e.toString();
    return msg.contains('already bound to a seat') || msg.contains('CONFLICT');
  }
}
