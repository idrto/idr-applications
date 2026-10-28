import 'dart:async';

import 'package:flutter/material.dart';
import 'package:idr_target/idr_target.dart';

import '../../target/target_controller.dart';
import '../../ui/components/buttons/idr_button.dart';
import '../../ui/components/cards/idr_card.dart';
import '../../ui/components/feedback/idr_feedback.dart';
import '../../ui/components/inputs/idr_fields.dart';
import '../../ui/components/layout/idr_layout.dart';
import '../../ui/components/status/idr_status.dart';
import '../../ui/theme/idr_theme.dart';
import '../../widgets/common.dart';

/// Custom domains for a Service Provider Target (`idrt provider domain ...`).
///
/// How it works, in the order the user sees it:
/// 1. Billing records the domain and tells us the CNAME target.
/// 2. The customer creates that CNAME at their DNS provider. Billing proves
///    domain control by resolving it (checked on demand, then every 10 minutes
///    for 7 days; verified domains are re-checked every 6 hours).
/// 3. Once verified, the agent requests a Let's Encrypt certificate on its next
///    start and answers the HTTP-01 challenge itself through Relay, so no
///    port or DNS TXT record is needed. It renews 30 days before expiry.
class DomainsSection extends StatefulWidget {
  const DomainsSection({super.key, required this.controller});

  final TargetController controller;

  @override
  State<DomainsSection> createState() => _DomainsSectionState();
}

class _DomainsSectionState extends State<DomainsSection> {
  final _domain = TextEditingController();
  List<CustomDomain>? _domains;
  String? _notice;
  Timer? _timer;

  TargetController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _load();
    // Certificate state changes on disk while the agent works.
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (mounted && !c.busy) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _domain.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final d = await c.domains();
    if (mounted) setState(() => _domains = d);
  }

  Future<void> _add() async {
    final d = await c.run(
      'Adding domain',
      () => c.target.addCustomDomain(_domain.text),
    );
    if (d == null) return;
    _domain.clear();
    _notice = d.verified
        ? '${d.domain} already points here and is verified.'
        : 'Added ${d.domain}. Create the DNS record below, then check it.';
    await _load();
  }

  Future<void> _verify(CustomDomain d) async {
    final r = await c.run(
      'Checking DNS',
      () => c.target.verifyCustomDomain(d.domain),
    );
    if (r != null) {
      _notice = r.verified
          ? '${r.domain} is verified. Restart serving to request its certificate.'
          : null;
    }
    await _load();
  }

  Future<void> _remove(CustomDomain d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${d.domain}?'),
        content: const Text(
          'It stops routing to this Target within 5 minutes. Restart serving to drop its certificate request.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await c.run('Removing domain', () => c.target.removeCustomDomain(d.domain));
    await _load();
  }

  /// The agent reads verified domains when it starts: restart to apply.
  Future<void> _restart() async {
    await c.stopServing();
    await c.startServing();
  }

  @override
  Widget build(BuildContext context) {
    if (c.registration == null) {
      return const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IdrPageHeader(title: 'Custom domains'),
          IdrAlert(
            tone: IdrTone.info,
            title: 'Register this machine first',
            message: 'A custom domain points at a registered Target.',
          ),
        ],
      );
    }
    final domains = _domains;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IdrPageHeader(
          title: 'Custom domains',
          subtitle:
              'Let customers reach ${c.registration!.hostLabel} at their own hostname, with HTTPS',
          actions: IdrButton(
            label: 'Refresh',
            icon: Icons.refresh,
            size: IdrButtonSize.sm,
            onPressed: c.busy ? null : _load,
          ),
        ),
        IdrCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              IdrField(
                label: 'Add a domain',
                hint: 'Use a subdomain such as app.customer.com. An apex domain cannot hold a CNAME.',
                child: Row(
                  children: [
                    Expanded(
                      child: IdrTextField(
                        controller: _domain,
                        hint: 'app.customer.com',
                        mono: true,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IdrButton(
                      label: 'Add domain',
                      variant: IdrButtonVariant.primary,
                      onPressed: c.busy || _domain.text.trim().isEmpty
                          ? null
                          : _add,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_notice != null) ...[
          const SizedBox(height: 12),
          IdrAlert(tone: IdrTone.success, title: _notice!),
        ],
        const SizedBox(height: 16),
        if (domains == null)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (domains.isEmpty)
          const IdrCard(
            child: IdrEmpty(
              icon: Icons.language,
              title: 'No custom domains',
              description: 'Add one above. You will get a DNS record to create, then the certificate is issued automatically.',
            ),
          ),
        for (final d in domains ?? const <CustomDomain>[])
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _DomainCard(
              domain: d,
              controller: c,
              onVerify: () => _verify(d),
              onRemove: () => _remove(d),
              onRestart: _restart,
            ),
          ),
      ],
    );
  }
}

class _DomainCard extends StatelessWidget {
  const _DomainCard({
    required this.domain,
    required this.controller,
    required this.onVerify,
    required this.onRemove,
    required this.onRestart,
  });

  final CustomDomain domain;
  final TargetController controller;
  final VoidCallback onVerify;
  final VoidCallback onRemove;
  final VoidCallback onRestart;

  static String _day(DateTime? t) =>
      t?.toIso8601String().substring(0, 10) ?? '?';

  @override
  Widget build(BuildContext context) {
    final d = domain;
    final c = controller;
    final acme = d.verified ? c.target.acmeStatus(d.domain) : null;
    final certOk = acme?.state == 'issued' || acme?.state == 'valid';
    final certFailed = acme?.state == 'failed';
    final dnsStep = d.verified
        ? IdrStepStatus.done
        : (d.lastError != null ? IdrStepStatus.error : IdrStepStatus.active);
    final certStep = !d.verified
        ? IdrStepStatus.pending
        : certOk
        ? IdrStepStatus.done
        : certFailed
        ? IdrStepStatus.error
        : IdrStepStatus.active;
    return IdrCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(d.domain, style: IdrText.display(size: 16))),
              IdrStatusBadge(
                status: d.verified
                    ? IdrStatus.verified
                    : d.status == 'failed'
                    ? IdrStatus.denied
                    : IdrStatus.connecting,
                label: d.status[0].toUpperCase() + d.status.substring(1),
              ),
            ],
          ),
          const SizedBox(height: 12),
          IdrStepRow(label: 'Domain added', status: IdrStepStatus.done),
          IdrStepRow(
            label: d.verified
                ? 'DNS record verified'
                : 'Create the DNS record, then check it',
            status: dnsStep,
          ),
          IdrStepRow(
            label: certOk
                ? 'Certificate issued'
                : certFailed
                ? 'Certificate request failed'
                : acme?.state == 'issuing'
                ? "Requesting certificate from Let's Encrypt"
                : 'Certificate: issued automatically after verification',
            status: certStep,
            detail: certOk ? 'expires ${_day(acme?.notAfter)}' : null,
          ),
          if (!d.verified) ...[
            const SizedBox(height: 8),
            const IdrSectionTitle(
              label: 'Create this record at your DNS provider',
            ),
            IdrCard(
              padding: const EdgeInsets.all(12),
              child: IdrInfoGroup(
                rows: [
                  const IdrInfoRow(
                    label: 'Type',
                    value: Text('CNAME'),
                    mono: true,
                  ),
                  IdrInfoRow(
                    label: 'Name',
                    value: CopyValue(value: d.domain, label: 'Name'),
                  ),
                  IdrInfoRow(
                    label: 'Value',
                    value: CopyValue(
                      value: d.cnameTarget,
                      label: 'CNAME target',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Copy the value exactly. New records can take a few minutes to appear; IDR also re-checks every 10 minutes for 7 days.',
              style: IdrText.body(
                size: 12,
                color: IdrColors.zinc500,
                height: 1.4,
              ),
            ),
            if (d.lastError != null) ...[
              const SizedBox(height: 8),
              IdrAlert(
                tone: IdrTone.warning,
                title: 'Not verified yet',
                message: d.lastError!.message,
              ),
            ],
          ],
          if (certFailed) ...[
            const SizedBox(height: 8),
            IdrAlert(
              tone: IdrTone.error,
              title: "Let's Encrypt could not issue the certificate",
              message:
                  '${acme!.lastError ?? 'Unknown error'}\nCheck that the agent is running and Presence is reachable, then restart serving.',
            ),
          ],
          if (acme != null && acme.staging)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: IdrAlert(
                tone: IdrTone.info,
                title: 'Development mode',
                message: "Certificates come from Let's Encrypt staging and browsers do not trust them.",
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!d.verified)
                IdrButton(
                  label: 'Check DNS now',
                  variant: IdrButtonVariant.primary,
                  size: IdrButtonSize.sm,
                  onPressed: c.busy ? null : onVerify,
                ),
              if (d.verified && !certOk)
                IdrButton(
                  label: c.agentRunning
                      ? 'Restart to request certificate'
                      : 'Start serving',
                  variant: IdrButtonVariant.primary,
                  size: IdrButtonSize.sm,
                  onPressed: c.busy ? null : onRestart,
                ),
              const Spacer(),
              IdrButton(
                label: 'Remove',
                variant: IdrButtonVariant.ghost,
                size: IdrButtonSize.sm,
                onPressed: c.busy ? null : onRemove,
              ),
            ],
          ),
          if (certOk)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Renews automatically on ${_day(acme?.renewAt)}. Serving HTTPS on this hostname also needs an nginx on this machine that uses the certificate.',
                style: IdrText.body(
                  size: 12,
                  color: IdrColors.zinc500,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Customer tenants of a Service Provider (list is local to this machine).
class TenantsSection extends StatefulWidget {
  const TenantsSection({super.key, required this.controller});

  final TargetController controller;

  @override
  State<TenantsSection> createState() => _TenantsSectionState();
}

class _TenantsSectionState extends State<TenantsSection> {
  final _id = TextEditingController();
  final _name = TextEditingController();
  final _org = TextEditingController();
  String? _fallbackUrl;

  TargetController get c => widget.controller;

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _org.dispose();
    super.dispose();
  }

  Future<void> _billing(Tenant t, {required bool buy}) async {
    final slug = t.org ?? c.org?.slug;
    final url = await c.run(
      'Opening billing portal',
      () => c.openPortal(
        buy ? c.portalPaths.subscribe : c.portalPaths.manage,
        orgSlug: slug,
      ),
    );
    setState(() => _fallbackUrl = url);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IdrPageHeader(
          title: 'Tenants',
          subtitle:
              'Customers you run Targets for. One machine serves one tenant.',
        ),
        if (c.tenants.isEmpty)
          const IdrCard(
            child: IdrEmpty(
              icon: Icons.apartment_outlined,
              title: 'No tenants yet',
              description:
                  'Add a customer below, then register a machine for it.',
            ),
          ),
        for (final t in c.tenants)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: IdrCard(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${t.name} (${t.id})',
                          style: IdrText.display(size: 14),
                        ),
                        Text(
                          'Billed to ${t.org ?? '${c.org?.name ?? 'your provider org'} (provider)'}'
                          '${c.machineTenant == t.id && c.registration != null ? '  ·  served by this machine' : ''}',
                          style: IdrText.body(
                            size: 12,
                            color: IdrColors.zinc500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IdrButton(
                    label: 'Seats',
                    size: IdrButtonSize.sm,
                    onPressed: c.busy ? null : () => _billing(t, buy: true),
                  ),
                  const SizedBox(width: 4),
                  IdrButton(
                    label: 'Billing',
                    size: IdrButtonSize.sm,
                    onPressed: c.busy ? null : () => _billing(t, buy: false),
                  ),
                  IconButton(
                    tooltip: 'Remove tenant',
                    onPressed: c.busy ? null : () => c.removeTenant(t.id),
                    icon: const Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: IdrColors.zinc400,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (_fallbackUrl != null)
          IdrAlert(
            tone: IdrTone.info,
            title: 'Could not open a browser',
            message: 'Visit: $_fallbackUrl',
          ),
        const SizedBox(height: 16),
        IdrCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Add a tenant', style: IdrText.display(size: 14)),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: IdrField(
                      label: 'Tenant id',
                      child: IdrTextField(
                        controller: _id,
                        hint: 'acme',
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: IdrField(
                      label: 'Display name',
                      child: IdrTextField(controller: _name, hint: 'Acme Corp'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: IdrField(
                      label: 'Customer billing org',
                      hint: 'Optional. Default: your provider org.',
                      child: IdrTextField(controller: _org, hint: 'acme'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: IdrButton(
                  label: 'Add tenant',
                  variant: IdrButtonVariant.primary,
                  onPressed: c.busy || _id.text.trim().isEmpty
                      ? null
                      : () async {
                          await c.addTenant(
                            _id.text,
                            name: _name.text,
                            billingOrg: _org.text,
                          );
                          if (c.error == null) {
                            _id.clear();
                            _name.clear();
                            _org.clear();
                          }
                        },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
