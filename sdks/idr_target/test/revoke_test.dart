import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idr_target/src/auth/auth.dart';
import 'package:idr_target/src/dp/identity_store.dart';
import 'package:idr_target/src/registration/enroll_client.dart';
import 'package:test/test.dart';

import 'support/memory_storage.dart';

void main() {
  const session = IdrAuthSession(token: 't', email: 'root@acme.test');

  test('revokeCredential posts the SKI with the Bearer and returns data',
      () async {
    late http.Request sent;
    final client = EnrollClient(
      controlPlaneUrl: 'http://cp.test/',
      httpClient: MockClient((r) async {
        sent = r;
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {'ski': 'zone-b-ski', 'status': 'revoked', 'reason': 'e2e'},
          }),
          200,
        );
      }),
    );
    final r = await client.revokeCredential(
      session: session,
      ski: 'zone-b-ski',
      reason: 'e2e',
    );
    expect(sent.url.path, '/api/v1/machine-authn/credential-revoke');
    expect(sent.headers['authorization'], 'Bearer t');
    expect(jsonDecode(sent.body), {'ski': 'zone-b-ski', 'reason': 'e2e'});
    expect(r['status'], 'revoked');
  });

  test('revokeCredential surfaces the billing error', () async {
    final client = EnrollClient(
      controlPlaneUrl: 'http://cp.test',
      httpClient: MockClient((_) async => http.Response(
            jsonEncode({'error': 'Not an owner', 'code': 'FORBIDDEN'}),
            403,
          )),
    );
    expect(
      client.revokeCredential(session: session, ski: 'x'),
      throwsA(predicate(
          (e) => '$e'.contains('403') && '$e'.contains('Not an owner [FORBIDDEN]'))),
    );
  });

  test('deleteZoneCa drops only that zone', () async {
    final ids = DpIdentityStore(SessionStore(storage: MemoryStorage()));
    await ids.saveZoneCa('zone-a', {'ski': 'a'});
    await ids.saveZoneCa('zone-b', {'ski': 'b'});
    await ids.deleteZoneCa('zone-b');
    await ids.deleteZoneCa('missing');
    expect((await ids.loadZoneCas()).keys, ['zone-a']);
  });
}
