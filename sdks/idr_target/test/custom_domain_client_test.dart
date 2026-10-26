import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idr_target/src/auth/auth.dart';
import 'package:idr_target/src/registration/custom_domain_client.dart';
import 'package:test/test.dart';

Map<String, dynamic> _row(String domain, String status) => {
      'id': 'id-$domain',
      'domain': domain,
      'targetFqhn': 'box--a@acme.test.idr.to',
      'cnameTarget': 'box--a-40acme-2etest.idr.to',
      'status': status,
    };

void main() {
  const session = IdrAuthSession(token: 't', email: 'a@acme.test');

  test('verifiedDomains asks for this Target and keeps verified rows',
      () async {
    late http.Request sent;
    final client = CustomDomainClient(
      controlPlaneUrl: 'http://cp.test/',
      httpClient: MockClient((r) async {
        sent = r;
        return http.Response(
          jsonEncode({
            'success': true,
            'data': [
              _row('app.customer.com', 'verified'),
              _row('new.customer.com', 'pending'),
              _row('old.customer.com', 'failed'),
            ],
          }),
          200,
        );
      }),
    );
    final domains = await client.verifiedDomains(
      session: session,
      targetFqhn: 'box--a@acme.test.idr.to',
    );
    expect(domains, ['app.customer.com']);
    expect(sent.url.path, '/api/v1/custom-domains');
    expect(sent.url.queryParameters['targetFqhn'], 'box--a@acme.test.idr.to');
    expect(sent.headers['authorization'], 'Bearer t');
  });

  test('add / verify / remove call billing and parse the record', () async {
    final calls = <String>[];
    final record = {
      'id': 'id-1',
      'domain': 'app.customer.com',
      'targetFqhn': 'box--a@acme.test.idr.to',
      'cnameTarget': 'box--a-40acme-2etest.idr.to',
      'status': 'pending',
      'lastCheckAt': '2026-10-24T09:00:00.000Z',
      'verifiedAt': null,
      'lastError': {
        'code': 'cname_mismatch',
        'message':
            'app.customer.com points to x.example.org, expected the Target',
        'seen': 'x.example.org',
      },
    };
    final client = CustomDomainClient(
      controlPlaneUrl: 'http://cp.test',
      httpClient: MockClient((r) async {
        calls.add(
            '${r.method} ${r.url.path}${r.body.isEmpty ? '' : ' ${r.body}'}');
        return http.Response(
          jsonEncode({'success': true, 'data': record}),
          r.method == 'POST' && r.url.path.endsWith('domains') ? 201 : 200,
        );
      }),
    );
    final added = await client.add(
      session: session,
      targetFqhn: 'box--a@acme.test.idr.to',
      domain: 'app.customer.com',
    );
    expect(added.cnameTarget, 'box--a-40acme-2etest.idr.to');
    expect(added.lastError?.seen, 'x.example.org');
    expect(added.verified, isFalse);
    await client.verify(session: session, id: 'id-1');
    await client.remove(session: session, id: 'id-1');
    expect(calls, [
      'POST /api/v1/custom-domains {"targetFqhn":"box--a@acme.test.idr.to","domain":"app.customer.com"}',
      'POST /api/v1/custom-domains/id-1/verify',
      'DELETE /api/v1/custom-domains/id-1',
    ]);
  });

  test('billing refusals keep their code and message', () async {
    final client = CustomDomainClient(
      controlPlaneUrl: 'http://cp.test',
      httpClient: MockClient((_) async => http.Response(
            jsonEncode({
              'success': false,
              'error': 'www.x.com is already on this Target',
              'code': 'DOMAIN_EXISTS',
            }),
            409,
          )),
    );
    await expectLater(
      client.add(session: session, targetFqhn: 't--a@b.c', domain: 'www.x.com'),
      throwsA(isA<CustomDomainException>()
          .having((e) => e.code, 'code', 'DOMAIN_EXISTS')
          .having((e) => e.isClientError, 'isClientError', isTrue)
          .having((e) => e.message, 'message',
              'www.x.com is already on this Target')),
    );
  });

  test('AcmeDomainStatus reads the agent status file', () {
    final s = AcmeDomainStatus.fromJson(jsonDecode('''{
      "domain": "app.customer.com", "state": "failed", "staging": true,
      "lastAttemptAt": "2026-10-23T19:52:25.720299200Z",
      "lastError": "create ACME order: rejectedIdentifier",
      "notAfter": null, "renewAt": null }''') as Map<String, dynamic>);
    expect(s.state, 'failed');
    expect(s.staging, isTrue);
    expect(s.lastError, contains('rejectedIdentifier'));
    expect(s.notAfter, isNull);
  });

  test('verifiedDomains throws on a billing error (caller logs and goes on)',
      () async {
    final client = CustomDomainClient(
      controlPlaneUrl: 'http://cp.test',
      httpClient: MockClient((_) async => http.Response('{}', 403)),
    );
    expect(
      client.verifiedDomains(session: session, targetFqhn: 'box--a@b.c'),
      throwsA(predicate((e) => '$e'.contains('403'))),
    );
  });
}
