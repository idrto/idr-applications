import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';

import '../core/billing.dart';
import '../core/devices.dart';
import '../core/target.dart';
import '../core/zones.dart';

/// Enterprise mode: a billing org pays; its owners/admins run machines.
///
/// - Billing: the session is bound to the org (`setup --org <slug>`), so
///   subscription checks, checkout and seats are the org's.
/// - Users and roles: `enterprise members` (Better Auth; no browser).
/// - Machines: an admin machine (Entity CA) approves Target enrollments.
/// - Zones: certificates, policies and who is admin/member of each are on
///   billing; zone names and recorded devices are local to the root machine.
/// - Zone admins hold their own zone key (signed by the root) and approve
///   their zone's machines and Sources; members serve in their zone.
const _plan = IdrBusinessPlan.enterprise;

class EnterpriseCommand extends Command<int> {
  EnterpriseCommand() {
    addSubcommand(_Setup());
    addSubcommand(_Register());
    addSubcommand(PendingCommand(_plan));
    addSubcommand(DecideCommand(_plan, approve: true, zones: true));
    addSubcommand(DecideCommand(_plan, approve: false));
    addSubcommand(_Org());
    addSubcommand(_Devices());
    addSubcommand(_Zone());
    addSubcommand(_Members());
    addSubcommand(_Revoke());
    addSubcommand(_Block());
  }

  @override
  String get name => 'enterprise';

  @override
  String get description =>
      'Enterprise mode: org subscription, admins, zones and machines.';
}

Future<CliOrg> _requireOrg() async {
  final org = await loadOrg();
  if (org == null) {
    throw const CliError(
      CliExit.usage,
      'This machine is not bound to an organization yet.',
      hint:
          'Finish Enterprise setup: `idrt enterprise setup --org <slug>`, '
          'or run `idrt` for the menu.',
      code: 'ORG_REQUIRED',
    );
  }
  return org;
}

List<String> _zonePath(String? raw) {
  final path = EnterpriseFqhn.parseZonePath(raw ?? '');
  final bad = path.where((z) => !EnterpriseFqhn.isValidZoneLabel(z));
  if (bad.isNotEmpty) {
    throw CliError(CliExit.usage, 'Invalid zone label: ${bad.first}');
  }
  return path;
}

/// [given], or a zone picked from this machine's org graph.
String _pickZone(IdrTarget target, String? given) {
  if (given != null && given.trim().isNotEmpty) {
    return _zonePath(given).join('.');
  }
  final zones = {for (final z in target.enterpriseZones) z.pathKey: z};
  if (zones.isEmpty) {
    throw const CliError(
      CliExit.usage,
      'This organization has no zones on this machine yet.',
      hint:
          'Create one on the root CA admin machine: '
          '`idrt enterprise zone add <name>`.',
      code: 'NO_ZONES',
    );
  }
  return ui.choose(
    'Which zone?',
    zones.keys.toList(),
    flag: '<zone>',
    display: (k) => '$k  ${zones[k]!.displayName}',
  );
}

/// Targets and Sources billing issued under zone [path] (null = the root).
List<Map<String, Object?>> zoneMembers(
  List<Map<String, dynamic>> credentials,
  Object? path,
) => [
  for (final c in credentials)
    if (c['zone'] == path &&
        (c['kind'] == 'machine_source' || c['kind'] == 'machine_target'))
      {
        'host': c['host'],
        'kind': c['kind'],
        'status': c['status'],
        'ski': c['ski'],
      },
];

/// Zones as this machine's org graph and billing know them. Billing records
/// zone certificates and policies; names, zone admins and devices are local.
Future<List<Map<String, Object?>>> zoneRecords(IdrTarget target) async {
  Map<String, Map<String, dynamic>>? onBilling;
  try {
    onBilling = {
      for (final z in await target.fetchZoneAuthorities())
        if (z['ski'] is String) z['ski'] as String: z,
    };
  } catch (_) {
    onBilling = null; // unreachable or not permitted: shown as unknown
  }
  final keysHere = {for (final z in await target.zoneAuthorities()) z.zone};
  Map<String, dynamic>? byZone(String path) =>
      onBilling?.values.where((r) => r['zone'] == path).firstOrNull;
  List<String> people(String path, String role) => [
    for (final e in ((byZone(path)?['roles'] as Map?) ?? const {}).entries)
      if (e.value == role) '${e.key}',
  ];
  // Billing's device list carries each credential's zone; owner only, so
  // null (unknown) for anyone else.
  List<Map<String, dynamic>>? credentials;
  try {
    credentials = await target.listCredentials();
  } catch (_) {
    credentials = null;
  }
  List<Map<String, Object?>>? members(Object? path) =>
      credentials == null ? null : zoneMembers(credentials, path);
  Map<String, Object?>? policy(Map<String, dynamic>? r) => r == null
      ? null
      : {
          'allowedServices': [
            for (final s in r['allowedServices'] as List? ?? const ['*']) '$s',
          ],
          'version': r['policyVersion'] ?? 1,
        };
  final local = target.enterpriseZones.map((z) => z.pathKey).toSet();
  return [
    for (final z in target.enterpriseZones)
      {
        'path': z.pathKey,
        'name': z.displayName,
        'parent': z.pathKey.contains('.')
            ? z.pathKey.substring(0, z.pathKey.lastIndexOf('.'))
            : null,
        'certificate': z.authoritySki,
        'issuedAt': z.issuedAt?.toIso8601String().substring(0, 10),
        'onBilling': onBilling == null || z.authoritySki == null
            ? null
            : onBilling.containsKey(z.authoritySki),
        'keyOnThisMachine': keysHere.contains(z.pathKey),
        'policy': policy(onBilling?[z.authoritySki]),
        'admins': people(z.pathKey, 'admin'),
        'zoneMembers': people(z.pathKey, 'member'),
        'membersApprove': byZone(z.pathKey)?['membersApprove'] == true,
        'adminsCreateSubzones':
            byZone(z.pathKey)?['adminsCreateSubzones'] == true,
        'devices': [
          for (final d in target.enterpriseDevices)
            if (d.zonePath.join('.') == z.pathKey) d.label,
        ],
        'members': members(z.pathKey),
      },
    // Issued from another admin machine: billing knows it, this one doesn't.
    for (final r in onBilling?.values ?? const <Map<String, dynamic>>[])
      if (r['zone'] is String && !local.contains(r['zone']))
        {
          'path': r['zone'],
          'name': null,
          'parent': null,
          'certificate': r['ski'],
          'issuedAt': null,
          'onBilling': true,
          'keyOnThisMachine': keysHere.contains(r['zone']),
          'policy': policy(r),
          'admins': people(r['zone'] as String, 'admin'),
          'zoneMembers': people(r['zone'] as String, 'member'),
          'membersApprove': r['membersApprove'] == true,
          'adminsCreateSubzones': r['adminsCreateSubzones'] == true,
          'devices': const <String>[],
          'members': members(r['zone']),
        },
  ];
}

String _certText(Map<String, Object?> z) => z['certificate'] == null
    ? 'none'
    : switch (z['onBilling']) {
        true => 'on billing',
        false => 'NOT on billing',
        _ => 'billing unreachable',
      };

String _policyText(Map<String, Object?> z) {
  final p = z['policy'] as Map?;
  if (p == null) return z['certificate'] == null ? '-' : 'unknown';
  final allowed = p['allowedServices'] as List;
  return allowed.contains('*') ? 'all services' : allowed.join(', ');
}

/// Register this machine and record it in the org graph under [zone].
/// Zone admins and members register into the zone picked at setup, in the
/// org's entity; billing checks they have a role there.
Future<void> _registerInZone(
  IdrTarget target,
  String host,
  String? zone, {
  String? entityId,
}) async {
  final context = await loadZoneContext();
  final path = _zonePath(zone ?? context?.zone);
  final key = path.join('.');
  final known =
      target.enterpriseZones.any((z) => z.pathKey == key) ||
      context?.zone == key;
  if (path.isNotEmpty && !known) {
    final onBilling = await _billingZones(target);
    if (onBilling != null && !onBilling.contains(key)) {
      throw CliError(
        CliExit.usage,
        'Unknown zone $key.',
        hint: onBilling.isEmpty
            ? 'This organization has no zones yet.'
            : 'Zones: ${onBilling.join(', ')}.',
        code: 'NO_SUCH_ZONE',
      );
    }
  }
  final firstTime = target.registration == null;
  await registerThisMachine(
    target,
    _plan,
    host,
    entityId: entityId ?? context?.entityId,
    // The local graph also records root-level devices; billing only zones.
    zone: path.isEmpty ? null : key,
  );
  if (firstTime && target.registration != null) {
    await target.addEnterpriseDevice(label: host.trim(), zonePath: path);
  }
}

/// Zone paths billing knows for the org, or null when it can't say.
Future<List<String>?> _billingZones(IdrTarget target) async {
  try {
    return [
      for (final z in await target.fetchZoneAuthorities())
        if (z['zone'] is String) z['zone'] as String,
    ]..sort();
  } catch (_) {
    return null;
  }
}

/// `idrt enterprise setup --org <slug> [--role admin|target] [--host …]`
class _Setup extends Command<int> {
  _Setup() {
    argParser
      ..addOption('org', help: 'Billing organization slug (from the portal).')
      ..addOption(
        'role',
        allowed: ['admin', 'target'],
        help:
            'admin: approves machines (Entity CA), can serve too. target: '
            'serves services. Default: admin on the org\'s first machine, '
            'else asked. --role admin also turns a Target into the admin '
            'when the org has none.',
      )
      ..addOption(
        'ca',
        allowed: ['root', 'intermediate'],
        defaultsTo: 'root',
        help: 'Admin CA level: root (org-wide) or intermediate (department).',
      )
      ..addOption('brand', help: 'Brand name (default: org name).')
      ..addOption('host', help: 'Also register this machine, e.g. laptop.')
      ..addOption(
        'zone',
        help:
            'Zone admins and members: the zone this machine is for (asked '
            'when you have several). Others: the zone for --host.',
      )
      ..addOption(
        'entity',
        help:
            'For --host: join the owner entity (the owner sign-in email). '
            'Needed when you are not the org owner.',
      )
      ..addFlag(
        'open',
        defaultsTo: true,
        help: 'Open the billing portal if a subscription is needed.',
      )
      ..addFlag(
        'reset-local-ca',
        negatable: false,
        help:
            'Dev only: forget this machine\'s root CA keys first. Use after '
            'the server root was cleared (billing dev-reset-machine-authn).',
      );
  }

  @override
  String get name => 'setup';

  @override
  String get description =>
      'Bind to your billing org, check its subscription, set up this machine.';

  @override
  Future<int> run() => withTarget((target) async {
    requireSession(target);
    final slug = ui.ask(
      'Organization slug (from the billing portal)',
      value: (argResults!['org'] as String?) ?? (await loadOrg())?.slug,
      flag: '--org <slug>',
      validate: orgSlugProblem,
    );
    if (slug == 'me' || slug == 'personal') {
      usageException(
        'That is your personal account; use `idrt personal setup`.',
      );
    }

    final ({String slug, String name, String role}) org;
    try {
      org = await target.bindOrganization(slug);
    } on IdrTargetException catch (e) {
      if (!e.message.contains('Organization not found')) rethrow;
      throw CliError(
        CliExit.usage,
        'No organization has the slug "$slug" yet.',
        hint:
            'Create it in the billing portal ($portalBaseUrl), or check the '
            'slug there, then run setup again.',
        code: 'ORG_NOT_FOUND',
      );
    }
    if (!canBill(org.role)) return _setupInZone(target, org);
    await saveOrg(org, target.session!.email);
    ui.info('Organization: ${org.name} (${org.slug}), you are ${org.role}.');

    final paid = target.userState.hasActivePlan ? currentPlan(target) : null;
    if (paid != null && paid != _plan) {
      throw CliError(
        CliExit.usage,
        '${org.name} has an active ${paid.title} subscription, '
        'not Enterprise.',
      );
    }
    await target.savePlanSelection(planCode: _plan.planCode);

    final roleFlag = argResults!['role'] as String?;
    var admin = isAdminMachine(target);
    if (target.userState.accountPath == null) {
      admin = switch (roleFlag) {
        'admin' => true,
        'target' => false,
        _ => await _firstRole(target, org),
      };
      await target.saveAccountPath(admin ? 'rootAdmin' : 'joinTarget');
      await target.saveEnterpriseUiFlags(
        entityRole: admin ? 'adminCa' : 'enrollTarget',
      );
    } else if (roleFlag == 'admin' && !admin) {
      await _promoteToAdmin(target, org);
      admin = true;
    } else if (roleFlag == 'target' && admin) {
      throw const CliError(
        CliExit.usage,
        'This machine is already the admin machine (it can serve services '
        'too). Run `idrt logout` to start over.',
      );
    }

    await requireBilling(target, _plan, open: argResults!['open'] as bool);

    final brand = (argResults!['brand'] as String?)?.trim();
    await target.enterpriseOrg.setBrandName(
      brand != null && brand.isNotEmpty
          ? brand
          : target.enterpriseOrg.brandName ?? org.name,
    );
    await target.saveEnterpriseUiFlags(
      entityConfirmed: true,
      caRole: admin ? argResults!['ca'] as String : null,
    );

    if (admin) {
      if (argResults!['reset-local-ca'] as bool) {
        await target.forgetAdminCa();
        ui.info('Forgot this machine\'s local root CA keys.');
      }
      // Only an enterprise-package root can issue zone authorities.
      await target.ensureAdminCa(package: 'enterprise');
      ui.info(
        'This machine is an Enterprise admin '
        '(${argResults!['ca']} CA) for ${org.name}.',
      );
    } else {
      ui.info('This machine is an Enterprise Target for ${org.name}.');
    }
    await target.markOnboardingDone();

    final host = argResults!['host'] as String?;
    if (host != null && host.trim().isNotEmpty) {
      await _registerInZone(
        target,
        host,
        argResults!['zone'] as String?,
        entityId: argResults!['entity'] as String?,
      );
    } else if (target.registration == null) {
      ui.info('Next: `idrt enterprise register <host> [--zone fin]`.');
    } else if (admin) {
      await approveSelfIfPending(target, _plan);
    }
    return CliExit.ok;
  });
}

extension on _Setup {
  /// Org members work through zones: billing says which zones they are
  /// admin or member of, so nothing is asked that is already decided.
  Future<int> _setupInZone(IdrTarget target, CliOrg org) async {
    ({String? entityId, bool owner, List<MyZone> zones})? mine;
    try {
      mine = await myZones(target);
    } catch (_) {
      mine = null; // org without Machine AuthN yet: no zones
    }
    final zones = [...?mine?.zones.where((z) => z.role != null)];
    if (mine == null || zones.isEmpty || mine.entityId == null) {
      // Nothing to do here without a zone; stay personal.
      await target.bindOrganization('me');
      throw CliError(
        CliExit.usage,
        'You are a ${org.role} of ${org.name} with no zone yet.',
        hint:
            'Ask the organization owner (or a zone admin) to add you to a '
            'zone: `idrt` > Organization > Invite people to zones. Then run '
            'this again.',
        code: 'NO_ZONE_ROLE',
      );
    }
    final entityId = mine.entityId!;
    await saveOrg(org, target.session!.email);
    final flag = (argResults!['zone'] as String?)?.trim().toLowerCase();
    final MyZone zone;
    if (flag != null && flag.isNotEmpty) {
      zone = zones.firstWhere(
        (z) => z.zone == flag,
        orElse: () => throw CliError(
          CliExit.usage,
          'You have no role in zone $flag.',
          hint: 'Your zones: ${zones.map((z) => z.zone).join(', ')}.',
          code: 'NO_ZONE_ROLE',
        ),
      );
    } else if (zones.length == 1) {
      zone = zones.single;
    } else {
      zone = ui.choose(
        'You are in several zones of ${org.name}. Which one is this machine for?',
        zones,
        flag: '--zone',
        display: (z) => '${z.zone}  (${z.role})',
      );
    }
    final previous = await loadZoneContext();
    await saveZoneContext((
      zone: zone.zone,
      role: zone.role!,
      entityId: entityId,
    ));
    await target.savePlanSelection(planCode: _plan.planCode);
    if (target.userState.accountPath == null) {
      await target.saveAccountPath('joinTarget');
    }
    await target.saveEnterpriseUiFlags(
      entityRole: 'enrollTarget',
      entityConfirmed: true,
    );
    await target.markOnboardingDone();
    ui.info(
      '${org.name}: you are ${zone.role == 'admin' ? 'an admin' : 'a member'} '
      'of zone ${zone.zone}.',
    );
    if (previous != null &&
        previous.zone != zone.zone &&
        target.registration != null) {
      ui.hint(
        'This machine\'s Target stays registered where it was '
        '(${target.registration!.verifiedFqhn}).',
      );
    }

    // Admins (and members allowed to approve) sign with their own zone key.
    final signs = zone.role == 'admin' || zone.membersApprove;
    final hasKey = signs && await ensureZoneKey(target, zone.zone, entityId);
    if (!signs) {
      ui.info(
        'Zone ${zone.zone}\'s admin approves this machine and the Sources '
        'that use it.',
      );
    }

    final host = argResults!['host'] as String?;
    if (host != null && host.trim().isNotEmpty) {
      await _registerInZone(target, host, zone.zone, entityId: entityId);
    } else if (target.registration == null) {
      ui.info(
        'Next: `idrt enterprise register <host>` (registers into zone '
        '${zone.zone}), or pick it in `idrt`.',
      );
    } else if (hasKey) {
      await approveSelfIfPending(target, _plan);
    }
    return CliExit.ok;
  }
}

/// No `--role`: the org's first machine must be its admin, or nothing could
/// ever approve a Target. Otherwise ask (scripts get a Target).
Future<bool> _firstRole(IdrTarget target, CliOrg org) async {
  bool? rootExists;
  try {
    rootExists = await target.entityRootExists();
  } catch (_) {
    rootExists = null; // unknown: ask
  }
  if (org.role == 'owner' && rootExists == false) {
    ui.info(
      '${org.name} has no admin machine yet, so this machine becomes its '
      'admin (approves devices). It can serve services too.',
    );
    return true;
  }
  if (!ui.interactive) return false;
  return ui.choose(
        'What will this machine do?',
        const ['target', 'admin'],
        flag: '--role',
        display: (r) => r == 'admin'
            ? 'Admin: approve devices and hold the org CA (can serve too)'
            : 'Target: serve services; the admin machine approves it',
      ) ==
      'admin';
}

/// A Target whose org has no admin machine can never be approved: make it
/// the admin instead of starting over.
Future<void> _promoteToAdmin(IdrTarget target, CliOrg org) async {
  final me = target.session!.email.trim().toLowerCase();
  final entity = target.registration?.entityId.trim().toLowerCase() ?? me;
  if (entity != me) {
    throw CliError(
      CliExit.usage,
      'This machine joined $entity; that account\'s admin machine approves '
      'it.',
    );
  }
  if (await target.entityRootExists(entity)) {
    throw CliError(
      CliExit.usage,
      '${org.name} already has an admin machine.',
      hint:
          'Approve this machine there: `idrt` > Pending approvals (or '
          '`idrt enterprise pending`, then `idrt enterprise approve <id>`).',
      code: 'ADMIN_EXISTS',
    );
  }
  await target.saveAccountPath('rootAdmin');
  await target.saveEnterpriseUiFlags(entityRole: 'adminCa');
  ui.info('This machine is now the admin machine for ${org.name}.');
}

/// `idrt enterprise register <host> [--zone fin.apac]`
class _Register extends Command<int> {
  _Register() {
    argParser
      ..addOption('zone', help: 'Zone in the org graph, e.g. fin.apac.')
      ..addOption(
        'entity',
        help:
            'Join the owner entity (the owner sign-in email) instead of '
            'your own. Needed when you are not the org owner.',
      );
  }

  @override
  String get name => 'register';

  @override
  String get description =>
      'Register this machine as a Target: register <host> [--zone …].';

  @override
  Future<int> run() => withTarget((target) async {
    final host = ui.ask(
      'Host name for this machine (e.g. laptop)',
      value: argResults!.rest.firstOrNull,
      flag: '<host>',
    );
    requireMode(target, _plan);
    await requireBilling(target, _plan, allowMembers: true);
    await _registerInZone(
      target,
      host,
      argResults!['zone'] as String?,
      entityId: argResults!['entity'] as String?,
    );
    return CliExit.ok;
  });
}

/// `idrt enterprise org` — org, brand, zones, zone admins, devices.
class _Org extends Command<int> {
  @override
  String get name => 'org';

  @override
  String get description => 'Show the org, its zones, zone admins and devices.';

  @override
  Future<int> run() => withTarget((target) async {
    requireMode(target, _plan);
    final org = await _requireOrg();
    ui.info('org:      ${org.name} (${org.slug}), you are ${org.role}');
    ui.info('brand:    ${target.enterpriseOrg.brandName ?? '-'}');
    ui.info(
      'ca:       ${target.userState.enterpriseCaRole ?? '(target machine)'}',
    );
    // Billing is the record of issued zones; keys live on the root machine.
    Map<String, Map<String, dynamic>>? onBilling;
    try {
      onBilling = {
        for (final z in await target.fetchZoneAuthorities())
          if (z['ski'] is String) z['ski'] as String: z,
      };
    } catch (_) {
      onBilling = null;
    }
    final keysHere = {for (final z in await target.zoneAuthorities()) z.ski};
    ui.info('zones:');
    for (final z in target.enterpriseZones) {
      final admins = target.enterpriseZoneAdmins
          .where((a) => a.zoneLabel == z.pathKey)
          .map((a) => a.email);
      ui.info(
        '  ${z.pathKey.padRight(16)} ${z.displayName}'
        '${admins.isEmpty ? '' : '  admins: ${admins.join(', ')}'}',
      );
      ui.info('    ${_certLine(z, onBilling, keysHere)}');
      final record = onBilling?[z.authoritySki];
      if (record != null) ui.info('    ${_policyLine(record)}');
    }
    ui.info('devices:');
    for (final d in target.enterpriseDevices) {
      ui.info(
        '  ${d.label.padRight(16)} '
        '${d.zonePath.isEmpty ? '(root)' : d.zonePath.join('.')}',
      );
    }
    ui.info(
      '(zone certificates are registered on billing; the zone list and '
      'devices are local to this machine)',
    );
    return CliExit.ok;
  });

  static String _policyLine(Map<String, dynamic> record) {
    final allowed = (record['allowedServices'] as List? ?? const ['*'])
        .map((e) => '$e')
        .toList();
    final version = record['policyVersion'] ?? 1;
    return allowed.contains('*')
        ? 'policy: no policy (all services), v$version'
        : 'policy: allows ${allowed.join(', ')}, v$version';
  }

  static String _certLine(
    EnterpriseZone z,
    Map<String, Map<String, dynamic>>? onBilling,
    Set<String> keysHere,
  ) {
    final ski = z.authoritySki;
    if (ski == null) {
      return 'no certificate (`idrt enterprise zone add ${z.pathKey}` issues one)';
    }
    final issued = z.issuedAt?.toIso8601String().substring(0, 10) ?? '?';
    final billing = onBilling == null
        ? 'billing unreachable'
        : onBilling.containsKey(ski)
        ? 'registered on billing'
        : 'NOT on billing';
    final key = keysHere.contains(ski)
        ? 'key on this machine'
        : 'key elsewhere';
    return 'certificate $ski, issued $issued, $billing, $key';
  }
}

/// `idrt enterprise zone policy <zone> --allow ollama[,lmstudio]`
class _ZonePolicy extends Command<int> {
  _ZonePolicy() {
    argParser.addMultiOption(
      'allow',
      help:
          'Services this zone\'s members may use (comma-separated, or "*" '
          'for all). Replaces the current policy.',
    );
  }

  @override
  String get name => 'policy';

  @override
  String get description =>
      'Set which services a zone\'s members may use: policy <zone> --allow ollama.';

  @override
  Future<int> run() => withTarget((target) async {
    final rest = argResults!.rest;
    if (rest.length > 1) usageException('Expected <zone>.');
    requireAdminMachine(target, _plan);
    if (target.userState.enterpriseCaRole != 'root') {
      throw const CliError(
        CliExit.usage,
        'Only the root CA admin machine signs zone policies.',
      );
    }
    final zone = _pickZone(target, rest.firstOrNull);
    var allow = argResults!['allow'] as List<String>;
    if (allow.isEmpty) {
      allow = [
        for (final s
            in ui
                .ask(
                  'Services members of $zone may use (comma-separated, '
                  '* for all)',
                  flag: '--allow <service>[,…]',
                )
                .split(','))
          if (s.trim().isNotEmpty) s.trim(),
      ];
    }
    final path = _zonePath(zone);
    final ({String zone, List<String> allowedServices, int policyVersion})
    result;
    try {
      result = await target.setZonePolicy(path: path, services: allow);
    } on ArgumentError catch (e) {
      throw CliError(CliExit.usage, '${e.message}');
    }
    ui.info(
      result.allowedServices.contains('*')
          ? 'Zone ${result.zone}: all services (policy v${result.policyVersion}).'
          : 'Zone ${result.zone} may use: '
                '${result.allowedServices.join(', ')} '
                '(policy v${result.policyVersion}).',
    );
    ui.info('Takes effect on members\' next session; nobody re-enrolls.');
    return CliExit.ok;
  });
}

/// `idrt enterprise zone add|invite`
class _Zone extends Command<int> {
  _Zone() {
    addSubcommand(_ZoneList());
    addSubcommand(_ZoneShow());
    addSubcommand(_ZoneAdd());
    addSubcommand(_ZoneInvite());
    addSubcommand(_ZoneSettings());
    addSubcommand(_ZonePolicy());
  }

  @override
  String get name => 'zone';

  @override
  String get description => 'Manage zones (departments) and zone admins.';
}

class _ZoneAdd extends Command<int> {
  _ZoneAdd() {
    argParser.addOption('name', help: 'Display name, e.g. "APAC Finance".');
  }

  @override
  String get name => 'add';

  @override
  String get description =>
      'Add a zone and issue its certificate under the root: add <path> '
      '(e.g. fin or fin.apac).';

  @override
  Future<int> run() => withTarget((target) async {
    final rest = argResults!.rest;
    if (rest.length > 1) usageException('Expected <path>.');
    requireMode(target, _plan);
    final context = await loadZoneContext();
    if (!isAdminMachine(target) && context?.role == 'admin') {
      return _requestSubzone(target, context!, rest.firstOrNull);
    }
    requireAdminMachine(target, _plan);
    if (target.userState.enterpriseCaRole != 'root') {
      throw const CliError(
        CliExit.usage,
        'Only the root CA admin machine issues zone certificates '
        '(`idrt enterprise setup --role admin --ca root`).',
      );
    }
    final path = _zonePath(
      ui.ask(
        'Zone path (e.g. fin, or fin.apac for a sub-zone of fin)',
        value: rest.firstOrNull,
        flag: '<path>',
        validate: (v) =>
            EnterpriseFqhn.parseZonePath(
              v,
            ).every(EnterpriseFqhn.isValidZoneLabel)
            ? null
            : 'Use lowercase letters, digits and -, with dots between levels.',
      ),
    );
    if (path.isEmpty) usageException('Expected <path>.');
    final key = path.join('.');
    if (path.length > 1 &&
        !target.enterpriseZones.any(
          (z) => z.pathKey == path.sublist(0, path.length - 1).join('.'),
        )) {
      throw CliError(
        CliExit.usage,
        'Add the parent zone ${path.sublist(0, path.length - 1).join('.')} first.',
      );
    }
    final existing = target.enterpriseZones
        .where((z) => z.pathKey == key)
        .firstOrNull;
    if (existing?.hasCertificate ?? false) {
      ui.info(
        'Zone $key already has a certificate (${existing!.authoritySki}).',
      );
      return CliExit.ok;
    }
    await requireBilling(target, _plan);
    final name = (argResults!['name'] as String?)?.trim();
    // The SDK records the zone locally only after billing accepts it.
    final zone = await target.createZoneAuthority(
      path: path,
      displayName: name == null || name.isEmpty ? path.last : name,
    );
    ui.info(
      '${existing == null ? 'Zone $key added' : 'Zone $key'} with a '
      'certificate under the root.',
    );
    ui.info('  zone CA SKI: ${zone.authoritySki}');
    if (!ui.interactive) {
      ui.hint(
        'Next: choose its admin: '
        '`idrt enterprise zone invite <email> --zone $key --role admin`.',
      );
      return CliExit.ok;
    }
    final org = await _requireOrg();
    final email = await _askEmail(
      target,
      'Who is the admin of zone $key?',
      later: 'Decide later (you approve its requests here meanwhile)',
    );
    if (email == null) {
      ui.hint('Choose one any time: Zones > $key > Choose the zone admin.');
      return CliExit.ok;
    }
    return _addToZones(target, org, email, [key], 'admin');
  });
}

/// Zone admin: ask the root to sign a sub-zone under one of your zones
/// (allowed only when the owner lets that zone's admins create sub-zones).
Future<int> _requestSubzone(
  IdrTarget target,
  ZoneContext context,
  String? given,
) async {
  final roles = await myZoneRoles(target);
  final mine = [
    for (final e in roles.entries)
      if (e.value == 'admin') e.key,
  ]..sort();
  // <parent.label>, or <parent> (label asked), or nothing (both asked).
  final full = given != null && given.contains('.');
  final parent = full
      ? given.substring(0, given.lastIndexOf('.'))
      : given ??
            (mine.length == 1
                ? mine.single
                : ui.choose(
                    'Create a sub-zone under which of your zones?',
                    mine,
                    flag: '<parent.label>',
                  ));
  final label = full
      ? given.substring(given.lastIndexOf('.') + 1)
      : ui.ask(
          'Sub-zone label under $parent (e.g. apac)',
          flag: '<parent.label>',
          validate: (v) => EnterpriseFqhn.isValidZoneLabel(v)
              ? null
              : 'Use lowercase letters, digits and -.',
        );
  final path = _zonePath('$parent.$label').join('.');
  if (roles[parent] != 'admin') {
    throw CliError(
      CliExit.usage,
      'You are not an admin of zone $parent.',
      code: 'ZONE_ROLE_REQUIRED',
    );
  }
  try {
    await ensureZoneKey(target, path, context.entityId);
  } on StateError catch (e) {
    if ('$e'.contains('SUBZONE_FORBIDDEN')) {
      throw CliError(
        CliExit.auth,
        'The organization owner has not allowed sub-zones under $parent.',
        hint:
            'Ask them to turn it on: `idrt enterprise zone settings $parent '
            '--subzones` on the root machine.',
        code: 'SUBZONE_FORBIDDEN',
      );
    }
    rethrow;
  }
  ui.info('You become the admin of $path once the root admin signs it.');
  return CliExit.ok;
}

/// `idrt enterprise zone invite [<email>] [--zone a,b] [--role admin|member]`
/// Adds people to zones (billing). The first person in a zone becomes its
/// admin; later ones are members. Not in the org yet: invited as a member.
class _ZoneInvite extends Command<int> {
  _ZoneInvite() {
    argParser
      ..addMultiOption(
        'zone',
        help: 'Zone(s), comma-separated. Asked when omitted.',
      )
      ..addOption(
        'role',
        allowed: ['admin', 'member'],
        help:
            'Default: admin when the zone has no admin yet, else member. '
            'Only the organization owner makes admins.',
      );
  }

  @override
  String get name => 'invite';

  @override
  String get description =>
      'Add someone to one or more zones: invite <email> [--zone fin,legal].';

  @override
  String get invocation =>
      'idrt enterprise zone invite <email> [--zone <zone>[,…]] [--role admin|member]';

  @override
  Future<int> run() => withTarget((target) async {
    var rest = argResults!.rest;
    if (rest.length > 2) usageException('Expected <email>.');
    requireMode(target, _plan);
    final org = await _requireOrg();
    var zones = [
      for (final z in argResults!['zone'] as List<String>)
        _zonePath(z).join('.'),
    ];
    // Old form: invite <zone> <email>.
    if (rest.length == 2 && !rest.first.contains('@')) {
      zones = [...zones, _zonePath(rest.first).join('.')];
      rest = rest.sublist(1);
    }
    final role = argResults!['role'] as String?;
    final email =
        rest.firstOrNull?.trim().toLowerCase() ??
        await _askEmail(
          target,
          role == 'admin' ? 'Who should be the zone admin?' : 'Who to add?',
        );
    if (email == null) return CliExit.ok;
    if (zones.isEmpty) zones = await _pickManagedZones(target, org);
    return _addToZones(target, org, email, zones, role);
  });
}

/// Picks a person: an org member from the list, or a typed email. With
/// [later], also offers to skip (returns null).
Future<String?> _askEmail(
  IdrTarget target,
  String question, {
  String? later,
}) async {
  const typed = '', skip = '-'; // never an email
  var known = const <String>[];
  if (ui.interactive) {
    try {
      known = [
        for (final m in await target.listOrganizationMembers())
          if ((m.email ?? '').isNotEmpty) m.email!.toLowerCase(),
      ]..remove(target.session!.email.toLowerCase());
    } on IdrTargetException {
      // Not allowed to list members: type the email.
    }
  }
  final picked = known.isEmpty && later == null
      ? typed
      : ui.choose<String>(
          question,
          [...known, typed, if (later != null) skip],
          flag: '<email>',
          display: (v) => v == typed
              ? 'Someone else (type their email)'
              : v == skip
              ? later!
              : v,
        );
  if (picked == skip) return null;
  if (picked != typed) return picked;
  return ui
      .ask(
        'Their email',
        flag: '<email>',
        validate: (v) => v.contains('@') ? null : 'Expected an email.',
      )
      .trim()
      .toLowerCase();
}

/// Gives [email] [role] (null: keep theirs, else first one is admin) in
/// [zones], invites them to the org if needed, and says what they run next.
Future<int> _addToZones(
  IdrTarget target,
  CliOrg org,
  String email,
  List<String> zones,
  String? role,
) async {
  if (role == 'member' && ui.interactive) {
    final current = {
      for (final z in await target.fetchZoneAuthorities())
        z['zone']: (z['roles'] as Map?)?[email],
    };
    zones = [
      for (final zone in zones)
        if (current[zone] != 'admin' ||
            ui.confirm(
              '$email is an admin of $zone. Make them a member instead?',
            ))
          zone,
    ];
    if (zones.isEmpty) return CliExit.ok;
  }
  final results = <Map<String, Object?>>[];
  for (final zone in zones) {
    try {
      final r = await target.setZoneRole(zone: zone, email: email, role: role);
      results.add({'zone': zone, 'role': r['role']});
    } on StateError catch (e) {
      throw _zoneRoleError(e, zone);
    }
  }
  final orgInvite = await _ensureInOrg(target, org, email);
  ui.result(
    {'email': email, 'zones': results, 'orgInvite': orgInvite},
    human: () {
      for (final r in results) {
        ui.success('$email is now ${r['role']} of zone ${r['zone']}.');
      }
      switch (orgInvite) {
        case 'invited':
          ui.info('Invited $email to ${org.name} as a member.');
        case 'owner-needed':
          // Billing lets a zone role in when they first pick the org.
          ui.info(
            '$email joins ${org.name} as a member when they sign in and '
            'pick ${org.slug} (their zone role lets them in).',
          );
      }
      ui.info('');
      ui.info('Tell them to run, on their machine:');
      ui.info('  idrt login           (as $email)');
      ui.info('  idrt enterprise setup --org ${org.slug}');
      ui.hint(
        'Setup finds their zone(s) and role by itself'
        '${results.any((r) => r['role'] == 'admin') ? '; as an admin they then ask you to sign their zone key (Pending approvals here)' : ''}.',
      );
    },
  );
  return CliExit.ok;
}

/// Zones the signed-in user may add people to: all (owner) or the ones
/// they are admin of.
Future<List<String>> _pickManagedZones(IdrTarget target, CliOrg org) async {
  final all = await _billingZones(target) ?? const <String>[];
  final roles = org.role == 'owner' ? null : await myZoneRoles(target);
  final managed = [
    for (final z in all)
      if (roles == null || roles[z] == 'admin') z,
  ];
  if (managed.isEmpty) {
    throw CliError(
      CliExit.usage,
      org.role == 'owner'
          ? '${org.name} has no zones yet.'
          : 'You are not an admin of any zone.',
      hint: org.role == 'owner'
          ? 'Create one first: `idrt enterprise zone add <name>`.'
          : 'The organization owner or a zone admin adds people.',
      code: 'NO_ZONES',
    );
  }
  if (managed.length == 1) return managed;
  final picked = ui.chooseMany(
    'Add them to which zones? (space selects, enter confirms)',
    managed,
    flag: '--zone',
  );
  if (picked.isEmpty) {
    throw const CliError(CliExit.usage, 'No zone picked.', code: 'NO_ZONE');
  }
  return picked;
}

CliError _zoneRoleError(StateError e, String zone) {
  final text = '$e';
  if (text.contains('OWNER_REQUIRED')) {
    return const CliError(
      CliExit.auth,
      'Only the organization owner makes or removes zone admins.',
      hint: 'You can add members: leave out --role admin.',
      code: 'OWNER_REQUIRED',
    );
  }
  if (text.contains('ZONE_ADMIN_REQUIRED')) {
    return CliError(
      CliExit.auth,
      'Only the organization owner or an admin of $zone adds people to it.',
      code: 'ZONE_ADMIN_REQUIRED',
    );
  }
  if (text.contains('(404)')) {
    return CliError(
      CliExit.usage,
      'Zone $zone does not exist.',
      hint: 'See `idrt enterprise zone list`.',
      code: 'NO_SUCH_ZONE',
    );
  }
  return CliError(CliExit.failure, text);
}

/// `member`/`invited`/`owner-needed`: whether [email] is (now) in the org.
Future<String> _ensureInOrg(IdrTarget target, CliOrg org, String email) async {
  try {
    final members = await target.listOrganizationMembers();
    if (members.any((m) => (m.email ?? '').toLowerCase() == email)) {
      return 'member';
    }
    final invites = await target.listOrganizationInvitations();
    if (invites.any(
      (i) => i.status == 'pending' && i.email.toLowerCase() == email,
    )) {
      return 'member';
    }
  } on IdrTargetException {
    // Members may not list; inviting below says what billing allows.
  }
  if (!canBill(org.role)) return 'owner-needed';
  await target.inviteOrganizationMember(email: email, role: 'member');
  return 'invited';
}

/// `idrt enterprise zone settings <zone> [--members-approve] [--subzones]`
class _ZoneSettings extends Command<int> {
  _ZoneSettings() {
    argParser
      ..addFlag(
        'members-approve',
        defaultsTo: null,
        help:
            'Members may approve Sources that enroll for their own Target '
            '(else only zone admins). Owner or zone admin.',
      )
      ..addFlag(
        'subzones',
        defaultsTo: null,
        help: 'Zone admins may create sub-zones. Owner only.',
      );
  }

  @override
  String get name => 'settings';

  @override
  String get description =>
      'Who approves in a zone, and whether its admins create sub-zones.';

  @override
  String get invocation =>
      'idrt enterprise zone settings [<zone>] [--[no-]members-approve] '
      '[--[no-]subzones]';

  @override
  Future<int> run() => withTarget((target) async {
    final rest = argResults!.rest;
    if (rest.length > 1) usageException('Expected <zone>.');
    requireMode(target, _plan);
    final org = await _requireOrg();
    final owner = org.role == 'owner';
    final roles = owner ? const <String, String>{} : await myZoneRoles(target);
    final all = await _billingZones(target) ?? const <String>[];
    final managed = [
      for (final z in all)
        if (owner || roles[z] == 'admin') z,
    ];
    final zone = rest.isNotEmpty
        ? _zonePath(rest.single).join('.')
        : managed.isEmpty
        ? throw const CliError(
            CliExit.usage,
            'You manage no zones.',
            code: 'NO_ZONES',
          )
        : managed.length == 1
        ? managed.single
        : ui.choose('Which zone?', managed, flag: '<zone>');
    final current = (await target.fetchZoneAuthorities())
        .where((z) => z['zone'] == zone)
        .firstOrNull;
    var membersApprove = argResults!['members-approve'] as bool?;
    var subzones = argResults!['subzones'] as bool?;
    if (membersApprove == null && subzones == null) {
      membersApprove = ui.confirm(
        'Let members of $zone approve Sources for their own Target? '
        '(No: only zone admins approve)',
        defaultValue: current?['membersApprove'] == true,
      );
      if (owner) {
        subzones = ui.confirm(
          'Let admins of $zone create sub-zones?',
          defaultValue: current?['adminsCreateSubzones'] == true,
        );
      }
    }
    final Map<String, dynamic> r;
    try {
      r = await target.setZoneSettings(
        zone: zone,
        membersApprove: membersApprove,
        adminsCreateSubzones: subzones,
      );
    } on StateError catch (e) {
      throw _zoneRoleError(e, zone);
    }
    ui.result(
      r,
      human: () {
        ui.info(
          'Zone $zone: '
          '${r['membersApprove'] == true ? 'members approve Sources for their own Target' : 'only zone admins approve'}; '
          'sub-zones ${r['adminsCreateSubzones'] == true ? 'allowed' : 'not allowed'} for its admins.',
        );
      },
    );
    return CliExit.ok;
  });
}

/// `idrt enterprise zone list`
class _ZoneList extends Command<int> {
  @override
  String get name => 'list';

  @override
  String get description =>
      'Zones with their certificate, policy, admins and devices.';

  @override
  Future<int> run() => withTarget((target) async {
    requireMode(target, _plan);
    await _requireOrg();
    final zones = await zoneRecords(target);
    ui.result(
      zones,
      human: () {
        if (zones.isEmpty) {
          ui.info('No zones yet.');
          ui.hint(
            'Create one on the root CA admin machine: '
            '`idrt enterprise zone add <name>`.',
          );
          return;
        }
        ui.table(
          ['zone', 'name', 'certificate', 'policy', 'admins', 'members'],
          [
            for (final z in zones)
              [
                z['path'],
                z['name'] ?? '(issued elsewhere)',
                _certText(z),
                _policyText(z),
                (z['admins'] as List).length,
                (z['members'] as List?)?.length ?? 'owner only',
              ],
          ],
        );
      },
    );
    return CliExit.ok;
  });
}

/// `idrt enterprise zone show [<zone>]`
class _ZoneShow extends Command<int> {
  @override
  String get name => 'show';

  @override
  String get description =>
      'One zone: parent, certificate, policy, zone admins and devices.';

  @override
  Future<int> run() => withTarget((target) async {
    final rest = argResults!.rest;
    if (rest.length > 1) usageException('Expected <zone>.');
    requireMode(target, _plan);
    await _requireOrg();
    final zones = await zoneRecords(target);
    final key = rest.isEmpty
        ? _pickZone(target, null)
        : _zonePath(rest.single).join('.');
    final z = zones.where((z) => z['path'] == key).firstOrNull;
    if (z == null) {
      throw CliError(
        CliExit.usage,
        'Unknown zone $key.',
        hint: 'See `idrt enterprise zone list`.',
        code: 'NO_SUCH_ZONE',
      );
    }
    ui.result(
      z,
      human: () {
        final admins = z['admins'] as List;
        final devices = z['devices'] as List;
        final members = z['members'] as List?;
        ui.fields({
          'zone': z['path'],
          'name': z['name'] ?? '(issued from another admin machine)',
          'parent': z['parent'] ?? '(top level)',
          'certificate': z['certificate'] == null
              ? 'none: `idrt enterprise zone add $key` issues one'
              : '${z['certificate']}, issued ${z['issuedAt'] ?? '?'}, '
                    '${_certText(z)}, key '
                    '${z['keyOnThisMachine'] == true ? 'on this machine' : 'elsewhere'}',
          'policy': _policyText(z),
          'zone admins': admins.isEmpty ? '(none)' : admins.join(', '),
          'recorded here': devices.isEmpty
              ? '(no devices recorded on this machine)'
              : devices.join(', '),
          'members': members == null
              ? 'only the organization owner can list them (billing)'
              : members.isEmpty
              ? '(no devices issued under this zone)'
              : '${members.length}',
        });
        if (members != null && members.isNotEmpty) {
          ui.info('');
          ui.table(
            ['host', 'kind', 'status', 'ski'],
            [
              for (final m in members.cast<Map>())
                [m['host'], m['kind'], m['status'], m['ski']],
            ],
          );
        }
      },
    );
    return CliExit.ok;
  });
}

/// `idrt enterprise devices` — billing's record of issued credentials.
class _Devices extends Command<int> {
  @override
  String get name => 'devices';

  @override
  String get description =>
      'Every device credential billing issued for the org (owner only).';

  @override
  Future<int> run() => withTarget((target) async {
    requireMode(target, _plan);
    final org = await _requireOrg();
    final List<Map<String, dynamic>> devices;
    try {
      devices = await target.listCredentials();
    } on StateError catch (e) {
      // Billing decides who may list; say what that means here.
      if ('$e'.contains('(403)')) {
        throw CliError(
          CliExit.auth,
          'Billing lists devices only for the organization owner '
          '(you are ${org.role} of ${org.name}).',
          hint:
              'Ask an owner, or `idrt enterprise members role <email> admin`.',
          code: 'FORBIDDEN',
        );
      }
      if ('$e'.contains('NOT_REGISTERED')) {
        throw CliError(
          CliExit.failure,
          '${org.name} has no machines registered with billing yet.',
          hint:
              'Finish setup on the admin machine (`idrt enterprise '
              'setup --org ${org.slug} --role admin`); approved devices '
              'appear here.',
          code: 'NOT_REGISTERED',
        );
      }
      rethrow;
    }
    final zoned = devices.any((d) => d.containsKey('zone'));
    ui.result(
      devices,
      human: () {
        if (devices.isEmpty) {
          ui.info('No devices yet. Approved Targets and Sources appear here.');
          return;
        }
        ui.table(
          ['host', 'kind', 'status', if (zoned) 'zone', 'ski'],
          [
            for (final d in devices)
              [
                d['host'],
                d['kind'],
                d['status'],
                if (zoned) d['zone'] ?? '(root)',
                d['ski'],
              ],
          ],
        );
        ui.hint('Revoke one: `idrt enterprise revoke <ski>`.');
      },
    );
    return CliExit.ok;
  });
}

/// `idrt enterprise members [invite|role|remove …]` — no browser.
/// One command so a bare `members` lists (args would print usage if we nested).
class _Members extends Command<int> {
  _Members() {
    argParser.addOption(
      'role',
      allowed: _memberRoles,
      help: 'admin or member (invite). Default member.',
    );
  }

  @override
  String get name => 'members';

  @override
  String get description =>
      'List org users, or invite / set role / remove (no browser).';

  @override
  String get invocation =>
      'idrt enterprise members [invite <email>|role <email> <role>|remove <email>]';

  @override
  Future<int> run() => withTarget((target) async {
    requireMode(target, _plan);
    requireSession(target);
    final org = await _requireOrg();
    final rest = argResults!.rest;
    final verb = rest.firstOrNull?.toLowerCase();
    if (verb == 'invite') {
      return _invite(target, org, rest.skip(1).toList());
    }
    if (verb == 'role') {
      return _setRole(target, org, rest.skip(1).toList());
    }
    if (verb == 'remove') {
      return _remove(target, org, rest.skip(1).toList());
    }
    if (verb != null) {
      usageException('Unknown members action "$verb".');
    }
    return _list(target);
  });

  Future<int> _list(IdrTarget target) async {
    final members = await target.listOrganizationMembers();
    var invites = <OrgInvitation>[];
    try {
      invites = await target.listOrganizationInvitations();
    } on IdrTargetException {
      // Roster still useful if invitations are forbidden.
    }
    final pending = invites.where((i) => i.status == 'pending').toList();
    ui.result(
      {
        'members': [
          for (final m in members)
            {'id': m.id, 'email': m.email, 'name': m.name, 'role': m.role},
        ],
        'invitations': [
          for (final i in pending)
            {'id': i.id, 'email': i.email, 'role': i.role, 'status': i.status},
        ],
      },
      human: () {
        if (members.isEmpty) {
          ui.info('No members returned.');
        } else {
          ui.table(
            ['email', 'role', 'name'],
            [
              for (final m in members) [m.email ?? m.id, m.role, m.name ?? ''],
            ],
          );
        }
        if (pending.isNotEmpty) {
          ui.info('Pending invitations:');
          ui.table(
            ['email', 'role'],
            [
              for (final i in pending) [i.email, i.role],
            ],
          );
        }
        ui.hint(
          'Invite: `idrt enterprise members invite <email> [--role member]`.',
        );
      },
    );
    return CliExit.ok;
  }

  Future<int> _invite(IdrTarget target, CliOrg org, List<String> rest) async {
    _requireManager(org, 'invite');
    final email = ui.ask(
      'Email to invite',
      value: rest.firstOrNull,
      flag: '<email>',
      validate: (v) => v.contains('@') ? null : 'Expected an email.',
    );
    final role = _memberRole(argResults!['role'] as String? ?? 'member');
    await target.inviteOrganizationMember(email: email, role: role);
    ui.info('Invited $email as $role.');
    ui.hint(
      role == 'admin'
          ? 'An org admin manages the whole organization. To give someone '
                'one zone only, use `idrt enterprise zone invite $email`.'
          : 'Give them a zone: `idrt enterprise zone invite $email`.',
    );
    return CliExit.ok;
  }

  Future<int> _setRole(IdrTarget target, CliOrg org, List<String> rest) async {
    _requireManager(org, 'change roles');
    if (rest.length > 2) usageException('Expected <email> <role>.');
    final email = ui.ask(
      'Member email',
      value: rest.firstOrNull,
      flag: '<email>',
      validate: (v) => v.contains('@') ? null : 'Expected an email.',
    );
    final role = _memberRole(
      rest.length > 1
          ? rest[1]
          : ui.ask('Role (admin or member)', flag: '<role>'),
    );
    final member = await _memberByEmail(target, email);
    await target.updateOrganizationMemberRole(memberId: member.id, role: role);
    ui.info('$email is now $role.');
    return CliExit.ok;
  }

  Future<int> _remove(IdrTarget target, CliOrg org, List<String> rest) async {
    _requireManager(org, 'remove members');
    final email = ui.ask(
      'Email to remove',
      value: rest.firstOrNull,
      flag: '<email>',
      validate: (v) => v.contains('@') ? null : 'Expected an email.',
    );
    try {
      await target.removeOrganizationMember(memberIdOrEmail: email);
    } on IdrTargetException {
      await _explainPendingInvite(target, email);
      rethrow;
    }
    ui.info('Removed $email.');
    return CliExit.ok;
  }

  void _requireManager(CliOrg org, String action) {
    if (!canBill(org.role)) {
      throw CliError(
        CliExit.auth,
        'Only an owner or admin can $action (you are ${org.role}).',
      );
    }
  }
}

const _memberRoles = ['admin', 'member'];

String _memberRole(String? raw) {
  final r = (raw ?? 'member').trim().toLowerCase();
  if (!_memberRoles.contains(r)) {
    throw CliError(CliExit.usage, 'Role must be admin or member (not owner).');
  }
  return r;
}

Future<OrgMember> _memberByEmail(IdrTarget target, String email) async {
  final want = email.trim().toLowerCase();
  final members = await target.listOrganizationMembers();
  final hit = members.where((m) => (m.email ?? '').toLowerCase() == want);
  if (hit.isEmpty) {
    await _explainPendingInvite(target, email);
    throw CliError(CliExit.usage, 'No member with email $email.');
  }
  return hit.first;
}

/// A pending invitee is not a member yet: say so instead of "not found".
Future<void> _explainPendingInvite(IdrTarget target, String email) async {
  final want = email.trim().toLowerCase();
  try {
    final pending = (await target.listOrganizationInvitations()).any(
      (i) => i.status == 'pending' && i.email.toLowerCase() == want,
    );
    if (pending) {
      throw CliError(
        CliExit.usage,
        '$email has a pending invitation and is not a member yet.',
        hint:
            'Roles and removal apply after they accept. The invited role '
            'cannot be changed from the CLI; cancel it in the billing portal.',
        code: 'INVITE_PENDING',
      );
    }
  } on IdrTargetException {
    // Fall through to the caller's own error.
  }
}

/// `idrt enterprise revoke <ski|zone> [--reason r]`
/// `idrt enterprise block <source> [--target <fqhn>] [--undo]`
class _Block extends Command<int> {
  _Block() {
    argParser
      ..addOption('target', help: 'Target FQHN. Default: this machine.')
      ..addFlag('undo', negatable: false, help: 'Unblock instead.');
  }

  @override
  String get name => 'block';

  @override
  String get description =>
      'Stop one Source using one Target (it keeps the other Targets of its '
      'zone): block <source-ski-or-host>. Owner or that zone\'s admin.';

  @override
  String get invocation =>
      'idrt enterprise block <source> [--target <fqhn>] [--undo]';

  @override
  Future<int> run() => withTarget((target) async {
    final rest = argResults!.rest;
    if (rest.length != 1) usageException('Expected <source>.');
    requireMode(target, _plan);
    final fqhn =
        (argResults!['target'] as String?) ??
        target.registration?.verifiedFqhn ??
        (throw const CliError(
          CliExit.usage,
          'This machine is not a Target; name one with --target <fqhn>.',
        ));
    final undo = argResults!['undo'] as bool;
    final Map<String, dynamic> r;
    try {
      r = await target.setTargetBlock(
        target: fqhn,
        source: rest.single,
        blocked: !undo,
      );
    } on StateError catch (e) {
      throw _zoneRoleError(e, fqhn);
    }
    ui.result(
      r,
      human: () => ui.success(
        undo
            ? '${r['source']} may use ${r['target']} again.'
            : '${r['source']} can no longer use ${r['target']} '
                  '(its other Targets are unchanged).',
      ),
    );
    return CliExit.ok;
  });
}

class _Revoke extends Command<int> {
  _Revoke() {
    argParser.addOption(
      'reason',
      help: 'Recorded on billing (default: other).',
    );
  }

  @override
  String get name => 'revoke';

  @override
  String get description =>
      'Revoke a zone\'s certificate (revoke zone-b) or one credential by SKI '
      '(member, Target). Org owner only.';

  @override
  String get invocation => 'idrt enterprise revoke <ski|zone> [--reason r]';

  @override
  Future<int> run() => withTarget((target) async {
    final rest = argResults!.rest;
    if (rest.length != 1) usageException('Expected <ski|zone>.');
    requireMode(target, _plan);
    await _requireOrg();
    final arg = rest.single.trim();
    final reason = argResults!['reason'] as String?;
    final zone = await _isZone(target, arg);
    try {
      final r = zone
          ? await target.revokeZone(_zonePath(arg), reason: reason)
          : await target.revokeCredential(arg, reason: reason);
      ui.info(
        zone
            ? 'Revoked zone $arg (certificate ${r.ski}, reason ${r.reason}). '
                  'Its members are denied from their next session.'
            : 'Revoked ${r.ski} (reason ${r.reason}). '
                  'It is denied from its next session.',
      );
    } on ArgumentError catch (e) {
      throw CliError(CliExit.usage, '${e.message}');
    }
    return CliExit.ok;
  });

  /// A zone name known locally or on billing; anything else is a SKI.
  static Future<bool> _isZone(IdrTarget target, String arg) async {
    if (target.enterpriseZones.any((z) => z.pathKey == arg)) return true;
    try {
      return (await target.fetchZoneAuthorities()).any((z) => z['zone'] == arg);
    } catch (_) {
      return false;
    }
  }
}
