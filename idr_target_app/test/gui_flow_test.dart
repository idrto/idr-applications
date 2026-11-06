import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:idr_target/idr_target.dart';
import 'package:idr_target_app/main.dart';
import 'package:idr_target_app/screens/home/services_section.dart';
import 'package:idr_target_app/target/target_controller.dart';
import 'package:idr_target_app/ui/components/buttons/idr_button.dart';

class _MemoryStorage implements BillingAuthStorage {
  final map = <String, String>{};

  @override
  Future<String?> getItem(String key) async => map[key];

  @override
  Future<void> setItem(String key, String value) async => map[key] = value;

  @override
  Future<void> removeItem(String key) async => map.remove(key);
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

/// A controller over the real SDK, with billing/Auth answered in-process.
Future<TargetController> _controller({
  List<String> providers = const ['google'],
  bool signedIn = false,
  TargetUserState? user,
  bool covered = false,
}) async {
  final store = SessionStore(storage: _MemoryStorage(), prefix: 't');
  if (signedIn) {
    await store.saveSession(
      const IdrAuthSession(token: 'tok', email: 'me@example.com'),
    );
  }
  final client = MockClient((req) async {
    if (req.url.path == '/api/auth/.well-known/oauth-providers') {
      return _json({
        'providers': [
          for (final p in providers) {'id': p, 'enabled': true},
        ],
      });
    }
    if (req.url.path == '/api/v1/subscriptions') {
      return _json({
        'data': covered
            ? [
                {
                  'subscriptionStatus': 'active',
                  'plan': {'name': 'IDR Personal bundle'},
                },
              ]
            : <Object>[],
      });
    }
    return _json({'error': 'not found'}, 404);
  });
  final target = IdrTarget(
    config: IdrTargetConfig(
      controlPlaneUrl: Uri.parse('http://127.0.0.1:3000'),
      agentBinaryPath: 'target-agent',
      mode: IdrTargetMode.development,
      configDirectory: Directory.systemTemp.createTempSync('idr_gui_').path,
    ),
    store: store,
    httpClient: client,
  );
  if (user != null) await target.saveUserState(user);
  return TargetController(target: target, store: store);
}

Future<void> _pumpApp(WidgetTester tester, TargetController c) async {
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(TargetApp(controller: c));
  await tester.pumpAndSettle();
}

void main() {

  testWidgets('sign-in offers only what the SDK can run (Google)', (t) async {
    final c = (await t.runAsync(
      () => _controller(providers: ['google', 'microsoft', 'email']),
    ))!;
    await t.runAsync(c.boot);
    await _pumpApp(t, c);

    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.textContaining('Microsoft'), findsNothing);
    // The Figma registration form does not exist in the real flow.
    expect(find.text('Create Account'), findsNothing);
    expect(find.text('Full name'), findsNothing);
    expect(find.textContaining('Terms of Service'), findsOneWidget);
  });

  testWidgets('signed in without a mode asks which mode to use', (t) async {
    final c = (await t.runAsync(() => _controller(signedIn: true)))!;
    await t.runAsync(c.boot);
    await _pumpApp(t, c);

    expect(find.text('How will you use this machine?'), findsOneWidget);
    expect(find.text('Use my own devices'), findsOneWidget);
    expect(find.text('Manage an organization'), findsOneWidget);
    expect(find.text('Run Targets for customers'), findsOneWidget);
  });

  testWidgets('chosen mode without a subscription lands on billing', (t) async {
    final c = (await t.runAsync(
      () => _controller(
        signedIn: true,
        user: const TargetUserState(
          planCode: 'idr_personal_bundle',
          accountPath: 'joinTarget',
        ),
      ),
    ))!;
    await t.runAsync(c.boot);
    await _pumpApp(t, c);

    expect(find.text('Activate Personal'), findsOneWidget);
    expect(find.text('Open checkout in browser'), findsOneWidget);
  });

  testWidgets('paid Target without a host registers this machine', (t) async {
    final c = (await t.runAsync(
      () => _controller(
        signedIn: true,
        covered: true,
        user: const TargetUserState(
          planCode: 'idr_personal_bundle',
          accountPath: 'joinTarget',
        ),
      ),
    ))!;
    await t.runAsync(c.boot);
    await _pumpApp(t, c);

    expect(find.text('Register this machine'), findsOneWidget);
    final register = find.widgetWithText(IdrButton, 'Register');
    expect(register, findsOneWidget);

    // Invalid host names are caught before anything is submitted.
    await t.enterText(find.byType(TextFormField).first, 'Bad Name');
    await t.pump();
    // Register stays disabled until the name is valid.
    expect(t.widget<IdrButton>(register).onPressed, isNull);
    await t.enterText(find.byType(TextFormField).first, 'laptop');
    await t.pump();
    expect(t.widget<IdrButton>(register).onPressed, isNotNull);
    expect(TargetController.hostProblem('Bad Name'), isNotNull);
    expect(TargetController.hostProblem('laptop'), isNull);
  });

  testWidgets('services: add, reject duplicate, toggle and remove', (t) async {
    final c = (await t.runAsync(() => _controller(signedIn: true)))!;
    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: c,
            builder: (_, _) =>
                SingleChildScrollView(child: ServicesSection(controller: c)),
          ),
        ),
      ),
    );
    expect(find.text('No services yet'), findsOneWidget);

    Future<void> addOllama() async {
      await t.tap(find.text('Add service').first);
      await t.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await t.enterText(fields.at(0), 'ollama');
      await t.enterText(fields.at(1), 'http://127.0.0.1:11434');
      await t.tap(find.text('Add service').last);
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await t.pumpAndSettle();
    }

    await addOllama();
    expect(c.state.services.map((s) => s.name), ['ollama']);
    expect(find.text('ollama'), findsOneWidget);

    // Same name again: the SDK's validation message reaches the form.
    await addOllama();
    expect(find.text('Name already used'), findsOneWidget);
    expect(c.state.services, hasLength(1));

    // Close the form that still shows the error, then pause and remove.
    await t.tap(find.byIcon(Icons.close));
    await t.pumpAndSettle();
    await t.tap(find.byType(Switch));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await t.pumpAndSettle();
    expect(c.state.services.single.enabled, isFalse);
    await t.tap(find.byIcon(Icons.delete_outline));
    await t.pumpAndSettle();
    await t.tap(find.text('Remove').last);
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await t.pumpAndSettle();
    expect(c.state.services, isEmpty);
    expect(find.text('No services yet'), findsOneWidget);
  });

  test('org slug and host validation mirror the CLI', () {
    expect(TargetController.orgSlugProblem(''), isNotNull);
    expect(TargetController.orgSlugProblem('has space'), isNotNull);
    expect(TargetController.orgSlugProblem('me'), isNotNull);
    expect(TargetController.orgSlugProblem('acme.com'), isNull);
    expect(canBill('owner'), isTrue);
    expect(canBill('admin'), isTrue);
    expect(canBill('member'), isFalse);
  });
}
