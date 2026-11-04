import 'package:idr_source/idr_source.dart';
import 'package:test/test.dart';

class _MemStorage implements BillingAuthStorage {
  final map = <String, String>{};
  @override
  Future<String?> getItem(String key) async => map[key];
  @override
  Future<void> setItem(String key, String value) async => map[key] = value;
  @override
  Future<void> removeItem(String key) async => map.remove(key);
}

/// Only what sign-out touches.
class _FakeAuthClient implements BillingAuthClient {
  var signedOut = false;

  @override
  Future<void> signOut() async => signedOut = true;

  @override
  Future<void> clearLocalAuthSession() async {}

  @override
  void setOnline(bool value) {}

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnimplementedError('unexpected ${i.memberName}');
}

void main() {
  const identityKey = 'idr.source.identity';

  ({IdrSource source, _MemStorage storage, _FakeAuthClient auth}) build() {
    final storage = _MemStorage()..map[identityKey] = '{"ski":"member"}';
    final auth = _FakeAuthClient();
    final source = IdrSource(
      config: IdrSourceConfig.forFlavor(const IdrFlavor(
        name: 'dev',
        isDev: true,
        controlPlane: 'http://127.0.0.1:3000',
        discovery: 'http://127.0.0.1:8081/.well-known/idr-presence.json',
      )),
      authStorage: storage,
      authClient: auth,
    );
    return (source: source, storage: storage, auth: auth);
  }

  test('logout signs out but keeps the enrolled device', () async {
    final t = build();
    await t.source.logout();
    expect(t.auth.signedOut, isTrue);
    expect(t.storage.map, contains(identityKey));
  });

  test('logout(forgetDevice: true) also deletes the device', () async {
    final t = build();
    await t.source.logout(forgetDevice: true);
    expect(t.auth.signedOut, isTrue);
    expect(t.storage.map, isNot(contains(identityKey)));
  });

  test('forgetDevice alone keeps the sign-in', () async {
    final t = build();
    await t.source.forgetDevice();
    expect(t.auth.signedOut, isFalse);
    expect(t.storage.map, isNot(contains(identityKey)));
  });
}
