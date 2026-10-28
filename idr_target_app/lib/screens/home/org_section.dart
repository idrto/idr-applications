import 'package:flutter/material.dart';
import 'package:idr_target/idr_target.dart';

import '../../target/target_controller.dart';
import '../../ui/components/buttons/idr_button.dart';
import '../../ui/components/cards/idr_card.dart';
import '../../ui/components/dialogs/idr_dialog.dart';
import '../../ui/components/feedback/idr_feedback.dart';
import '../../ui/components/inputs/idr_fields.dart';
import '../../ui/components/layout/idr_layout.dart';
import '../../ui/components/status/idr_status.dart';
import '../../ui/theme/idr_theme.dart';
import '../../widgets/common.dart';

/// Enterprise org: zones (+ access policy, revoke), members, issued devices.
class OrganizationSection extends StatefulWidget {
  const OrganizationSection({super.key, required this.controller});

  final TargetController controller;

  @override
  State<OrganizationSection> createState() => _OrganizationSectionState();
}

class _OrganizationSectionState extends State<OrganizationSection> {
  String _tab = 'zones';

  TargetController get c => widget.controller;

  @override
  Widget build(BuildContext context) {
    final org = c.org;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IdrPageHeader(
          title: org?.name ?? 'Organization',
          subtitle: org == null
              ? null
              : '${org.slug} · you are ${org.role} · ${c.isAdminMachine ? 'admin machine (${c.user.enterpriseCaRole ?? 'root'} CA)' : 'Target machine'}',
        ),
        IdrTabs(
          activeId: _tab,
          onChanged: (id) => setState(() => _tab = id),
          tabs: const [
            IdrTab(id: 'zones', label: 'Zones'),
            IdrTab(id: 'members', label: 'Members'),
            IdrTab(id: 'devices', label: 'Devices'),
          ],
        ),
        const SizedBox(height: 16),
        switch (_tab) {
          'members' => _MembersTab(controller: c),
          'devices' => _DevicesTab(controller: c),
          _ => _ZonesTab(controller: c),
        },
      ],
    );
  }
}

class _ZonesTab extends StatefulWidget {
  const _ZonesTab({required this.controller});

  final TargetController controller;

  @override
  State<_ZonesTab> createState() => _ZonesTabState();
}

class _ZonesTabState extends State<_ZonesTab> {
  Map<String, Map<String, dynamic>>? _billing; // by zone path
  bool _billingUnknown = false;

  TargetController get c => widget.controller;
  bool get _root => c.isAdminMachine && c.user.enterpriseCaRole == 'root';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await c.target.fetchZoneAuthorities();
      if (mounted) {
        setState(() {
          _billing = {
            for (final r in rows)
              if (r['zone'] is String) r['zone'] as String: r,
          };
          _billingUnknown = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _billingUnknown = true);
    }
  }

  String _policy(Map<String, dynamic>? r) {
    if (r == null) return _billingUnknown ? 'billing unreachable' : '-';
    final allowed = [
      for (final s in r['allowedServices'] as List? ?? const ['*']) '$s',
    ];
    return allowed.contains('*') ? 'all services' : allowed.join(', ');
  }

  Future<void> _addZone() async {
    final path = TextEditingController();
    final name = TextEditingController();
    final go = await showIdrDialog<bool>(
      context: context,
      title: 'Add zone',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IdrField(
            label: 'Zone path',
            required: true,
            hint:
                'e.g. fin, or fin.apac for a sub-zone (add the parent first).',
            child: IdrTextField(controller: path, hint: 'fin', mono: true),
          ),
          const SizedBox(height: 12),
          IdrField(
            label: 'Display name',
            child: IdrTextField(controller: name, hint: 'Finance'),
          ),
          const SizedBox(height: 16),
          Builder(
            builder: (ctx) => IdrButton(
              label: 'Issue certificate',
              variant: IdrButtonVariant.primary,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ),
        ],
      ),
    );
    if (go == true) {
      await c.addZone(path.text, name.text);
      await _load();
    }
    path.dispose();
    name.dispose();
  }

  Future<void> _policyDialog(EnterpriseZone z) async {
    final allow = TextEditingController(
      text: [
        for (final s
            in _billing?[z.pathKey]?['allowedServices'] as List? ?? const ['*'])
          '$s',
      ].join(', '),
    );
    final go = await showIdrDialog<bool>(
      context: context,
      title: 'Access policy for ${z.pathKey}',
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IdrField(
            label: 'Services members may use',
            hint: 'Comma-separated service names, or * for all. Takes effect on the next session; nobody re-enrolls.',
            child: IdrTextField(
              controller: allow,
              mono: true,
              hint: 'ollama, lmstudio',
            ),
          ),
          const SizedBox(height: 16),
          Builder(
            builder: (ctx) => IdrButton(
              label: 'Sign policy',
              variant: IdrButtonVariant.primary,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ),
        ],
      ),
    );
    if (go == true) {
      final list = [
        for (final s in allow.text.split(','))
          if (s.trim().isNotEmpty) s.trim(),
      ];
      await c.setZonePolicy(z.pathKey, list.isEmpty ? ['*'] : list);
      await _load();
    }
    allow.dispose();
  }

  Future<void> _personDialog(EnterpriseZone z) async {
    final email = TextEditingController();
    String role = 'auto';
    final go = await showIdrDialog<bool>(
      context: context,
      title: 'Add someone to ${z.pathKey}',
      content: StatefulBuilder(
        builder: (ctx, setLocal) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IdrField(
              label: 'Email',
              required: true,
              child: IdrTextField(controller: email, hint: 'name@acme.com'),
            ),
            const SizedBox(height: 12),
            IdrField(
              label: 'Role',
              hint: 'Only the organization owner makes admins.',
              child: IdrSelect<String>(
                value: role,
                options: const [
                  IdrOption(
                    value: 'auto',
                    label: 'Admin if the zone has none, else member',
                  ),
                  IdrOption(value: 'admin', label: 'Zone admin'),
                  IdrOption(value: 'member', label: 'Member'),
                ],
                onChanged: (v) => setLocal(() => role = v),
              ),
            ),
            const SizedBox(height: 16),
            IdrButton(
              label: 'Add',
              variant: IdrButtonVariant.primary,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      ),
    );
    if (go == true && email.text.contains('@')) {
      await c.addToZone(
        z.pathKey,
        email.text.trim().toLowerCase(),
        role: role == 'auto' ? null : role,
      );
      await _load();
    }
    email.dispose();
  }

  Future<void> _revoke(EnterpriseZone z) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Revoke zone ${z.pathKey}?'),
        content: const Text(
          'Every member of this zone is denied from their next session. The zone key is deleted from this machine. '
          'To bring the zone back you must issue a new certificate and each member must re-enroll.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await c.revokeZone(z.pathKey);
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final zones = c.target.enterpriseZones;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Zones are departments. Each gets its own certificate under the root; members\' certificates chain member → zone → root.',
                style: IdrText.body(
                  size: 12,
                  color: IdrColors.zinc500,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (_root)
              IdrButton(
                label: 'Add zone',
                icon: Icons.add,
                variant: IdrButtonVariant.primary,
                size: IdrButtonSize.sm,
                onPressed: c.busy ? null : _addZone,
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (!_root)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: IdrAlert(
              tone: IdrTone.info,
              title: 'Zone certificates are issued on the root admin machine',
              message: 'This machine can view zones but not issue certificates or sign policies.',
            ),
          ),
        if (zones.isEmpty)
          const IdrCard(
            child: IdrEmpty(
              icon: Icons.account_tree_outlined,
              title: 'No zones yet',
              description: 'Without zones, every approved device sits directly under the root.',
            ),
          ),
        for (final z in zones)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: IdrCard(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        z.pathKey,
                        style: IdrText.mono(size: 13, weight: FontWeight.w600),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          z.displayName,
                          style: IdrText.body(color: IdrColors.zinc500),
                        ),
                      ),
                      IdrStatusBadge(
                        status: z.hasCertificate
                            ? IdrStatus.verified
                            : IdrStatus.inactive,
                        label: z.hasCertificate
                            ? 'Certificate'
                            : 'No certificate',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  IdrInfoGroup(
                    rows: [
                      IdrInfoRow(
                        label: 'Certificate',
                        value: z.authoritySki == null
                            ? const Text('none')
                            : CopyValue(value: z.authoritySki!, label: 'SKI'),
                      ),
                      IdrInfoRow(
                        label: 'Policy',
                        value: Text(_policy(_billing?[z.pathKey])),
                      ),
                      IdrInfoRow(
                        label: 'Admins',
                        value: Text(
                          [
                            for (final e
                                in ((_billing?[z.pathKey]?['roles'] as Map?) ??
                                        const {})
                                    .entries)
                              if (e.value == 'admin') '${e.key}',
                          ].join(', ').ifEmpty('(none)'),
                        ),
                      ),
                    ],
                  ),
                  if (z.hasCertificate && _root) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        IdrButton(
                          label: 'Access policy',
                          size: IdrButtonSize.sm,
                          onPressed: c.busy ? null : () => _policyDialog(z),
                        ),
                        const SizedBox(width: 8),
                        IdrButton(
                          label: 'Add person',
                          size: IdrButtonSize.sm,
                          onPressed: c.busy ? null : () => _personDialog(z),
                        ),
                        const Spacer(),
                        IdrButton(
                          label: 'Revoke zone',
                          variant: IdrButtonVariant.destructive,
                          size: IdrButtonSize.sm,
                          onPressed: c.busy ? null : () => _revoke(z),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _MembersTab extends StatefulWidget {
  const _MembersTab({required this.controller});

  final TargetController controller;

  @override
  State<_MembersTab> createState() => _MembersTabState();
}

class _MembersTabState extends State<_MembersTab> {
  List<OrgMember>? _members;
  List<OrgInvitation> _invites = const [];
  String? _error;

  TargetController get c => widget.controller;
  bool get _manager => canBill(c.org?.role ?? 'member');

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final m = await c.target.listOrganizationMembers();
      var inv = <OrgInvitation>[];
      try {
        inv = await c.target.listOrganizationInvitations();
      } on IdrTargetException {
        // The roster is still useful if invitations are forbidden.
      }
      if (mounted) {
        setState(() {
          _members = m;
          _invites = inv.where((i) => i.status == 'pending').toList();
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = describeError(e));
    }
  }

  Future<void> _invite() async {
    final email = TextEditingController();
    String role = 'member';
    final go = await showIdrDialog<bool>(
      context: context,
      title: 'Invite to organization',
      content: StatefulBuilder(
        builder: (ctx, setLocal) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IdrField(
              label: 'Email',
              required: true,
              child: IdrTextField(controller: email, hint: 'name@acme.com'),
            ),
            const SizedBox(height: 12),
            IdrField(
              label: 'Role',
              hint: role == 'admin'
                  ? 'An org admin manages the whole organization. To give someone one zone only, add them to a zone.'
                  : 'Members can enroll devices. Give them a zone under Zones.',
              child: IdrSelect<String>(
                value: role,
                options: const [
                  IdrOption(value: 'member', label: 'Member'),
                  IdrOption(value: 'admin', label: 'Admin'),
                ],
                onChanged: (v) => setLocal(() => role = v),
              ),
            ),
            const SizedBox(height: 16),
            IdrButton(
              label: 'Send invitation',
              variant: IdrButtonVariant.primary,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      ),
    );
    if (go == true && email.text.contains('@')) {
      await c.run(
        'Inviting',
        () => c.target.inviteOrganizationMember(
          email: email.text.trim(),
          role: role,
        ),
      );
      await _load();
    }
    email.dispose();
  }

  Future<void> _setRole(OrgMember m, String role) async {
    await c.run(
      'Updating role',
      () => c.target.updateOrganizationMemberRole(memberId: m.id, role: role),
    );
    await _load();
  }

  Future<void> _remove(OrgMember m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${m.email ?? m.name ?? m.id}?'),
        content: const Text('They lose access to the organization.'),
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
    await c.run(
      'Removing member',
      () => c.target.removeOrganizationMember(memberIdOrEmail: m.email ?? m.id),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return IdrAlert(
        tone: IdrTone.error,
        title: 'Could not load members',
        message: _error,
      );
    }
    final members = _members;
    if (members == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final me = c.session?.email.toLowerCase();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_manager)
          Align(
            alignment: Alignment.centerRight,
            child: IdrButton(
              label: 'Invite',
              icon: Icons.person_add_alt,
              variant: IdrButtonVariant.primary,
              size: IdrButtonSize.sm,
              onPressed: c.busy ? null : _invite,
            ),
          ),
        const SizedBox(height: 8),
        IdrCard(
          child: IdrTable(
            columns: const ['Email', 'Name', 'Role', ''],
            rows: [
              for (final m in members)
                IdrTableRow(
                  cells: [
                    Text(m.email ?? m.id),
                    Text(m.name ?? ''),
                    Text(m.role),
                    if (_manager &&
                        m.role != 'owner' &&
                        (m.email ?? '').toLowerCase() != me)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IdrButton(
                            label: m.role == 'admin'
                                ? 'Make member'
                                : 'Make admin',
                            size: IdrButtonSize.xs,
                            onPressed: c.busy
                                ? null
                                : () => _setRole(
                                    m,
                                    m.role == 'admin' ? 'member' : 'admin',
                                  ),
                          ),
                          const SizedBox(width: 4),
                          IdrButton(
                            label: 'Remove',
                            variant: IdrButtonVariant.ghost,
                            size: IdrButtonSize.xs,
                            onPressed: c.busy ? null : () => _remove(m),
                          ),
                        ],
                      )
                    else
                      const SizedBox.shrink(),
                  ],
                ),
            ],
          ),
        ),
        if (_invites.isNotEmpty) ...[
          const SizedBox(height: 16),
          const IdrSectionTitle(label: 'Pending invitations'),
          IdrCard(
            child: IdrTable(
              columns: const ['Email', 'Role'],
              rows: [
                for (final i in _invites)
                  IdrTableRow(cells: [Text(i.email), Text(i.role)]),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _DevicesTab extends StatefulWidget {
  const _DevicesTab({required this.controller});

  final TargetController controller;

  @override
  State<_DevicesTab> createState() => _DevicesTabState();
}

class _DevicesTabState extends State<_DevicesTab> {
  List<Map<String, dynamic>>? _devices;
  String? _error;

  TargetController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final d = await c.target.listCredentials();
      if (mounted) {
        setState(() {
          _devices = d;
          _error = null;
        });
      }
    } catch (e) {
      final text = describeError(e);
      if (mounted) {
        setState(
          () => _error = text.contains('(403)')
              ? 'Billing lists devices only for the organization owner (you are ${c.org?.role}).'
              : text.contains('NOT_REGISTERED')
              ? 'No machines are registered with billing yet. Approved devices appear here.'
              : text,
        );
      }
    }
  }

  Future<void> _revoke(Map<String, dynamic> d) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Revoke ${d['host'] ?? d['ski']}?'),
        content: const Text(
          'Its next session is denied and its seat is released.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await c.revokeCredential('${d['ski']}');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return IdrAlert(
        tone: IdrTone.info,
        title: 'Devices unavailable',
        message: _error,
      );
    }
    final devices = _devices;
    if (devices == null) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (devices.isEmpty) {
      return const IdrCard(
        child: IdrEmpty(
          icon: Icons.devices_other,
          title: 'No devices yet',
          description: 'Approved Targets and Sources appear here.',
        ),
      );
    }
    return IdrCard(
      child: IdrTable(
        columns: const ['Host', 'Kind', 'Status', 'Zone', ''],
        rows: [
          for (final d in devices)
            IdrTableRow(
              cells: [
                Text('${d['host'] ?? '-'}'),
                Text('${d['kind'] ?? '-'}'),
                Text('${d['status'] ?? '-'}'),
                Text('${d['zone'] ?? '(root)'}'),
                Align(
                  alignment: Alignment.centerRight,
                  child: d['status'] == 'revoked'
                      ? const SizedBox.shrink()
                      : IdrButton(
                          label: 'Revoke',
                          variant: IdrButtonVariant.ghost,
                          size: IdrButtonSize.xs,
                          onPressed: c.busy ? null : () => _revoke(d),
                        ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
