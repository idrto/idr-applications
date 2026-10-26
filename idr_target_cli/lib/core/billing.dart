import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';

import 'target.dart';

/// Where the billing portal handles each mode's subscription.
///
/// [subscribe] deep-links the shop to the plan's addonCode (portal opens checkout);
/// [manage] is the subscriptions page of the account that pays.
({String subscribe, String manage}) portalPaths(IdrBusinessPlan plan) =>
    switch (plan) {
      // Personal: the signed-in user's own (personal org) subscription.
      // Enterprise: same pages, bound to the org (see openPortal).
      // Service Provider: same pages, bound to the tenant's billing org;
      // quantity on /shop is the number of Target seats.
      IdrBusinessPlan() => (
          subscribe: '/shop/${plan.planCode}',
          manage: '/subscriptions'
        ),
    };

/// Attention codes that mean "fix it in the billing portal".
const billingAttentionCodes = {
  IdrTargetErrorCode.billingRequired,
  IdrTargetErrorCode.entitlementMissing,
  IdrTargetErrorCode.entitlementExpired,
  IdrTargetErrorCode.entitlementRevoked,
  IdrTargetErrorCode.quotaExceeded,
};

/// Billing truth comes from [IdrTarget.hydrateSubscription] (run by `start`).
bool isCovered(IdrTarget target, IdrBusinessPlan plan) =>
    target.userState.hasActivePlan &&
    target.userState.planCode == plan.planCode;

/// Opens (or prints) the portal at [path], already signed in when possible.
/// The portal preselects [orgSlug] (default: the org this machine is bound to).
Future<void> openPortal(
  IdrTarget target,
  String path, {
  required bool open,
  String? orgSlug,
}) async {
  if (portalBaseUrl.isEmpty) {
    throw const CliError(
      CliExit.usage,
      'Set IDR_BILLING_PORTAL_URL to the billing portal origin.',
    );
  }
  final plain = Uri.parse('$portalBaseUrl$path');
  final url = await target.billingPortalUrl(
    portalBaseUrl: portalBaseUrl,
    redirectPath: path,
    orgSlug: orgSlug ?? (await loadOrg())?.slug,
  );
  if (!open) {
    // Handoff URLs carry a one-time token: only print them on request.
    ui.info('Open this URL to manage billing:\n  $url');
    return;
  }
  final opened = await LoopbackAuthSessionLauncher.openSystemBrowser(url);
  ui.info(
    opened
        ? 'Opened billing portal: $plain'
        : 'Could not open a browser. Visit:\n  $plain',
  );
}

/// Gate for commands that need a paid [plan]. Sends the user to the portal
/// and throws [CliExit.billing] when the subscription is missing or expired.
Future<void> requireBilling(
  IdrTarget target,
  IdrBusinessPlan plan, {
  bool open = true,
}) async {
  if (isCovered(target, plan)) return;
  // Org members cannot see or buy the org's subscription (server 403s).
  final org = await loadOrg();
  if (org != null && !canBill(org.role)) {
    throw CliError(
      CliExit.billing,
      'Billing for ${org.name} is managed by its owners and admins; '
      'your role is ${org.role}.',
    );
  }
  ui.info(
    'No active ${plan.title} subscription (missing or expired).',
  );
  await openPortal(target, portalPaths(plan).subscribe, open: open);
  throw const CliError(
    CliExit.billing,
    'Complete checkout in the portal, then re-run this command.',
  );
}

IdrBusinessPlan _planFromArgs(IdrTarget target, String? flag) {
  final plan = switch (flag) {
    'personal' => IdrBusinessPlan.personal,
    'enterprise' => IdrBusinessPlan.enterprise,
    'provider' => IdrBusinessPlan.serviceProvider,
    _ => currentPlan(target),
  };
  if (plan == null) {
    throw const CliError(
      CliExit.usage,
      'No mode chosen yet. Run `idrt personal setup` / '
      '`idrt enterprise setup` / `idrt provider setup`, or pass --plan.',
    );
  }
  return plan;
}

void _addBillingFlags(Command<int> c) {
  c.argParser
    ..addOption(
      'plan',
      allowed: ['personal', 'enterprise', 'provider'],
      help: 'Plan to bill (default: this machine\'s mode).',
    )
    ..addFlag(
      'open',
      defaultsTo: true,
      help: 'Open the browser (--no-open prints a signed-in URL).',
    );
}

/// `idrt billing` — subscription state, then the portal's manage page.
class BillingCommand extends Command<int> {
  BillingCommand() {
    _addBillingFlags(this);
    argParser.addFlag(
      'status',
      negatable: false,
      help: 'Only print subscription state; do not open the portal.',
    );
  }

  @override
  String get name => 'billing';

  @override
  String get description =>
      'Show subscription state and open the billing portal to manage it.';

  @override
  Future<int> run() => withTarget((target) async {
        requireSession(target);
        final plan = _planFromArgs(target, argResults!['plan'] as String?);
        final covered = isCovered(target, plan);
        final org = await loadOrg();
        final statusOnly = argResults!['status'] as bool;
        void human() {
          ui.fields({
            'plan': '${plan.title} (${plan.planCode})',
            if (org != null)
              'paid by': '${org.name} (${org.slug}), you are ${org.role}',
            'subscription': covered ? 'active' : 'missing or expired',
          });
          printAttention(target);
        }

        final data = {
          'plan': plan.planCode,
          'paidBy': org?.slug,
          'subscriptionActive': covered,
        };
        if (statusOnly) {
          ui.result(data, human: human);
          return covered ? CliExit.ok : CliExit.billing;
        }
        if (!ui.json) human();
        final paths = portalPaths(plan);
        await openPortal(
          target,
          covered ? paths.manage : paths.subscribe,
          open: argResults!['open'] as bool,
        );
        return CliExit.ok;
      });
}

/// `idrt subscribe` — straight to checkout for the mode's plan.
class SubscribeCommand extends Command<int> {
  SubscribeCommand() {
    _addBillingFlags(this);
  }

  @override
  String get name => 'subscribe';

  @override
  String get description => 'Open billing portal checkout for your plan.';

  @override
  Future<int> run() => withTarget((target) async {
        requireSession(target);
        final plan = _planFromArgs(target, argResults!['plan'] as String?);
        if (isCovered(target, plan)) {
          ui.info('${plan.title} subscription is already active.');
          return CliExit.ok;
        }
        await openPortal(
          target,
          portalPaths(plan).subscribe,
          open: argResults!['open'] as bool,
        );
        ui.info('After checkout, run `idrt billing --status`.');
        return CliExit.ok;
      });
}
