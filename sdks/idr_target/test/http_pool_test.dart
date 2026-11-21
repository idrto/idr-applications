import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idr_target/idr_target.dart';
import 'package:test/test.dart';

import 'support/memory_storage.dart';

void main() {
  test('subscription and enrollment calls reuse a control-plane connection',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final dir = await Directory.systemTemp.createTemp('idr-http-pool-');
    final ports = <int>[];
    server.listen((request) async {
      ports.add(request.connectionInfo!.remotePort);
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(
          request.uri.path.endsWith('/subscriptions')
              ? {'success': true, 'data': <Object>[]}
              : {'exists': true}));
      await request.response.close();
    });
    final store = SessionStore(storage: MemoryStorage());
    await store.saveSession(IdrAuthSession(
      token: 'test-token',
      email: 'test@example.com',
      accessExpiresAt: DateTime.now().add(const Duration(hours: 1)),
    ));
    final target = IdrTarget(
      config: IdrTargetConfig(
        controlPlaneUrl: Uri.parse('http://127.0.0.1:${server.port}'),
        agentBinaryPath: 'unused',
        configDirectory: dir.path,
      ),
      store: store,
      // An unavailable auth refresh keeps the saved session. API calls still
      // use real local sockets so this detects redundant connection pools.
      authClient: BillingAuthClient(
        billingBaseUrl: 'http://auth.test',
        deepLinkScheme: 'idr',
        storagePrefix: store.prefix,
        storage: store.storage,
        httpClient: MockClient((_) async => http.Response('unavailable', 503)),
      ),
    );
    addTearDown(() async {
      await target.dispose();
      await server.close(force: true);
      await dir.delete(recursive: true);
    });
    await target.start(launchAgent: false);
    expect(await target.entityRootExists('test@example.com'), isTrue);
    expect(ports, hasLength(2));
    expect(ports.toSet(), hasLength(1),
        reason: 'API calls should share one TCP connection');
  });
}
