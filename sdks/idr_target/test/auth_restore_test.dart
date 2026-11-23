import 'package:idr_session/idr_session.dart';
import 'package:idr_target/src/auth/auth_manager.dart';
import 'package:idr_target/src/auth/session_store.dart';
import 'package:test/test.dart';
import 'package:two_key_dart_sdk/two_key_headless.dart';

import 'support/memory_storage.dart';

class _AuthClient extends BillingAuthClient {
  _AuthClient(MemoryStorage storage)
      : super(
            billingBaseUrl: 'http://auth.test',
            deepLinkScheme: 'idr',
            storagePrefix: 'test',
            storage: storage);
  int refreshes = 0;
  bool unreachable = false;
  @override
  Future<BillingAuthSession?> getSession() async {
    refreshes++;
    if (unreachable) {
      throw const BillingAuthException('ClientException with SocketException: The remote computer refused the network connection');
    }
    return null;
  }
}

void main() {
  for (final entry in <String, Duration?>{
    'valid': const Duration(minutes: 10),
    'near expiry': const Duration(seconds: 30),
    'expired': const Duration(minutes: -1),
    'unknown expiry': null,
  }.entries) {
    test('restore ${entry.key} token', () async {
      final storage = MemoryStorage();
      final store = SessionStore(storage: storage);
      final client = _AuthClient(storage);
      addTearDown(client.dispose);
      final expiry = entry.value;
      await store.saveSession(IdrAuthSession(
        token: 'saved-token',
        email: 'test@example.com',
        accessExpiresAt: expiry == null ? null : DateTime.now().add(expiry),
      ));
      final manager = AuthManager(
          client: client,
          store: store,
          launcher: LoopbackAuthSessionLauncher());
      final restored = await manager.restore();
      expect(restored?.token, 'saved-token');
      expect(client.refreshes, entry.key == 'valid' ? 0 : 1);
    });
  }

  test('a failed refresh is not retried within the backoff (each retry cost ~2 s offline)', () async {
    final storage = MemoryStorage();
    final store = SessionStore(storage: storage);
    final client = _AuthClient(storage)..unreachable = true;
    addTearDown(client.dispose);
    await store.saveSession(IdrAuthSession(
      token: 'saved-token',
      email: 'test@example.com',
      accessExpiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
    ));
    final manager = AuthManager(client: client, store: store, launcher: LoopbackAuthSessionLauncher());
    expect((await manager.restore())?.token, 'saved-token');
    expect(manager.lastRefreshError, isA<BillingAuthException>());
    expect(manager.refreshRecentlyFailed, isTrue);
    expect((await manager.restore())?.token, 'saved-token');
    expect(client.refreshes, 1, reason: 'the second restore must not call Billing again');
  });
}
