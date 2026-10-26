import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idr_target/idr_target.dart';
import 'package:idr_target/src/auth/auth_manager.dart';

import 'support/memory_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AuthManager manager(http.Client httpClient) {
    final store = SessionStore(storage: MemoryStorage(), prefix: 't');
    return AuthManager(
      client: BillingAuthClient(
        billingBaseUrl: 'http://127.0.0.1:3000',
        deepLinkScheme: 'idr',
        storagePrefix: 't',
        storage: store.storage,
        httpClient: httpClient,
      ),
      store: store,
      launcher: LoopbackAuthSessionLauncher(),
    );
  }

  group('AuthManager.fetchLoginOptions', () {
    test('parses oauth-providers discovery', () async {
      final auth = manager(MockClient((request) async {
        expect(request.url.path, '/api/auth/.well-known/oauth-providers');
        return http.Response(
          jsonEncode({
            'issuer': 'http://127.0.0.1:3000/api/auth',
            'providers': [
              {'id': 'google', 'enabled': true},
              {'id': 'microsoft', 'enabled': false},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }));

      final options = await auth.fetchLoginOptions(apiBase: 'x');
      expect(options.providers, [IdrAuthProvider.google]);
      expect(options.emailPassword, isFalse);
    });

    test('throws CONFIG_INVALID when no providers enabled', () async {
      final auth = manager(MockClient((_) async => http.Response(
            jsonEncode({'providers': <Object>[]}),
            200,
            headers: {'content-type': 'application/json'},
          )));

      expect(
        () => auth.fetchLoginOptions(apiBase: 'x'),
        throwsA(isA<IdrTargetException>().having(
          (e) => e.code,
          'code',
          IdrTargetErrorCode.configInvalid,
        )),
      );
    });

    test('maps non-200 to a target exception', () async {
      final auth = manager(MockClient((_) async => http.Response('nope', 503)));

      expect(
        () => auth.fetchLoginOptions(apiBase: 'x'),
        throwsA(isA<IdrTargetException>()),
      );
    });
  });
}
