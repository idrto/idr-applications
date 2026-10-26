import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idr_target/idr_target.dart';
import 'package:idr_target/src/entitlement/billing_commerce.dart';
import 'package:test/test.dart';

import 'support/memory_storage.dart';

const _session = IdrAuthSession(
  token: 'session-token',
  email: 'user@example.com',
);

void main() {
  group('BillingCommerceClient.fetchCovering', () {
    test('active Personal subscription is covering', () async {
      final client = BillingCommerceClient(
        apiBaseUrl: 'http://127.0.0.1:1',
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/subscriptions');
          return http.Response(
            jsonEncode({
              'success': true,
              'data': [
                {
                  'subscriptionStatus': 'active',
                  'plan': {'name': 'Personal Bundle'},
                },
              ],
            }),
            200,
          );
        }),
      );

      final covering = await client.fetchCovering(_session);
      expect(covering?.planCode, 'idr_personal_bundle');
    });

    test('no covering subscription returns null', () async {
      final client = BillingCommerceClient(
        apiBaseUrl: 'http://127.0.0.1:1',
        httpClient: MockClient((request) async {
          return http.Response(
            jsonEncode({'success': true, 'data': <Object>[]}),
            200,
          );
        }),
      );

      expect(await client.fetchCovering(_session), isNull);
    });

    test('401 is auth expired, not entitled', () async {
      final client = BillingCommerceClient(
        apiBaseUrl: 'http://127.0.0.1:1',
        httpClient: MockClient((request) async {
          return http.Response('unauthorized', 401);
        }),
      );

      expect(
        () => client.fetchCovering(_session),
        throwsA(
          isA<IdrTargetException>().having(
            (e) => e.code,
            'code',
            IdrTargetErrorCode.authExpired,
          ),
        ),
      );
    });

    test('403 (org member cannot see billing) is not covered, not expired',
        () async {
      final client = BillingCommerceClient(
        apiBaseUrl: 'http://127.0.0.1:1',
        httpClient: MockClient((request) async {
          return http.Response('forbidden', 403);
        }),
      );

      expect(await client.fetchCovering(_session), isNull);
    });
  });

  group('BillingCommerceClient.createCheckoutSession', () {
    test('resolves Personal plan and returns checkout URL', () async {
      final client = BillingCommerceClient(
        apiBaseUrl: 'http://127.0.0.1:1',
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/v1/plans') {
            return http.Response(
              jsonEncode({
                'success': true,
                'data': [
                  {
                    'id': '10',
                    'name': 'Personal Bundle',
                    'featuresJson': {'planCode': 'idr_personal_bundle'},
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path == '/api/v1/plans/10/pricings') {
            return http.Response(
              jsonEncode({
                'success': true,
                'data': [
                  {'id': '20', 'billingInterval': 'annual'},
                ],
              }),
              200,
            );
          }
          expect(request.url.path, '/api/v1/checkout/checkout-session');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['planId'], '10');
          expect(body['pricingId'], '20');
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'url': 'https://checkout.stripe.com/c/pay/cs_test',
                'sessionId': 'cs_test',
              },
            }),
            200,
          );
        }),
      );

      final created = await client.createCheckoutSession(
        session: _session,
        planCode: 'idr_personal_bundle',
      );
      expect(created.url, contains('checkout.stripe.com'));
      expect(created.sessionId, 'cs_test');
    });

    test('resolves plan from catalog addonCode', () async {
      final client = BillingCommerceClient(
        apiBaseUrl: 'http://127.0.0.1:1',
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/v1/plans') {
            return http.Response(
              jsonEncode({
                'success': true,
                'data': [
                  {
                    'id': '10',
                    'name': 'Personal Bundle',
                    'featuresJson': {'addonCode': 'idr_personal_bundle'},
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path == '/api/v1/plans/10/pricings') {
            return http.Response(
              jsonEncode({
                'success': true,
                'data': [
                  {'id': '20', 'billingInterval': 'annual'},
                ],
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'url': 'https://checkout.stripe.com/c/pay/cs_test',
                'sessionId': 'cs_test',
              },
            }),
            200,
          );
        }),
      );

      final created = await client.createCheckoutSession(
        session: _session,
        planCode: 'idr_personal_bundle',
      );
      expect(created.url, contains('checkout.stripe.com'));
    });

    test('fulfillCheckout posts sessionId', () async {
      final client = BillingCommerceClient(
        apiBaseUrl: 'http://127.0.0.1:1',
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/v1/checkout/fulfill');
          expect(jsonDecode(request.body), {'sessionId': 'cs_test'});
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {'subscriptionId': '1'},
            }),
            200,
          );
        }),
      );

      await client.fulfillCheckout(session: _session, sessionId: 'cs_test');
    });
  });

  group('TargetReadyStep billing gate', () {
    const signedIn = IdrAuthSession(token: 't', email: 'a@b.c');

    test('active subscription skips billing', () {
      final step = TargetReadyStep.resolve(
        session: signedIn,
        userState: const TargetUserState(
          planCode: 'idr_personal_bundle',
          hasActivePlan: true,
          accountPath: 'rootAdmin',
        ),
      );
      expect(step, isA<Ready>());
    });

    test('no covering subscription is BillingRequired', () {
      final step = TargetReadyStep.resolve(
        session: signedIn,
        userState: const TargetUserState(
          planCode: 'idr_personal_bundle',
          hasActivePlan: false,
          accountPath: 'rootAdmin',
        ),
      );
      expect(step, isA<BillingRequired>());
    });
  });

  group('IdrTarget hydrate + checkout', () {
    late Directory dir;
    late SessionStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('idr-billing-');
      store = SessionStore(storage: MemoryStorage(), prefix: 't');
      await store.saveSession(
        const IdrAuthSession(token: 'session-token', email: 'user@example.com'),
      );
      await store.writeJson('user_state', const TargetUserState(
        onboardingDone: true,
        accountPath: 'rootAdmin',
        planCode: 'idr_personal_bundle',
        hasActivePlan: true,
      ).toJson());
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    IdrTarget makeTarget({
      required http.Client commerceHttp,
      _Launcher? launcher,
    }) {
      return IdrTarget(
        config: IdrTargetConfig(
          controlPlaneUrl: Uri.parse('http://127.0.0.1:1'),
          agentBinaryPath: 'dummy-agent',
          configDirectory: dir.path,
          mode: IdrTargetMode.development,
        ),
        store: store,
        authClient: BillingAuthClient(
          billingBaseUrl: 'http://127.0.0.1:1',
          deepLinkScheme: 'idr',
          storagePrefix: store.prefix,
          storage: store.storage,
          // Live session lookup fails → AuthManager.restore falls back to the
          // persisted session (never wipes it).
          httpClient: MockClient((_) async => http.Response('null', 200)),
        ),
        billingCommerce: BillingCommerceClient(
          apiBaseUrl: 'http://127.0.0.1:1',
          httpClient: commerceHttp,
        ),
        openUrl: (launcher ?? _Launcher()).open,
      );
    }

    test('401 on hydrate signs out and is not fake entitled', () async {
      final target = makeTarget(
        commerceHttp: MockClient((_) async => http.Response('unauthorized', 401)),
      );
      await target.start();
      expect(target.session, isNull);
      expect(target.state.readyStep, isA<SignInRequired>());
      expect(target.attention?.code, IdrTargetErrorCode.authExpired);
      expect(target.userState.hasActivePlan, isTrue);
      await target.dispose();
    });

    test('no covering subscription is BillingRequired', () async {
      final target = makeTarget(
        commerceHttp: MockClient((_) async => http.Response(
          jsonEncode({'success': true, 'data': <Object>[]}),
          200,
        )),
      );
      await target.start();
      expect(target.session, isNotNull);
      expect(target.userState.hasActivePlan, isFalse);
      expect(target.state.readyStep, isA<BillingRequired>());
      await target.dispose();
    });

    test('checkout does not entitle until hydrate sees an active sub', () async {
      var covering = false;
      final launcher = _Launcher();
      final target = makeTarget(
        launcher: launcher,
        commerceHttp: MockClient((request) async {
          if (request.url.path == '/api/v1/checkout/fulfill') {
            expect(jsonDecode(request.body), {'sessionId': 'cs_test'});
            return http.Response(
              jsonEncode({
                'success': true,
                'data': {'subscriptionId': covering ? '1' : null},
              }),
              200,
            );
          }
          if (request.url.path == '/api/v1/subscriptions') {
            if (!covering) {
              return http.Response(
                jsonEncode({'success': true, 'data': <Object>[]}),
                200,
              );
            }
            return http.Response(
              jsonEncode({
                'success': true,
                'data': [
                  {
                    'subscriptionStatus': 'active',
                    'plan': {'name': 'Personal Bundle'},
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path == '/api/v1/plans') {
            return http.Response(
              jsonEncode({
                'success': true,
                'data': [
                  {
                    'id': '10',
                    'name': 'Personal Bundle',
                    'featuresJson': {'planCode': 'idr_personal_bundle'},
                  },
                ],
              }),
              200,
            );
          }
          if (request.url.path.contains('/pricings')) {
            return http.Response(
              jsonEncode({
                'success': true,
                'data': [
                  {'id': '20', 'billingInterval': 'annual'},
                ],
              }),
              200,
            );
          }
          expect(request.url.path, '/api/v1/checkout/checkout-session');
          return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'url': 'https://checkout.stripe.com/c/pay/cs_test',
                'sessionId': 'cs_test',
              },
            }),
            200,
          );
        }),
      );
      await target.start();
      expect(target.userState.hasActivePlan, isFalse);

      await target.startCheckout('idr_personal_bundle');
      expect(launcher.opened?.toString(), contains('checkout.stripe.com'));
      expect(target.userState.hasActivePlan, isFalse);

      covering = true;
      await target.hydrateSubscription();
      expect(target.userState.hasActivePlan, isTrue);
      expect(target.state.readyStep, isA<Ready>());
      await target.dispose();
    });
  });
}

class _Launcher {
  Uri? opened;

  Future<bool> open(Uri url) async {
    opened = url;
    return true;
  }
}
