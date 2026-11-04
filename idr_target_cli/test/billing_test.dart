import 'package:idr_target/idr_target.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target_cli/core/billing.dart';
import 'package:idr_target_cli/core/target.dart';
import 'package:test/test.dart';

class _MemoryStorage implements BillingAuthStorage {
  final _m = <String, String>{};
  @override
  Future<String?> getItem(String key) async => _m[key];
  @override
  Future<void> setItem(String key, String value) async => _m[key] = value;
  @override
  Future<void> removeItem(String key) async => _m.remove(key);
}

void main() {
  const personal = IdrBusinessPlan.personal;
  // In-process, like `idrt --flavor dev` (portal URL from config/dev.json).
  setUpAll(() => IdrFlavor.current = IdrFlavor.load('dev'));

  test('personal deep-links the shop to its addonCode', () {
    expect(portalPaths(personal).subscribe, '/shop/idr_personal_bundle');
    expect(portalPaths(personal).manage, '/subscriptions');
  });

  test('enterprise deep-links the org shop; only owner/admin can bill', () {
    expect(
      portalPaths(IdrBusinessPlan.enterprise).subscribe,
      '/shop/idr_enterprise_bundle',
    );
    expect(canBill('owner'), isTrue);
    expect(canBill('admin'), isTrue);
    expect(canBill('member'), isFalse);
  });

  test('service provider deep-links seat checkout', () {
    expect(
      portalPaths(IdrBusinessPlan.serviceProvider).subscribe,
      '/shop/idr_sp_target',
    );
  });

  test('billing gate: covered only by an active plan of the same mode',
      () async {
    final target = IdrTarget(
      config: IdrTargetConfig(
        // Unroutable: handoff fails fast and falls back to the plain URL.
        controlPlaneUrl: Uri.parse('http://127.0.0.1:9'),
        agentBinaryPath: 'target-agent',
      ),
      store: SessionStore(storage: _MemoryStorage()),
    );
    addTearDown(target.dispose);

    await target.saveUserState(const TargetUserState(
      planCode: 'idr_enterprise_bundle',
      hasActivePlan: true,
    ));
    expect(isCovered(target, personal), isFalse);
    await expectLater(
      requireBilling(target, personal, open: false),
      throwsA(isA<CliError>()
          .having((e) => e.exitCode, 'exitCode', CliExit.billing)),
    );

    await target.saveUserState(const TargetUserState(
      planCode: 'idr_personal_bundle',
      hasActivePlan: true,
    ));
    await requireBilling(target, personal, open: false); // no throw
  });
}
