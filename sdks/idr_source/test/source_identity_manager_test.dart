import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idr_dp_ffi/idr_dp_ffi.dart';
import 'package:idr_source/idr_source.dart';
import 'package:test/test.dart';

class _MemStorage implements BillingAuthStorage {
  final m = <String, String>{};
  @override
  Future<String?> getItem(String key) async => m[key];
  @override
  Future<void> setItem(String key, String value) async => m[key] = value;
  @override
  Future<void> removeItem(String key) async => m.remove(key);
}

// RFC 8410 Ed25519 test key (seed D4EE...); public x is arbitrary here.
const _pem = '-----BEGIN PRIVATE KEY-----\n'
    'MC4CAQAwBQYDK2VwBCIEINTuctv5E1hK1bbY8fdp+K06/nwoy/HU++CXqI9EdVhC\n'
    '-----END PRIVATE KEY-----';

class _FakeCrypto implements IdrCrypto {
  @override
  Ed25519KeyMaterial generateEd25519() => const Ed25519KeyMaterial(
        privatePem: _pem,
        publicPem: '',
        publicB64url: 'pub',
        publicJwk: {'kty': 'OKP', 'crv': 'Ed25519', 'x': 'eHh4'},
        ski: 'SKI1',
      );
  @override
  String ski(String publicB64url) => 'SKI1';
  @override
  String buildCsr({required String privatePem, required String fqhn}) =>
      'CSR($fqhn)';
  @override
  String sign({required String privatePem, required List<int> message}) =>
      throw UnimplementedError();
  @override
  String signJson({required String privatePem, required String json}) =>
      throw UnimplementedError();
  @override
  String caCertPemFromPrivateJwk({
    required Map<String, dynamic> privateJwk,
    required String commonName,
  }) =>
      throw UnimplementedError();
  @override
  SignedLeaf signCsr({
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
}

void main() {
  test('entityIdFromFqhn', () {
    expect(SourceIdentityManager.entityIdFromFqhn('pc--me@x.com.idr.to'),
        'me@x.com');
    expect(SourceIdentityManager.entityIdFromFqhn('PC--Acme'), 'acme');
    expect(() => SourceIdentityManager.entityIdFromFqhn('example.com'),
        throwsA(isA<IdrSourceException>()));
  });

  test('enroll: create → pending → approved → DeviceIdentityJson', () async {
    var pulls = 0;
    final calls = <String>[];
    final client = MockClient((req) async {
      calls.add(req.url.path);
      if (req.url.path.endsWith('/enroll-create')) {
        final body = jsonDecode(req.body) as Map;
        expect(body['kind'], 'machine_source');
        expect(body['host'], 'laptop--me@x.com');
        expect(req.headers['cookie'], 'better-auth.session_token=abc');
        return http.Response(
            jsonEncode({'enrollId': 'e1', 'pullToken': 'pt'}), 200);
      }
      if (req.url.path.endsWith('/enroll-pull')) {
        pulls++;
        if (pulls == 1)
          return http.Response(jsonEncode({'status': 'pending'}), 200);
        return http.Response(
          jsonEncode({
            'status': 'approved',
            'ski': 'SKI1',
            'certPem': 'LEAF',
            'chainPem': 'CHAIN',
            'credential': {
              'issuerSki': 'CA',
              'signature': 'sig',
              'certPem': 'x'
            },
          }),
          200,
        );
      }
      return http.Response('nope', 404);
    });
    final storage = _MemStorage();
    final mgr = SourceIdentityManager(
      storage: storage,
      enroll: DelegatePermissionsClient(
        billingBaseUrl: 'http://billing.test',
        sessionCookie: () async => 'better-auth.session_token=abc',
        httpClient: client,
      ),
      crypto: _FakeCrypto.new,
    );

    expect(await mgr.approvedIdentityJson(), isNull);
    final host = await mgr.enroll(
      targetFqhn: 'pc--me@x.com.idr.to',
      sourceLabel: 'Laptop',
    );
    expect(host, 'laptop--me@x.com');
    expect(pulls, 2);

    final json = jsonDecode((await mgr.approvedIdentityJson())!) as Map;
    expect(json['ski'], 'SKI1');
    expect(json['private_jwk']['d'], isNotEmpty);
    expect(json['credential'], {'issuerSki': 'CA', 'signature': 'sig'});
    expect(json['cert_pem'], 'LEAF');
    // The native engine signs the session's source_proof with this chain.
    expect(json['chain_pem'], 'CHAIN');
    expect(json.containsKey('pull_token'), isFalse);

    // Idempotent: second call does not re-create.
    calls.clear();
    expect(await mgr.enroll(targetFqhn: 'pc--me@x.com', sourceLabel: 'laptop'),
        host);
    expect(calls, isEmpty);
  });
}
