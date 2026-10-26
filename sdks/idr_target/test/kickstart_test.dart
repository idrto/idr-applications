import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idr_target/src/auth/auth.dart';
import 'package:idr_target/src/crypto/idr_crypto.dart';
import 'package:idr_target/src/dp/identity_store.dart';
import 'package:idr_target/src/errors.dart';
import 'package:idr_target/src/registration/enroll_client.dart';
import 'package:idr_target/src/registration/enrollment_manager.dart';
import 'package:idr_target/src/registration/registration_client.dart';
import 'package:test/test.dart';

import 'support/memory_storage.dart';

String _fakePkcs8Pem() {
  final der = Uint8List.fromList([
    0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70,
    0x04, 0x22, 0x04, 0x20,
    ...List<int>.filled(32, 1),
  ]);
  final b64 = base64Encode(der);
  return '-----BEGIN PRIVATE KEY-----\n$b64\n-----END PRIVATE KEY-----\n';
}

class _KickstartCrypto implements IdrCrypto {
  @override
  Ed25519KeyMaterial generateEd25519() => Ed25519KeyMaterial(
        privatePem: _fakePkcs8Pem(),
        publicPem: '',
        publicB64url: 'A' * 43,
        publicJwk: {
          'kty': 'OKP',
          'crv': 'Ed25519',
          'x': 'A' * 43,
        },
      );

  @override
  String buildCsr({required String privatePem, required String fqhn}) =>
      throw UnimplementedError();

  @override
  String sign({required String privatePem, required List<int> message}) =>
      'c2ln';

  @override
  String signJson({required String privatePem, required String json}) =>
      throw UnimplementedError();

  @override
  String ski(String publicB64url) => 'ca-ski';

  @override
  ({String leafPem, String chainPem}) signCsr({
    required String csrPem,
    required Map<String, dynamic> caPrivateJwk,
    required String issuerSki,
    String? host,
    String? issuerChainPem,
  }) =>
      throw UnimplementedError();

  @override
  String signIntermediateCa({
    required Map<String, dynamic> childPublicJwk,
    required String childCommonName,
    required Map<String, dynamic> parentPrivateJwk,
    required String parentCommonName,
  }) =>
      throw UnimplementedError();

  @override
  String caCertPemFromPrivateJwk({
    required Map<String, dynamic> privateJwk,
    required String commonName,
  }) =>
      '-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n';
}

void main() {
  test('kickstart sends client caCertPem and JWKs', () async {
    Map<String, dynamic>? body;
    final httpClient = MockClient((request) async {
      body = jsonDecode(request.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({'entityId': 'user@example.com'}),
        200,
      );
    });
    final store = SessionStore(storage: MemoryStorage());
    final crypto = _KickstartCrypto();
    final enrollment = EnrollmentManager(
      enroll: EnrollClient(
        controlPlaneUrl: 'http://127.0.0.1:1',
        httpClient: httpClient,
      ),
      registration: RegistrationClient(
        controlPlaneUrl: 'http://127.0.0.1:1',
        store: store,
      ),
      identity: DpIdentityStore(store),
      requireCrypto: () => crypto,
    );

    await enrollment.kickstartEntity(
      session: const IdrAuthSession(
        token: 'session-token',
        email: 'user@example.com',
      ),
      entityId: 'user@example.com',
    );

    expect(body, isNotNull);
    expect(body!['caCertPem'], contains('BEGIN CERTIFICATE'));
    expect(body!['rootPublicJwk'], isA<Map>());
    expect(body!['adminPublicJwk'], isA<Map>());
    expect(body!['rootCredential'], isA<Map>());
    expect(body!['adminCredential'], isA<Map>());
    expect((body!['rootCredential'] as Map)['signature'], isNotEmpty);

    final saved = await DpIdentityStore(store).loadAdminCa();
    expect(saved?['caCertPem'], contains('BEGIN CERTIFICATE'));
    expect(saved?['issuerSki'], 'ca-ski');
    expect(saved?['package'], 'personal');
  });

  test('enterprise root is registered and recorded as enterprise; '
      'a local CA of another package is refused', () async {
    final bodies = <Map<String, dynamic>>[];
    final store = SessionStore(storage: MemoryStorage());
    final crypto = _KickstartCrypto();
    final enrollment = EnrollmentManager(
      enroll: EnrollClient(
        controlPlaneUrl: 'http://127.0.0.1:1',
        httpClient: MockClient((request) async {
          bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(jsonEncode({'entityId': 'a@acme.com'}), 200);
        }),
      ),
      registration: RegistrationClient(
        controlPlaneUrl: 'http://127.0.0.1:1',
        store: store,
      ),
      identity: DpIdentityStore(store),
      requireCrypto: () => crypto,
    );
    const session = IdrAuthSession(token: 't', email: 'a@acme.com');

    await enrollment.ensureAdminCa(
      session: session,
      entityId: 'a@acme.com',
      package: 'enterprise',
    );
    expect(bodies.single['package'], 'enterprise');
    expect((bodies.single['rootCredential'] as Map)['package'], 'enterprise');
    expect((await DpIdentityStore(store).loadAdminCa())?['package'],
        'enterprise');

    // Same package again: no-op, no second kickstart.
    await enrollment.ensureAdminCa(
      session: session,
      entityId: 'a@acme.com',
      package: 'enterprise',
    );
    expect(bodies, hasLength(1));

    await expectLater(
      enrollment.ensureAdminCa(session: session, entityId: 'a@acme.com'),
      throwsA(isA<IdrTargetException>().having(
        (e) => e.code,
        'code',
        IdrTargetErrorCode.configInvalid,
      )),
    );
  });
}
