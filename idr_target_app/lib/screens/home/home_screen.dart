import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:idr_target/idr_target.dart';

import '../../target/target_controller.dart';
import '../../target/target_env.dart';
import '../../ui/components/buttons/idr_button.dart';
import '../../ui/components/cards/idr_card.dart';
import '../../ui/components/feedback/idr_feedback.dart';
import '../../ui/components/layout/idr_layout.dart';
import '../../ui/components/status/idr_status.dart';
import '../../ui/idr_dashboard.dart';
import '../../ui/theme/idr_theme.dart';
import '../../widgets/common.dart';
import '../flow_screens.dart';
import 'approvals_section.dart';
import 'domains_section.dart';
import 'org_section.dart';
import 'services_section.dart';
import 'transfers_section.dart';

/// Billing attention codes mean "fix it in the billing portal" (as in the CLI).
const _billingCodes = {
  IdrTargetErrorCode.billingRequired,
  IdrTargetErrorCode.entitlementMissing,
  IdrTargetErrorCode.entitlementExpired,
  IdrTargetErrorCode.entitlementRevoked,
  IdrTargetErrorCode.quotaExceeded,
};

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});

  final TargetController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _section = 'overview';
  int _pending = 0;
  bool _approver = false;
  Timer? _timer;

  TargetController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// Keeps the approvals badge fresh and polls a Target waiting for its admin.
  Future<void> _tick() async {
    await c.pollEnrollment();
    if (c.registration == null && !c.isAdminMachine) return;
    try {
      final approver = await c.isApprover();
      final pending = approver ? (await c.pendingRequests()).length : 0;
      if (mounted) {
        setState(() {
          _approver = approver;
          _pending = pending;
        });
      }
    } catch (_) {
      // Billing unreachable: keep the last known count.
    }
  }

  @override
  Widget build(BuildContext context) {
    final plan = c.plan;
    final s = c.session;
    final reg = c.registration;
    final items = <IdrDashItem>[
      const IdrDashItem('overview', 'Overview', Icons.dashboard_outlined),
      const IdrDashItem('services', 'Services', Icons.dns_outlined),
      const IdrDashItem('transfers', 'Transfers', Icons.swap_vert_outlined),
      if (_approver)
        IdrDashItem(
          'approvals',
          'Approvals',
          Icons.verified_user_outlined,
          badge: _pending,
        ),
      if (plan == IdrBusinessPlan.serviceProvider) ...const [
        IdrDashItem('tenants', 'Tenants', Icons.apartment_outlined),
        IdrDashItem('domains', 'Custom domains', Icons.language),
      ],
      if (plan == IdrBusinessPlan.enterprise)
        const IdrDashItem(
          'organization',
          'Organization',
          Icons.account_tree_outlined,
        ),
    ];
    final body = switch (_section) {
      'services' => ServicesSection(controller: c),
      'transfers' => TransfersSection(transfers: c.target.transfers),
      'approvals' => ApprovalsSection(controller: c, onChanged: _tick),
      'tenants' => TenantsSection(controller: c),
      'domains' => DomainsSection(controller: c),
      'organization' => OrganizationSection(controller: c),
      'billing' => BillingSection(controller: c),
      'diagnostics' => const DiagnosticsSection(),
      _ => OverviewSection(
        controller: c,
        onGoto: (id) => setState(() => _section = id),
      ),
    };
    return BusyOverlay(
      controller: c,
      child: IdrDashboard(
        title: 'Target',
        tag: plan?.title ?? 'Desktop',
        navTitle: reg?.hostLabel ?? 'This machine',
        navSubtitle: s?.email,
        nav: [
          IdrDashGroup('Target', items),
          const IdrDashGroup('Account', [
            IdrDashItem('billing', 'Billing', Icons.credit_card_outlined),
            IdrDashItem(
              'diagnostics',
              'Diagnostics',
              Icons.monitor_heart_outlined,
            ),
          ]),
        ],
        section: _section,
        onSection: (id) => setState(() => _section = id),
        userInitial: s == null || s.email.isEmpty
            ? null
            : s.email[0].toUpperCase(),
        userLabel: s?.email,
        orgLabel: c.org?.name,
        footer: IdrButton(
          label: 'Sign out',
          variant: IdrButtonVariant.ghost,
          size: IdrButtonSize.sm,
          icon: Icons.logout,
          onPressed: c.busy ? null : () => _confirmSignOut(context),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ErrorBanner(controller: c),
            body,
          ],
        ),
      ),
    );
  }

  Future<void> _confirmSignOut(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'This stops the agent and forgets this machine\'s host registration and bound organization. '
          'Registering again needs a new approval.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (ok == true) await c.signOut();
  }
}

IdrStatus _statusOf(TargetController c) {
  if (c.awaitingApproval) return IdrStatus.warning;
  return switch (c.state.status) {
    IdrTargetStatus.running => IdrStatus.online,
    IdrTargetStatus.starting ||
    IdrTargetStatus.enrolling ||
    IdrTargetStatus.authenticating ||
    IdrTargetStatus.securingTls ||
    IdrTargetStatus.registering => IdrStatus.connecting,
    IdrTargetStatus.reconnecting ||
    IdrTargetStatus.needsAttention => IdrStatus.warning,
    IdrTargetStatus.failed => IdrStatus.offline,
    _ => IdrStatus.inactive,
  };
}

String _statusLabel(TargetController c) {
  if (c.awaitingApproval) return 'Awaiting approval';
  return switch (c.state.status) {
    IdrTargetStatus.running => 'Serving',
    IdrTargetStatus.needsAttention => 'Needs attention',
    IdrTargetStatus.stopped || IdrTargetStatus.signedOut => 'Not serving',
    IdrTargetStatus.initializing => 'Not serving',
    final s => s.name[0].toUpperCase() + s.name.substring(1),
  };
}

class OverviewSection extends StatelessWidget {
  const OverviewSection({
    super.key,
    required this.controller,
    required this.onGoto,
  });

  final TargetController controller;
  final ValueChanged<String> onGoto;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final reg = c.registration;
    final a = c.state.attention;
    final agentMissing = resolveAgentBinary() == null;
    final services = c.state.services;
    final enabled = services.where((s) => s.enabled).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IdrPageHeader(
          title: reg?.hostLabel ?? 'Register this machine',
          subtitle: reg?.verifiedFqhn ?? 'This machine is not registered yet.',
          actions: reg == null
              ? null
              : IdrStatusBadge(status: _statusOf(c), label: _statusLabel(c)),
        ),
        if (agentMissing) ...[
          IdrAlert(
            tone: IdrTone.error,
            title: 'target-agent was not found',
            message: 'Build it (cargo build --release -p target-agent --features webrtc), put it next to this app, or set IDR_TARGET_AGENT.',
            actions: IdrButton(
              label: 'Diagnostics',
              size: IdrButtonSize.sm,
              onPressed: () => onGoto('diagnostics'),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (c.awaitingApproval) ...[
          IdrAlert(
            tone: IdrTone.warning,
            title: 'Waiting for admin approval',
            message: c.isAdminMachine
                ? 'Approve this machine under Approvals.'
                : 'Ask your admin to approve ${reg?.verifiedFqhn ?? 'this machine'}. This page checks automatically.',
            actions: c.isAdminMachine
                ? IdrButton(
                    label: 'Approvals',
                    size: IdrButtonSize.sm,
                    onPressed: () => onGoto('approvals'),
                  )
                : IdrButton(
                    label: 'Check now',
                    size: IdrButtonSize.sm,
                    onPressed: c.busy ? null : c.pollEnrollment,
                  ),
          ),
          const SizedBox(height: 12),
        ],
        if (a != null &&
            a.code != IdrTargetErrorCode.authRequired &&
            a.code != IdrTargetErrorCode.hostNotRegistered) ...[
          IdrAlert(
            tone: IdrTone.warning,
            title: a.code.wire,
            message: a.message,
            actions: _billingCodes.contains(a.code)
                ? IdrButton(
                    label: 'Billing',
                    size: IdrButtonSize.sm,
                    onPressed: () => onGoto('billing'),
                  )
                : null,
          ),
          const SizedBox(height: 12),
        ],
        if (reg == null) ...[
          IdrCard(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (c.isAdminMachine)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: IdrAlert(
                      tone: IdrTone.success,
                      title: 'Admin machine ready',
                      message: 'This machine holds the certificate authority and approves other machines. Register it too if you want it to serve services.',
                    ),
                  ),
                RegisterForm(controller: c),
              ],
            ),
          ),
        ] else ...[
          IdrStatGrid(
            children: [
              IdrStatCard(
                label: 'Status',
                value: _statusLabel(c),
                tone: c.agentRunning ? IdrStatTone.accent : IdrStatTone.neutral,
              ),
              IdrStatCard(
                label: 'Services',
                value: '$enabled',
                sub: '${services.length} configured',
              ),
              IdrStatCard(
                label: 'Mode',
                value: c.plan?.title ?? '-',
                sub: c.isAdminMachine ? 'Admin machine' : 'Target',
              ),
              IdrStatCard(
                label: 'Subscription',
                value: c.covered ? 'Active' : 'Inactive',
                tone: c.covered ? IdrStatTone.neutral : IdrStatTone.warn,
              ),
            ],
          ),
          const SizedBox(height: 16),
          IdrCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(_nextTitle(c), style: IdrText.display(size: 14)),
                          const SizedBox(height: 2),
                          Text(
                            _nextBody(c),
                            style: IdrText.body(
                              size: 12,
                              color: IdrColors.zinc500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    _primaryAction(context),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          IdrCard(
            padding: const EdgeInsets.all(16),
            child: IdrInfoGroup(
              rows: [
                IdrInfoRow(
                  label: 'Address',
                  value: CopyValue(value: reg.verifiedFqhn, label: 'Address'),
                ),
                IdrInfoRow(
                  label: 'Account',
                  value: Text(c.session?.email ?? '-'),
                ),
                if (c.org != null)
                  IdrInfoRow(
                    label: 'Organization',
                    value: Text('${c.org!.name} (${c.org!.role})'),
                  ),
                IdrInfoRow(
                  label: 'Presence',
                  value: Text(c.target.config.discoveryUrl),
                  mono: true,
                ),
                IdrInfoRow(
                  label: 'Control plane',
                  value: Text(c.target.config.controlPlaneBase),
                  mono: true,
                ),
                IdrInfoRow(label: 'TLS', value: Text(c.state.tls.name)),
              ],
            ),
          ),
        ],
      ],
    );
  }

  String _nextTitle(TargetController c) {
    if (c.awaitingApproval) return 'Waiting for approval';
    if (c.agentRunning) {
      return 'Serving ${c.state.services.where((s) => s.enabled).length} service(s)';
    }
    if (c.state.services.isEmpty) return 'Add a service to publish';
    return 'Start serving';
  }

  String _nextBody(TargetController c) {
    if (c.awaitingApproval) {
      return 'The admin machine must approve this registration first.';
    }
    if (c.agentRunning) {
      return 'Approved Sources can reach this machine through Presence. No inbound port is opened.';
    }
    if (c.state.services.isEmpty) {
      return 'Publish a local app such as Ollama under Services, then start serving.';
    }
    return 'Starts the Target agent and publishes your enabled services.';
  }

  Widget _primaryAction(BuildContext context) {
    final c = controller;
    if (c.awaitingApproval) return const SizedBox.shrink();
    if (c.agentRunning || c.state.status == IdrTargetStatus.starting) {
      return IdrButton(
        label: 'Stop',
        variant: IdrButtonVariant.destructive,
        icon: Icons.stop,
        onPressed: c.busy ? null : c.stopServing,
      );
    }
    return IdrButton(
      label: 'Start serving',
      variant: IdrButtonVariant.primary,
      icon: Icons.play_arrow,
      loading: c.busy,
      onPressed: c.busy ? null : c.startServing,
    );
  }
}

class BillingSection extends StatefulWidget {
  const BillingSection({super.key, required this.controller});

  final TargetController controller;

  @override
  State<BillingSection> createState() => _BillingSectionState();
}

class _BillingSectionState extends State<BillingSection> {
  String? _fallbackUrl;

  TargetController get c => widget.controller;

  Future<void> _open(String path) async {
    final url = await c.run('Opening billing portal', () => c.openPortal(path));
    setState(() => _fallbackUrl = url);
  }

  @override
  Widget build(BuildContext context) {
    final plan = c.plan;
    final org = c.org;
    final canManage = org == null || canBill(org.role);
    final seats =
        plan == IdrBusinessPlan.enterprise ||
        plan == IdrBusinessPlan.serviceProvider;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const IdrPageHeader(
          title: 'Billing',
          subtitle: 'Subscription and seats',
        ),
        IdrCard(
          padding: const EdgeInsets.all(16),
          child: IdrInfoGroup(
            rows: [
              IdrInfoRow(
                label: 'Plan',
                value: Text(
                  plan == null ? '-' : '${plan.title} (${plan.planCode})',
                ),
              ),
              if (org != null)
                IdrInfoRow(
                  label: 'Paid by',
                  value: Text('${org.name} (${org.slug}), you are ${org.role}'),
                ),
              IdrInfoRow(
                label: 'Subscription',
                value: IdrStatusBadge(
                  status: c.covered ? IdrStatus.active : IdrStatus.denied,
                  label: c.covered ? 'Active' : 'Missing or expired',
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (!canManage)
          const IdrAlert(
            tone: IdrTone.info,
            title: 'Billing is managed by owners and admins',
            message:
                'Ask an owner of the organization to change the subscription.',
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              IdrButton(
                label: c.covered ? 'Manage subscription' : 'Subscribe',
                variant: IdrButtonVariant.primary,
                onPressed: c.busy
                    ? null
                    : () => _open(
                        c.covered
                            ? c.portalPaths.manage
                            : c.portalPaths.subscribe,
                      ),
              ),
              if (seats && c.covered)
                IdrButton(
                  label: 'Buy more seats',
                  onPressed: c.busy
                      ? null
                      : () => _open(c.portalPaths.subscribe),
                ),
              IdrButton(
                label: 'Refresh status',
                onPressed: c.busy ? null : c.refreshSubscription,
              ),
            ],
          ),
        if (_fallbackUrl != null) ...[
          const SizedBox(height: 12),
          IdrAlert(
            tone: IdrTone.info,
            title: 'Could not open a browser',
            message: 'Visit: $_fallbackUrl',
          ),
        ],
        if (seats) ...[
          const SizedBox(height: 16),
          Text(
            'Every approved machine takes one seat, Targets and Sources alike. Revoking a machine frees its seat.',
            style: IdrText.body(
              size: 12,
              color: IdrColors.zinc500,
              height: 1.4,
            ),
          ),
        ],
      ],
    );
  }
}

/// Environment checks equivalent to `idrt doctor` (run on demand).
class DiagnosticsSection extends StatefulWidget {
  const DiagnosticsSection({super.key});

  @override
  State<DiagnosticsSection> createState() => _DiagnosticsSectionState();
}

class _DiagnosticsSectionState extends State<DiagnosticsSection> {
  List<(String, bool, String)>? _checks;
  bool _running = false;

  Future<(bool, String)> _http(String url) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 4);
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 5));
      await res.drain<void>();
      return (res.statusCode < 500, 'HTTP ${res.statusCode}');
    } catch (e) {
      return (false, 'unreachable ($e)');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _run() async {
    setState(() => _running = true);
    final cfg = buildConfig();
    final out = <(String, bool, String)>[];
    out.add(('Mode', true, cfg.mode.name));
    out.add((
      'Billing portal',
      portalBaseUrl.isNotEmpty,
      portalBaseUrl.isEmpty
          ? 'IDR_BILLING_PORTAL_URL is not set'
          : portalBaseUrl,
    ));
    final billing = await _http(cfg.controlPlaneBase);
    out.add((
      'Billing API',
      billing.$1,
      '${cfg.controlPlaneBase}: ${billing.$2}',
    ));
    final presence = await _http(cfg.discoveryUrl);
    out.add((
      'Presence discovery',
      presence.$1,
      '${cfg.discoveryUrl}: ${presence.$2}',
    ));
    final agent = resolveAgentBinary();
    if (agent == null || !File(agent).existsSync()) {
      out.add(('target-agent', false, 'not found (set IDR_TARGET_AGENT)'));
    } else {
      try {
        final r = await Process.run(agent, [
          'version',
        ]).timeout(const Duration(seconds: 10));
        out.add((
          'target-agent',
          r.exitCode == 0,
          r.exitCode == 0
              ? '$agent (${'${r.stdout}'.trim().split('\n').first})'
              : '$agent exited ${r.exitCode}',
        ));
      } catch (e) {
        out.add(('target-agent', false, 'cannot run $agent ($e)'));
      }
    }
    try {
      IdrDpCrypto.open();
      out.add(('idr_dp library', true, 'loaded'));
    } catch (e) {
      out.add(('idr_dp library', false, 'not loaded ($e). Set IDR_DP_LIB.'));
    }
    try {
      final s = await Socket.connect(
        '127.0.0.1',
        9091,
        timeout: const Duration(seconds: 1),
      );
      s.destroy();
      out.add(('Agent process', true, 'running (metrics port 9091 answers)'));
    } catch (_) {
      out.add(('Agent process', true, 'not running'));
    }
    if (mounted) {
      setState(() {
        _checks = out;
        _running = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IdrPageHeader(
          title: 'Diagnostics',
          subtitle: 'Local services and the path to IDR',
          actions: IdrButton(
            label: _checks == null ? 'Run checks' : 'Run again',
            variant: IdrButtonVariant.primary,
            size: IdrButtonSize.sm,
            loading: _running,
            onPressed: _running ? null : _run,
          ),
        ),
        if (_checks == null)
          const IdrCard(
            child: IdrEmpty(
              icon: Icons.monitor_heart_outlined,
              title: 'No checks run yet',
              description: 'Checks the billing API, Presence, target-agent and the certificate library.',
            ),
          ),
        for (final (name, ok, detail)
            in _checks ?? const <(String, bool, String)>[])
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: IdrCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 160,
                    child: Text(
                      name,
                      style: IdrText.body(weight: FontWeight.w500),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      detail,
                      style: IdrText.mono(size: 11, color: IdrColors.zinc500),
                    ),
                  ),
                  IdrStatusBadge(
                    status: ok ? IdrStatus.online : IdrStatus.offline,
                    label: ok ? 'OK' : 'Fail',
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
