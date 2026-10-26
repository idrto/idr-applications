import 'dart:convert';

import 'package:idr_source/idr_source.dart';
import 'package:idr_source/src/auth/auth_manager.dart';
import 'package:test/test.dart';
import 'package:two_key_dart_sdk/two_key_headless.dart';

class _MemStorage implements BillingAuthStorage {
  final map = <String, String>{};
  @override
  Future<String?> getItem(String key) async => map[key];
  @override
  Future<void> setItem(String key, String value) async => map[key] = value;
  @override
  Future<void> removeItem(String key) async => map.remove(key);
}

/// Only what bind + mint touch; anything else is a test bug.
class _FakeAuthClient implements BillingAuthClient {
  _FakeAuthClient({this.bindError, this.live = true});

  final BillingAuthException? bindError;
  final bool live;
  final calls = <String>[];
  String boundSlug = 'me';

  @override
  Future<({String organizationId, String slug, String name, String role})>
      bindOrganization({String slug = 'me'}) async {
    calls.add('bind:$slug');
    if (bindError != null) throw bindError!;
    boundSlug = slug;
    return (
      organizationId: 'org-1',
      slug: slug,
      name: 'Test New',
      role: 'member'
    );
  }

  @override
  Future<BillingAuthSession?> getSession() async => live
      ? const BillingAuthSession(
          user: BillingAuthSessionUser(id: 'u1', email: 'm@acme.test'),
        )
      : null;

  @override
  Future<BillingAuthTokens> acquireApiToken() async {
    calls.add('mint');
    return BillingAuthTokens(accessToken: 'jwt-for-$boundSlug');
  }

  @override
  Future<String> getSessionCookie() async => 'ba_session=abc';

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('unexpected ${i.memberName}');
}

void main() {
  AuthManager manager(_FakeAuthClient client, _MemStorage storage) =>
      AuthManager(
        client: client,
        storage: storage,
        launcher: LoopbackAuthSessionLauncher(),
      );

  test('binds the org, then re-mints and stores an org-scoped token', () async {
    final client = _FakeAuthClient();
    final storage = _MemStorage();
    final bound =
        await manager(client, storage).bindOrganization('test-slug-new');

    expect(client.calls, ['bind:test-slug-new', 'mint']);
    expect(bound.slug, 'test-slug-new');
    expect(bound.role, 'member');
    expect(bound.session.token, 'jwt-for-test-slug-new');
    final saved = jsonDecode(storage.map['idr.source.session']!) as Map;
    expect(saved['token'], 'jwt-for-test-slug-new');
  });

  test('maps "not a member" and unknown orgs to stable codes', () async {
    Future<String> codeFor(BillingAuthException e) async {
      try {
        await manager(_FakeAuthClient(bindError: e), _MemStorage())
            .bindOrganization('x');
        return 'none';
      } on IdrSourceException catch (s) {
        return s.code;
      }
    }

    expect(
      await codeFor(const BillingAuthException(
        'You are not a member of this organization.',
        statusCode: 403,
        code: 'NOT_A_MEMBER',
      )),
      'NOT_A_MEMBER',
    );
    expect(
      await codeFor(const BillingAuthException('Organization not found',
          statusCode: 404)),
      'ORG_NOT_FOUND',
    );
    expect(
      await codeFor(const BillingAuthException('boom', statusCode: 500)),
      'BIND_FAILED',
    );
  });

  test(
      'an expired sign-in asks to log in again instead of sending a stale token',
      () async {
    final storage = _MemStorage();
    await expectLater(
      manager(_FakeAuthClient(live: false), storage).bindOrganization('x'),
      throwsA(isA<IdrSourceException>()
          .having((e) => e.code, 'code', 'AUTH_REQUIRED')),
    );
    expect(storage.map, isEmpty);
  });
}
