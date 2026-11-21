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
  @override
  Future<BillingAuthSession?> getSession() async {
    refreshes++;
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
}
