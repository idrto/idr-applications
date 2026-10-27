import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idr_target/idr_target.dart';
import 'package:idr_target/src/registration/registration_client.dart';
import 'package:test/test.dart';

import 'support/memory_storage.dart';

const _session = IdrAuthSession(token: 't', email: 'za@acme.test');

RegistrationClient _client(String Function(Map body) fqhnFor) =>
    RegistrationClient(
      controlPlaneUrl: 'http://127.0.0.1:1',
      store: SessionStore(storage: MemoryStorage()),
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        return http.Response(
          jsonEncode({
            'success': true,
            'data': {
              'entityId': body['entityId'],
              'hostLabel': body['hostLabel'],
              'verifiedFqhn': fqhnFor(body),
            },
          }),
          201,
        );
      }),
    );

void main() {
  test('a zoned host sends its zone and keeps the zoned name', () async {
    Map? sent;
    final reg = await _client((b) {
      sent = b;
      return '${b['hostLabel']}.${b['zone']}--${b['entityId']}.idr.to';
    }).registerHost(
      session: _session,
      entityId: 'owner@acme.test',
      hostLabel: 'laptop',
      machineSki: 'ski',
      zone: 'finzone',
    );
    expect(sent!['zone'], 'finzone');
    expect(reg.verifiedFqhn, 'laptop.finzone--owner@acme.test.idr.to');
  });

  test('a billing that drops the zone is refused, not served', () async {
    expect(
      () => _client(
        (b) => '${b['hostLabel']}--${b['entityId']}.idr.to',
      ).registerHost(
        session: _session,
        entityId: 'owner@acme.test',
        hostLabel: 'laptop',
        machineSki: 'ski',
        zone: 'finzone',
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('personal and root hosts send no zone', () async {
    Map? sent;
    final reg = await _client((b) {
      sent = b;
      return '${b['hostLabel']}--${b['entityId']}.idr.to';
    }).registerHost(
      session: _session,
      entityId: 'za@acme.test',
      hostLabel: 'laptop',
      machineSki: 'ski',
    );
    expect(sent!.containsKey('zone'), isFalse);
    expect(reg.verifiedFqhn, 'laptop--za@acme.test.idr.to');
  });
}
