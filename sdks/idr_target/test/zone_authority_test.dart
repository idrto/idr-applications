import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idr_target/src/auth/auth.dart';
import 'package:idr_dp_ffi/idr_dp_ffi.dart' show IdrDpCrypto;
import 'package:idr_target/src/crypto/idr_crypto.dart';
import 'package:idr_target/src/dp/identity_store.dart';
import 'package:idr_target/src/errors.dart';
import 'package:idr_target/src/registration/enroll_client.dart';
import 'package:idr_target/src/registration/enrollment_manager.dart';
import 'package:idr_target/src/registration/registration_client.dart';
import 'package:test/test.dart';

import 'support/memory_storage.dart';

/// Real `idr_dp` crypto (zone CA + chain signing); HTTP is mocked.
/// Chain signatures themselves are checked in the Rust and billing tests.
void main() {
  final libPath = IdrDpCrypto.resolveLibraryPath(null);
  final skip = File(libPath).existsSync()
      ? false
      : 'build idr-dp-ffi first (or set IDR_DP_LIB): $libPath';

  const session = IdrAuthSession(token: 't', email: 'root@acme.test');
  const entity = 'root@acme.test';

  late IdrCrypto crypto;
  late SessionStore store;
  late List<http.Request> requests;
  late http.Response Function(http.Request) respond;

  EnrollmentManager manager() => EnrollmentManager(
        enroll: EnrollClient(
          controlPlaneUrl: 'http://cp.test',
          httpClient: MockClient((r) async {
            requests.add(r);
            return respond(r);
          }),
        ),
        registration:
            RegistrationClient(controlPlaneUrl: 'http://cp.test', store: store),
        identity: DpIdentityStore(store),
        requireCrypto: () => crypto,
      );

  Map<String, dynamic> body(String path) => jsonDecode(
        requests.lastWhere((r) => r.url.path.endsWith(path)).body,
      ) as Map<String, dynamic>;

  setUp(() async {
    if (skip != false) return;
    crypto = IdrDpCrypto.open(libraryPath: libPath);
    store = SessionStore(storage: MemoryStorage());
    requests = [];
    respond = (r) => http.Response(
          jsonEncode(r.url.path.endsWith('issue-delegate')
              ? {'deviceId': 'dev-zone-a', 'zone': 'zone-a'}
              : {'entityId': entity}),
          201,
        );
    // Enterprise root CA on this machine.
    await manager().ensureAdminCa(
      session: session,
      entityId: entity,
      package: 'enterprise',
    );
  });

  test('issues a root-signed zone authority and keeps its key locally', () async {
    final m = manager();
    final zone = await m.issueZoneAuthority(session: session, zone: 'Zone-A');

    final sent = body('issue-delegate');
    final root = (await DpIdentityStore(store).loadAdminCa())!;
    final cred = sent['credential'] as Map<String, dynamic>;
    expect(sent['kind'], 'zone_authority');
    expect(sent['zone'], 'zone-a');
    expect(sent['issuerSki'], root['issuerSki']);
    expect(sent['zoneCertPem'], contains('BEGIN CERTIFICATE'));
    expect(cred['kind'], 'zone_authority');
    expect(cred['zone'], 'zone-a');
    expect(cred['issuerSki'], root['issuerSki']);
    expect(cred['ski'], zone.ski);
    expect(cred['package'], 'enterprise');
    expect((cred['signature'] as String).split('.'), hasLength(3));
    // Canonical field order (billing verifies the JWS byte-for-byte).
    expect(cred.keys.toList().sublist(0, 12), [
      'version', 'kind', 'entityId', 'ski', 'publicJwk', 'permissions',
      'zone', 'host', 'issuerSki', 'notBefore', 'notAfter', 'package',
    ]);
    final perms = (cred['permissions'] as List).cast<Map>();
    expect(perms.map((p) => p['action']), isNot(contains('zone.delegate')));
    for (final p in perms) {
      final scope = p['scope'] as Map;
      if (scope.containsKey('name')) expect(scope['name'], 'zone-a');
    }

    final saved = (await DpIdentityStore(store).loadZoneCa('zone-a'))!;
    expect(saved['ski'], zone.ski);
    expect(saved['deviceId'], 'dev-zone-a');
    expect(saved['chainPem'], contains((saved['certPem'] as String).trim()));
    expect(saved['chainPem'], contains((root['caCertPem'] as String).trim()));
    expect((saved['privateJwk'] as Map)['d'], isNotEmpty);

    // Idempotent: a second call reuses the stored zone, no new request.
    final again = await m.issueZoneAuthority(session: session, zone: 'zone-a');
    expect(again.ski, zone.ski);
    expect(requests.where((r) => r.url.path.endsWith('issue-delegate')),
        hasLength(1));
  }, skip: skip);

  test('stores nothing when billing refuses the zone', () async {
    respond = (r) => http.Response(
          jsonEncode({'error': 'Only the organization owner may issue delegates',
              'code': 'OWNER_REQUIRED'}),
          403,
        );
    await expectLater(
      manager().issueZoneAuthority(session: session, zone: 'zone-a'),
      throwsA(isA<StateError>().having(
          (e) => e.message, 'message', contains('OWNER_REQUIRED'))),
    );
    expect(await DpIdentityStore(store).loadZoneCas(), isEmpty);
  }, skip: skip);

  test('refuses a personal-package root before calling billing', () async {
    final s = DpIdentityStore(store);
    await s.saveAdminCa(
      issuerSki: 'root',
      privateJwk: Map<String, dynamic>.from(
          (await s.loadAdminCa())!['privateJwk'] as Map),
      entityId: entity,
      caCertPem: (await s.loadAdminCa())!['caCertPem'] as String,
      package: 'personal',
    );
    requests.clear();
    await expectLater(
      manager().issueZoneAuthority(session: session, zone: 'zone-a'),
      throwsA(isA<IdrTargetException>().having(
          (e) => e.code, 'code', IdrTargetErrorCode.configInvalid)),
    );
    expect(requests, isEmpty);
  }, skip: skip);

  test('approve(zone:) signs with the zone CA and sends the zone chain', () async {
    final m = manager();
    final zone = await m.issueZoneAuthority(session: session, zone: 'zone-a');
    final saved = (await DpIdentityStore(store).loadZoneCa('zone-a'))!;
    final member = crypto.generateEd25519();
    final csr = crypto.buildCsr(
        privatePem: member.privatePem, fqhn: 'laptop--$entity');
    respond = (r) => r.url.path.endsWith('enroll-list')
        ? http.Response(
            jsonEncode({
              'enrollments': [
                {
                  'enrollId': 'enroll-1',
                  'host': 'laptop--$entity',
                  'csrPem': csr,
                  'ski': member.ski,
                  'publicJwk': member.publicJwk,
                  'entityId': entity,
                },
              ],
            }),
            200)
        : http.Response('{}', 200);

    await m.approve(
      session: session,
      enrollId: 'enroll-1',
      entityId: entity,
      zone: 'zone-a',
    );

    final sent = body('enroll-approve');
    expect(sent['issuerSki'], zone.ski);
    expect((sent['issuerPrivateJwk'] as Map)['x'],
        (saved['privateJwk'] as Map)['x']);
    expect((sent['credential'] as Map)['zone'], 'zone-a');
    final chain = sent['chainPem'] as String;
    expect(chain, startsWith((sent['leafPem'] as String).trim()));
    expect(chain, contains((saved['chainPem'] as String).trim()));
  }, skip: skip);

  test('approve(zone:) without that zone CA here fails clearly', () async {
    await expectLater(
      manager().approve(
          session: session, enrollId: 'x', entityId: entity, zone: 'zone-z'),
      throwsA(isA<IdrTargetException>().having(
          (e) => e.message, 'message', contains('zone-z'))),
    );
  }, skip: skip);

  test('setZonePolicy re-signs the billing copy, changing only acl.service',
      () async {
    final m = manager();
    await m.issueZoneAuthority(session: session, zone: 'zone-a');
    final issued =
        body('issue-delegate')['credential'] as Map<String, dynamic>;
    respond = (r) => r.url.path.endsWith('/delegates')
        ? http.Response(
            jsonEncode({
              'zones': [
                {'zone': 'zone-a', 'ski': issued['ski'], 'credential': issued},
              ],
            }),
            200)
        : http.Response(
            jsonEncode({'allowedServices': ['ollama'], 'policyVersion': 2}),
            200);

    final result = await m.setZonePolicy(
        session: session, zone: 'zone-a', services: ['Ollama']);

    expect(result.allowedServices, ['ollama']);
    expect(result.policyVersion, 2);
    final sent = body('zone-policy')['credential'] as Map<String, dynamic>;
    for (final f in ['version', 'kind', 'entityId', 'ski', 'zone', 'host',
        'issuerSki', 'package']) {
      expect(sent[f], issued[f], reason: f);
    }
    expect(sent['publicJwk'], issued['publicJwk']);
    expect(sent['signature'], isNot(issued['signature']));
    expect((sent['signature'] as String).split('.'), hasLength(3));
    final perms = (sent['permissions'] as List).cast<Map>();
    final acl = perms.where((p) => p['action'] == 'acl.service').single;
    expect((acl['scope'] as Map)['service'], ['ollama']);
    expect(
      perms.where((p) => p['action'] != 'acl.service').toList(),
      (issued['permissions'] as List)
          .cast<Map>()
          .where((p) => p['action'] != 'acl.service')
          .toList(),
    );
  }, skip: skip);

  test('setZonePolicy needs the zone on billing', () async {
    respond = (r) => http.Response(jsonEncode({'zones': []}), 200);
    await expectLater(
      manager().setZonePolicy(session: session, zone: 'zone-a', services: ['*']),
      throwsA(isA<IdrTargetException>()
          .having((e) => e.code, 'code', IdrTargetErrorCode.configMissing)),
    );
  }, skip: skip);

  test('normalizeServices: lowercase, unique, sorted; * means all', () {
    expect(EnrollmentManager.normalizeServices(['LMStudio', 'ollama,ollama']),
        ['lmstudio', 'ollama']);
    expect(EnrollmentManager.normalizeServices(['ollama', '*']), ['*']);
    expect(() => EnrollmentManager.normalizeServices([]), throwsArgumentError);
    expect(() => EnrollmentManager.normalizeServices(['bad name']),
        throwsArgumentError);
  });

  test('zone admin key: requested here, signed by the root, then signs '
      'its zone', () async {
    // The zone admin's machine has no root CA, only its own store.
    final adminStore = SessionStore(storage: MemoryStorage());
    final admin = EnrollmentManager(
      enroll: EnrollClient(
        controlPlaneUrl: 'http://cp.test',
        httpClient: MockClient((r) async {
          requests.add(r);
          return respond(r);
        }),
      ),
      registration: RegistrationClient(
          controlPlaneUrl: 'http://cp.test', store: adminStore),
      identity: DpIdentityStore(adminStore),
      requireCrypto: () => crypto,
    );
    respond = (r) => http.Response(
        jsonEncode({'enrollId': 'zk-1', 'pullToken': 'pt', 'kind': 'zone_authority'}),
        201);
    expect(
        await admin.requestZoneKey(
            session: session, entityId: entity, zone: 'Fin'),
        'pending');
    final asked = body('enroll-create');
    expect(asked['kind'], 'zone_authority');
    expect(asked['zone'], 'fin');
    expect(await admin.zoneKeyRequests(), ['fin']);

    // Root: the inbox lists the request; approving signs a zone CA for it.
    respond = (r) {
      if (r.url.path.endsWith('enroll-list')) {
        return http.Response(
            jsonEncode({
              'enrollments': [
                {
                  'enrollId': 'zk-1',
                  'kind': 'zone_authority',
                  'zone': 'fin',
                  'ski': asked['subjectSki'],
                  'publicJwk': asked['publicJwk'],
                  'csrPem': asked['csrPem'],
                  'requestedBy': 'za@acme.test',
                  'status': 'pending',
                },
              ],
            }),
            200);
      }
      if (r.url.path.endsWith('/delegates')) {
        return http.Response(jsonEncode({'zones': []}), 200);
      }
      return http.Response(jsonEncode({'status': 'approved'}), 200);
    };
    await manager()
        .approve(session: session, enrollId: 'zk-1', entityId: entity);
    final signed = body('enroll-approve');
    final root = (await DpIdentityStore(store).loadAdminCa())!;
    final cred = signed['credential'] as Map<String, dynamic>;
    expect(signed['issuerSki'], root['issuerSki']);
    expect(signed['leafPem'], contains('BEGIN CERTIFICATE'));
    expect(signed['chainPem'], contains((root['caCertPem'] as String).trim()));
    expect(signed, isNot(contains('issuerPrivateJwk')));
    expect(cred['kind'], 'zone_authority');
    expect(cred['zone'], 'fin');
    expect(cred['ski'], asked['subjectSki']);

    // Zone admin picks the signed key up and can sign in its zone.
    respond = (r) => http.Response(
        jsonEncode({
          'status': 'approved',
          'ski': asked['subjectSki'],
          'certPem': signed['leafPem'],
          'chainPem': signed['chainPem'],
        }),
        200);
    expect(await admin.pullZoneKey('fin'), 'approved');
    expect(await admin.zoneKeyRequests(), isEmpty);
    final key = (await DpIdentityStore(adminStore).loadZoneCa('fin'))!;
    expect(key['certPem'], signed['leafPem']);
    expect((key['privateJwk'] as Map)['d'], isNotEmpty);
    expect(
        await admin.requestZoneKey(
            session: session, entityId: entity, zone: 'fin'),
        'approved');
  }, skip: skip);
}
