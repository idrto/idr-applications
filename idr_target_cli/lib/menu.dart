import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';

import 'core/billing.dart';
import 'core/commands.dart';
import 'core/devices.dart';
import 'core/target.dart';
import 'core/zones.dart';
import 'modes/enterprise.dart';
import 'modes/provider.dart';

/// `idrt`'s home menu. It follows the SDK's own next step for this machine
/// and offers only what fits it; every entry runs an existing command, and
/// commands ask for anything still missing. Billing has the last word on
/// permissions: entries hidden or explained here are only guidance.
Future<Menu> idrtMenu() => withTarget((target) async {
  final session = target.session;
  if (session == null) {
    return (
      title: 'IDR',
      header: 'You are not signed in.',
      items: <MenuItem>[
        ('Sign in', () => ['login']),
        exitItem,
      ],
    );
  }
  final email = session.email;
  final plan = currentPlan(target);
  final org = await loadOrg();
  final zone = await loadZoneContext();
  // Zone keys the root signed since last time become usable now.
  final keyWaiting = await pullZoneKeys(target);
  final reg = target.registration;
  final step = target.state.readyStep;
  final header = [
    'Signed in as $email',
    if (plan != null) '${plan.title} · ${await _machineRole(target, plan)}',
    if (org != null) 'Organization: ${org.name} (${org.slug}), ${org.role}',
    if (zone != null) 'Zone: ${zone.zone}, you are ${zone.role}',
    if (reg != null)
      'Target FQHN: ${reg.verifiedFqhn}  (the name people enroll against)',
    // Without an org, finishing setup is the next step whatever else is due.
    if (step is! Ready && !(plan == IdrBusinessPlan.enterprise && org == null))
      'Next step: ${readyStepName(step)}',
  ].join('\n');

  if (plan == null) {
    return (
      title: 'IDR',
      header: '$header\nChoose how this machine will be used:',
      items: <MenuItem>[
        ('Personal setup (your own machines)', () => ['personal', 'setup']),
        (
          'Enterprise setup (an organization)',
          () => _enterpriseSetup(org?.slug, email),
        ),
        (
          'Service Provider setup (run Targets for customers)',
          () => ['provider', 'setup', '--org', _pickOrg(email)],
        ),
        ..._common,
      ],
    );
  }

  // Billing reports an Enterprise plan, but this machine was never bound
  // to the organization: everything else needs that first.
  if (plan == IdrBusinessPlan.enterprise && org == null) {
    return (
      title: 'IDR',
      header:
          '$header\nEnterprise setup is not finished: this machine '
          'has no organization yet.',
      items: <MenuItem>[
        ('Finish Enterprise setup', () => _enterpriseSetup(org?.slug, email)),
        ..._common,
      ],
    );
  }

  final mode = _mode(plan);
  final provider = plan == IdrBusinessPlan.serviceProvider;
  final tenants = provider ? await tenantIds() : const <String>[];
  final reviews = provider || await isApprover(target);
  final enterprise = plan == IdrBusinessPlan.enterprise;
  final awaiting = reg != null && target.state.enrollment.awaitingAdmin;
  // Stuck Target: nobody in the org holds the CA that could approve it.
  final noAdmin =
      enterprise &&
      awaiting &&
      !isAdminMachine(target) &&
      canBill(org!.role) &&
      await _noAdminMachine(target);
  return (
    title: 'IDR',
    header: header,
    items: <MenuItem>[
      if (enterprise && !target.userState.enterpriseEntityConfirmed)
        ('Finish Enterprise setup', () => _enterpriseSetup(org?.slug, email))
      else if (!isCovered(target, plan) && org != null && !canBill(org.role))
        explain(
          'Waiting for ${org.name} to renew the ${plan.title} plan',
          'The organization has no active ${plan.title} subscription. Only '
              'its owner or an admin can buy it (billing portal); this '
              'machine picks it up when you open `idrt` afterwards.',
        )
      else if (!isCovered(target, plan))
        ('Buy or renew the ${plan.title} plan', () => ['billing'])
      else if (provider && tenants.isEmpty)
        ('Add your first customer tenant', () => ['provider', 'tenant', 'add'])
      else if (reg == null)
        ('Register this machine as a Target', () => [mode, 'register'])
      else if (noAdmin)
        (
          'Make this machine the admin and approve it here',
          () => ['enterprise', 'setup', '--org', org.slug, '--role', 'admin'],
        )
      else if (awaiting)
        explain(
          'Waiting for an admin to approve this machine',
          zone != null
              ? 'An admin of zone ${zone.zone} approves it in their `idrt` > '
                    'Pending approvals.'
              : 'On the admin machine: `idrt $mode pending`, then '
                    '`idrt $mode approve` (or use its menu: Pending approvals).',
        )
      else
        ('Start serving (Ctrl+C comes back here)', () => ['start']),
      if (keyWaiting.isNotEmpty)
        explain(
          'Waiting for the root admin to sign your zone key '
              '(${keyWaiting.join(', ')})',
          'The root admin approves it in their `idrt` > Pending approvals. '
              'Then this machine approves requests for '
              '${keyWaiting.join(', ')}; it is picked up when you open `idrt`.',
        ),
      submenu(
        'Services on this machine (${target.services.length})',
        _servicesMenu,
      ),
      if (reviews)
        submenu('Pending approvals', () => _approvalsMenu(mode, plan)),
      if (plan == IdrBusinessPlan.enterprise)
        submenu('Organization: ${org!.name}', _organizationMenu),
      if (provider)
        submenu('Customer tenants (${tenants.length})', _tenantsMenu),
      ('Billing', () => ['billing']),
      ..._common,
    ],
  );
});

final _common = <MenuItem>[
  ('Status', () => ['status']),
  ('Run diagnostics', () => ['doctor']),
  (
    'Sign out',
    () =>
        ui.confirm(
          'Sign out? This machine also forgets its host '
          'registration and organization.',
        )
        ? ['logout']
        : const [],
  ),
  exitItem,
];

String _mode(IdrBusinessPlan plan) => switch (plan) {
  IdrBusinessPlan.personal => 'personal',
  IdrBusinessPlan.enterprise => 'enterprise',
  IdrBusinessPlan.serviceProvider => 'provider',
};

Future<String> _machineRole(IdrTarget target, IdrBusinessPlan plan) async {
  if (plan == IdrBusinessPlan.serviceProvider) return 'provider machine';
  if (!isAdminMachine(target)) {
    final keys = [for (final z in await target.zoneAuthorities()) z.zone];
    return keys.isEmpty
        ? 'Target machine'
        : 'zone admin machine (${keys.join(', ')})';
  }
  return switch (target.userState.enterpriseCaRole) {
    'root' => 'root CA admin machine',
    'intermediate' => 'intermediate CA admin machine',
    _ => 'admin machine',
  };
}

bool _isRootCa(IdrTarget target) =>
    isAdminMachine(target) && target.userState.enterpriseCaRole == 'root';

Future<int?> _pendingCount(IdrTarget target, {String? zone}) async {
  try {
    return (await target.listPendingEnrollments(
      await approverEntity(target),
    )).where((r) => r.isPending && (zone == null || r.zone == zone)).length;
  } catch (_) {
    return null; // billing unreachable: the submenu's command will say why
  }
}

/// Enterprise setup with the organization picked. Setup itself picks the
/// role: admin on the org's first machine, otherwise it asks.
List<String> _enterpriseSetup(String? orgSlug, String email) => [
  'enterprise',
  'setup',
  '--org',
  orgSlug ?? _pickOrg(email),
];

String _pickOrg(String email) =>
    pickOrg(knownOrgsFile, email, validate: orgSlugProblem);

Future<bool> _noAdminMachine(IdrTarget target) async {
  try {
    final entity = target.registration?.entityId ?? target.session!.email;
    if (entity.toLowerCase() != target.session!.email.toLowerCase()) {
      return false; // joined someone else's entity: their admin approves
    }
    return !await target.entityRootExists(entity);
  } catch (_) {
    return false; // unknown: keep the plain "waiting" note
  }
}

Future<Menu> _servicesMenu() => withTarget(
  (target) async => (
    title: 'Services',
    header: target.services.isEmpty
        ? 'Nothing is published yet. Add a local service (e.g. Ollama) so '
              'approved Sources can use it.'
        : 'Published: ${target.services.map((s) => s.name).join(', ')}',
    items: <MenuItem>[
      if (target.services.isNotEmpty)
        ('List services', () => ['services', 'list']),
      ('Add a service', () => ['services', 'add']),
      if (target.services.isNotEmpty)
        (
          'Remove a service',
          () => [
            'services',
            'remove',
            ui.choose('Which service?', [
              for (final s in target.services) s.name,
            ], flag: '<name>'),
          ],
        ),
      backItem,
    ],
  ),
);

Future<Menu> _approvalsMenu(String mode, IdrBusinessPlan plan) =>
    withTarget((target) async {
      final count = await _pendingCount(target);
      return (
        title: 'Pending approvals',
        header: switch (count) {
          null => 'Could not reach billing to count requests.',
          0 =>
            'Nothing is waiting. Machines and Sources that enroll with '
                'this account show up here.',
          _ => '$count request(s) waiting.',
        },
        items: <MenuItem>[
          ('Review pending requests', () => [mode, 'pending']),
          if (count != 0) ...[
            // approve asks for a zone only when the request has none.
            ('Approve a request', () => [mode, 'approve']),
            ('Reject a request', () => [mode, 'reject']),
          ],
          backItem,
        ],
      );
    });

Future<Menu> _organizationMenu() => withTarget((target) async {
  final org = (await loadOrg())!;
  final email = target.session!.email;
  final zones = await zoneRecords(target);
  final root = _isRootCa(target);
  final owner = org.role == 'owner';
  final roles = owner ? const <String, String>{} : await myZoneRoles(target);
  final managesZones = owner || roles.containsValue('admin');
  final others = knownOrgs(
    knownOrgsFile,
    email,
  ).where((o) => o.slug != org.slug);
  return (
    title: 'Organization: ${org.name}',
    header:
        '${org.name} (${org.slug}) · you are ${org.role} · '
        'this machine: ${await _machineRole(target, IdrBusinessPlan.enterprise)}',
    items: <MenuItem>[
      ('View organization details', () => ['enterprise', 'org']),
      if (managesZones && zones.isNotEmpty)
        ('Invite people to zones', () => ['enterprise', 'zone', 'invite']),
      if (zones.isNotEmpty)
        submenu('Zones (${zones.length})', _zonesMenu)
      else if (root)
        ('Create the first zone', () => ['enterprise', 'zone', 'add'])
      else
        explain(
          'Zones (none yet)',
          'No zones yet. The root CA admin machine creates them '
              '(`idrt enterprise zone add <name>`).',
        ),
      if (owner)
        ('Devices (from billing)', () => ['enterprise', 'devices'])
      else
        explain(
          'Devices (owner only)',
          'Billing lists devices only for the organization owner; you '
              'are ${org.role}. Ask an owner.',
        ),
      ('Users and roles', () => ['enterprise', 'members']),
      if (others.isNotEmpty)
        explain(
          'Switch organization',
          'This machine\'s certificates belong to ${org.name}. To use '
              '${others.map((o) => o.name).join(' or ')}, sign out (this '
              'forgets the machine\'s setup) and set it up again, or use '
              'another machine.',
        ),
      backItem,
    ],
  );
});

/// What to tell someone so they can join [zone]: the Target's FQHN (the
/// machine they enroll against) and the exact commands.
List<String> _joinHelp(IdrTarget target, String orgSlug, String zone) {
  final fqhn = target.registration?.verifiedFqhn;
  if (fqhn == null) {
    return [
      'To let people join zone $zone, the organization needs a running Target.',
      'This machine is not registered yet: pick "Register this machine as a '
          'Target" on the main menu. Its FQHN (the name people enroll '
          'against) then shows here.',
    ];
  }
  return [
    'How someone joins zone $zone:',
    '  Target FQHN: $fqhn',
    '  1. Add them to this zone (Add a member, below).',
    '  2. They run: idr login',
    '     then:     idr enroll $fqhn --org $orgSlug',
    '  3. You approve them here (Approve a pending request into this zone).',
  ];
}

Future<Menu> _zonesMenu() => withTarget((target) async {
  final zones = await zoneRecords(target);
  final root = _isRootCa(target);
  String policy(Map<String, Object?> z) {
    final p = z['policy'] as Map?;
    if (p == null) return '';
    final allowed = p['allowedServices'] as List;
    return ' · ${allowed.contains('*') ? 'all services' : allowed.join(', ')}';
  }

  return (
    title: 'Zones',
    header: zones.isEmpty
        ? 'No zones left.'
        : 'Pick a zone to see its details, admins and devices.',
    items: <MenuItem>[
      for (final z in zones)
        submenu(
          '${z['path']}  ${z['name'] ?? '(issued elsewhere)'}${policy(z)}',
          () => _zoneMenu(z['path'] as String),
        ),
      if (root) ('Create a zone', () => ['enterprise', 'zone', 'add']),
      backItem,
    ],
  );
});

Future<Menu> _zoneMenu(String path) => withTarget((target) async {
  final z = (await zoneRecords(
    target,
  )).where((z) => z['path'] == path).firstOrNull;
  if (z == null) {
    throw CliError(
      CliExit.failure,
      'Zone $path is gone.',
      hint: 'It may have been removed on another machine.',
    );
  }
  final org = (await loadOrg())!;
  final root = _isRootCa(target);
  final owner = org.role == 'owner';
  final myRole = owner ? null : (await myZoneRoles(target))[path];
  final manages = owner || myRole == 'admin';
  final keyHere = z['keyOnThisMachine'] == true;
  final local = z['name'] != null;
  final certified = z['certificate'] != null;
  final admins = z['admins'] as List;
  final people = z['zoneMembers'] as List? ?? const [];
  final devices = z['devices'] as List;
  final members = z['members'] as List?;
  final waiting = keyHere ? await _pendingCount(target, zone: path) : null;
  return (
    title: 'Zone $path',
    header: [
      if (local) 'Name: ${z['name']}',
      'Parent: ${z['parent'] ?? '(top level)'}',
      'Certificate: ${certified ? 'issued' : 'none yet'}',
      'Zone admins: ${admins.isEmpty ? '(none)' : admins.join(', ')}',
      'Zone members: ${people.isEmpty ? '(none)' : people.join(', ')}',
      'Approves Sources: ${z['membersApprove'] == true ? 'admins, and members for their own Target' : 'zone admins only'}',
      if (myRole != null) 'You: $myRole of this zone',
      'Devices recorded here: ${devices.isEmpty ? '(none)' : devices.join(', ')}',
      if (members != null && members.isNotEmpty)
        'Enrolled machines (from billing): '
            '${members.map((m) => (m as Map)['host']).join(', ')}',
      '',
      ..._joinHelp(target, org.slug, path),
    ].join('\n'),
    items: <MenuItem>[
      ('View zone details', () => ['enterprise', 'zone', 'show', path]),
      if (root && !certified)
        ('Issue its certificate', () => ['enterprise', 'zone', 'add', path]),
      if (root && certified)
        ('Set allowed services', () => ['enterprise', 'zone', 'policy', path]),
      if (keyHere && waiting != 0)
        (
          'Approve a pending request into this zone'
              '${waiting == null ? '' : ' ($waiting)'}',
          () => ['enterprise', 'approve', '--zone', path],
        )
      else if (keyHere)
        explain(
          'Approve a pending request into this zone (none waiting)',
          'Nothing is waiting for zone $path. Requests show up here after '
              'someone enrolls into it.',
        ),
      if (owner && certified)
        (
          admins.isEmpty ? 'Choose the zone admin' : 'Add another zone admin',
          () => [
            'enterprise',
            'zone',
            'invite',
            '--zone',
            path,
            '--role',
            'admin',
          ],
        ),
      if (manages && certified)
        (
          'Add a member',
          () => [
            'enterprise',
            'zone',
            'invite',
            '--zone',
            path,
            '--role',
            'member',
          ],
        ),
      if (manages && certified)
        (
          'Zone settings (who approves${owner ? ', sub-zones' : ''})',
          () => ['enterprise', 'zone', 'settings', path],
        ),
      if (!root && myRole == 'admin' && z['adminsCreateSubzones'] == true)
        (
          'Create a sub-zone (the root admin signs it)',
          () => ['enterprise', 'zone', 'add', path],
        ),
      if (root && local)
        (
          'Create a sub-zone',
          () => [
            'enterprise',
            'zone',
            'add',
            '$path.${ui.ask('Sub-zone label (e.g. apac)', flag: '<label>', validate: (v) => EnterpriseFqhn.isValidZoneLabel(v) ? null : 'Use lowercase letters, digits and -.')}',
          ],
        ),
      if (certified && org.role == 'owner')
        (
          'Revoke this zone',
          () =>
              ui.confirm(
                'Revoke zone $path? Its members are denied '
                'from their next session until they re-enroll.',
              )
              ? ['enterprise', 'revoke', path]
              : const [],
        ),
      backItem,
    ],
  );
});

Future<Menu> _tenantsMenu() => withTarget((target) async {
  final ids = await tenantIds();
  return (
    title: 'Customer tenants',
    header: ids.isEmpty ? 'No tenants yet.' : 'Tenants: ${ids.join(', ')}',
    items: <MenuItem>[
      if (ids.isNotEmpty)
        ('List tenants', () => ['provider', 'tenant', 'list']),
      ('Add a tenant', () => ['provider', 'tenant', 'add']),
      if (ids.isNotEmpty)
        (
          'Tenant billing',
          () => [
            'provider',
            'billing',
            ui.choose('Which tenant?', ids, flag: '<tenant>'),
          ],
        ),
      backItem,
    ],
  );
});
