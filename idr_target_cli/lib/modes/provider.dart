import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';

import '../core/billing.dart';
import '../core/devices.dart';
import '../core/domains.dart';
import '../core/target.dart';

/// Service Provider mode: a provider runs Targets for customer tenants.
///
/// - Billing is per Target seat (`idr_sp_target`). Each tenant is billed to
///   its own org (the provider is owner/admin there and buys on its behalf)
///   or, by default, to the provider's org.
/// - A machine serves one tenant; its session is bound to that tenant's
///   billing org, so seat checks and checkout links are that tenant's.
/// - SP has no admin machine: any provider machine reviews enrollments.
/// - The tenant list is local to this machine (no server tenant API yet).
const _plan = IdrBusinessPlan.serviceProvider;

class ProviderCommand extends Command<int> {
  ProviderCommand() {
    addSubcommand(_Setup());
    addSubcommand(_TenantCommand());
    addSubcommand(_Register());
    addSubcommand(_Billing());
    addSubcommand(DomainCommand(_plan));
    addSubcommand(PendingCommand(_plan, adminOnly: false));
    addSubcommand(DecideCommand(_plan, approve: true, adminOnly: false));
    addSubcommand(DecideCommand(_plan, approve: false, adminOnly: false));
  }

  @override
  String get name => 'provider';

  @override
  String get description =>
      'Service Provider mode: run Targets for customer tenants.';
}

// --- Local provider config ----------------------------------------------------

typedef _Tenant = ({String id, String name, String? org});

typedef _Provider = ({
  String org,
  String orgName,
  List<_Tenant> tenants,
  String? machineTenant,
});

const _key = 'idrt.provider';

Future<_Provider?> _load() async {
  final j = await cliStore.readJson(_key);
  if (j == null) return null;
  return (
    org: j['org'] as String,
    orgName: j['orgName'] as String? ?? j['org'] as String,
    tenants: [
      for (final t in (j['tenants'] as List? ?? const []).cast<Map>())
        (
          id: t['id'] as String,
          name: t['name'] as String,
          org: t['org'] as String?
        ),
    ],
    machineTenant: j['machineTenant'] as String?,
  );
}

Future<void> _save(_Provider p) => cliStore.writeJson(_key, {
      'org': p.org,
      'orgName': p.orgName,
      'tenants': [
        for (final t in p.tenants) {'id': t.id, 'name': t.name, 'org': t.org},
      ],
      'machineTenant': p.machineTenant,
    });

/// Tenant ids saved on this machine (for the menu).
Future<List<String>> tenantIds() async =>
    [for (final t in (await _load())?.tenants ?? const <_Tenant>[]) t.id];

Future<_Provider> _requireProvider(IdrTarget target) async {
  requireMode(target, _plan);
  final p = await _load();
  if (p == null) {
    throw const CliError(
      CliExit.usage,
      'Run `idrt provider setup --org <your-org>` first.',
    );
  }
  return p;
}

_Tenant _findTenant(_Provider p, String id) {
  for (final t in p.tenants) {
    if (t.id == id) return t;
  }
  throw CliError(
    CliExit.usage,
    'Unknown tenant $id. Add it with `idrt provider tenant add $id`.',
  );
}

/// Org that pays for [t]'s Targets.
String _billingOrg(_Provider p, _Tenant t) => t.org ?? p.org;

/// Bind to [slug] and require owner/admin there; on failure bind back to
/// [fallback] so the machine keeps a usable billing context.
Future<CliOrg> _bindBilling(
  IdrTarget target,
  String slug, {
  required String fallback,
}) async {
  final org = await target.bindOrganization(slug);
  if (!canBill(org.role)) {
    await target.bindOrganization(fallback);
    throw CliError(
      CliExit.usage,
      'You are a ${org.role} of ${org.name}; a provider needs owner or admin '
      'there to buy seats and register Targets.',
    );
  }
  return org;
}

/// The bound org's active subscription must be SP (or none yet).
void _requireNoOtherPlan(IdrTarget target, String orgName) {
  final paid = target.userState.hasActivePlan ? currentPlan(target) : null;
  if (paid != null && paid != _plan) {
    throw CliError(
      CliExit.usage,
      '$orgName has an active ${paid.title} subscription, not Service Provider.',
    );
  }
}

// --- Commands -----------------------------------------------------------------

/// `idrt provider setup --org <provider-slug>`
class _Setup extends Command<int> {
  _Setup() {
    argParser.addOption(
      'org',
      help: 'Your provider organization slug (default payer for tenants).',
    );
  }

  @override
  String get name => 'setup';

  @override
  String get description =>
      'Choose Service Provider mode and bind your provider organization.';

  @override
  Future<int> run() => withTarget((target) async {
        requireSession(target);
        final existing = await _load();
        final slug = ui.ask(
          'Organization slug (from the billing portal)',
          value: (argResults!['org'] as String?) ?? existing?.org,
          flag: '--org <slug>',
          validate: orgSlugProblem,
        );
        final org = await _bindBilling(target, slug, fallback: 'me');
        _requireNoOtherPlan(target, org.name);
        await saveOrg(org, target.session!.email);
        await _save((
          org: org.slug,
          orgName: org.name,
          tenants: existing?.tenants ?? const [],
          machineTenant: existing?.machineTenant,
        ));

        // SP machines are Targets only (no admin path in the SDK).
        await target.savePlanSelection(planCode: _plan.planCode);
        if (target.userState.accountPath == null) {
          await target.saveAccountPath('joinTarget');
          await target.saveEnterpriseUiFlags(entityRole: 'enrollTarget');
        }
        await target.markOnboardingDone();

        ui.info(
            'Service Provider: ${org.name} (${org.slug}), you are ${org.role}.');
        ui.info(
          'Next: `idrt provider tenant add <id> [--org <customer-org>]`, then '
          '`idrt provider register <host> --tenant <id>`.',
        );
        return CliExit.ok;
      });
}

/// `idrt provider tenant add|list|remove`
class _TenantCommand extends Command<int> {
  _TenantCommand() {
    addSubcommand(_TenantAdd());
    addSubcommand(_TenantList());
    addSubcommand(_TenantRemove());
  }

  @override
  String get name => 'tenant';

  @override
  String get description => 'Manage the customer tenants you run Targets for.';
}

class _TenantAdd extends Command<int> {
  _TenantAdd() {
    argParser
      ..addOption('name', help: 'Display name (default: id).')
      ..addOption(
        'org',
        help: 'Customer org that pays for this tenant\'s Targets '
            '(you must be its owner/admin). Default: your provider org.',
      );
  }

  @override
  String get name => 'add';

  @override
  String get description => 'Add a tenant: add <id> [--name …] [--org …].';

  @override
  Future<int> run() => withTarget((target) async {
        final rest = argResults!.rest;
        if (rest.length > 1) usageException('Expected <id>.');
        final p = await _requireProvider(target);
        final id = ui
            .ask('Tenant id (e.g. acme)',
                value: rest.firstOrNull,
                flag: '<id>',
                validate: (v) => EnterpriseFqhn.isValidZoneLabel(v.toLowerCase())
                    ? null
                    : 'Tenant id must be lowercase letters, digits and -.')
            .toLowerCase();
        if (p.tenants.any((t) => t.id == id)) {
          throw CliError(CliExit.usage, 'Tenant $id already exists.');
        }
        final orgFlag = (argResults!['org'] as String?)?.trim();
        String? org;
        if (orgFlag != null && orgFlag.isNotEmpty && orgFlag != p.org) {
          // Verify the provider can bill there, then restore this machine's org.
          final current = (await loadOrg())?.slug ?? p.org;
          final bound = await _bindBilling(target, orgFlag, fallback: current);
          await target.bindOrganization(current);
          org = bound.slug;
        }
        final name = (argResults!['name'] as String?)?.trim();
        await _save((
          org: p.org,
          orgName: p.orgName,
          tenants: [
            ...p.tenants,
            (id: id, name: name == null || name.isEmpty ? id : name, org: org),
          ],
          machineTenant: p.machineTenant,
        ));
        ui.info(
          'Tenant $id added, billed to ${org ?? '${p.orgName} (provider)'}.',
        );
        return CliExit.ok;
      });
}

class _TenantList extends Command<int> {
  @override
  String get name => 'list';

  @override
  String get description => 'List tenants and who pays for them.';

  @override
  Future<int> run() => withTarget((target) async {
        final p = await _requireProvider(target);
        bool here(t) => t.id == p.machineTenant && target.registration != null;
        ui.result(
          {
            'provider': p.org,
            'tenants': [
              for (final t in p.tenants)
                {
                  'id': t.id,
                  'name': t.name,
                  'billedTo': t.org ?? p.org,
                  'thisMachine': here(t),
                },
            ],
          },
          human: () {
            ui.info('provider: ${p.orgName} (${p.org})');
            if (p.tenants.isEmpty) ui.info('No tenants yet.');
            for (final t in p.tenants) {
              ui.info(
                '  ${t.id.padRight(16)} ${t.name.padRight(20)} '
                'billed to ${t.org ?? '${p.org} (provider)'}'
                '${here(t) ? '  ← this machine' : ''}',
              );
            }
          },
        );
        return CliExit.ok;
      });
}

class _TenantRemove extends Command<int> {
  @override
  String get name => 'remove';

  @override
  String get description => 'Remove a tenant from the list: remove <id>.';

  @override
  Future<int> run() => withTarget((target) async {
        final rest = argResults!.rest;
        if (rest.length != 1) usageException('Expected <id>.');
        final p = await _requireProvider(target);
        final t = _findTenant(p, rest.single);
        if (t.id == p.machineTenant && target.registration != null) {
          throw const CliError(
            CliExit.usage,
            'This machine serves that tenant. Run `idrt logout` first.',
          );
        }
        await _save((
          org: p.org,
          orgName: p.orgName,
          tenants: [...p.tenants.where((x) => x.id != t.id)],
          machineTenant: p.machineTenant,
        ));
        ui
            .info('Tenant ${t.id} removed (its seats stay in the portal).');
        return CliExit.ok;
      });
}

/// `idrt provider register <host> --tenant <id>`
class _Register extends Command<int> {
  _Register() {
    argParser
      ..addOption('tenant', help: 'Tenant this Target serves (asked if omitted).')
      ..addFlag(
        'open',
        defaultsTo: true,
        help: 'Open the billing portal if a seat is needed.',
      );
  }

  @override
  String get name => 'register';

  @override
  String get description =>
      'Register this machine as a Target for a tenant: register <host> --tenant <id>.';

  @override
  Future<int> run() => withTarget((target) async {
        final p = await _requireProvider(target);
        final host = ui.ask('Host name for this machine (e.g. laptop)',
            value: argResults!.rest.firstOrNull, flag: '<host>');
        final t = _findTenant(
          p,
          (argResults!['tenant'] as String?) ??
              ui
                  .choose('Which tenant does this machine serve?', p.tenants,
                      flag: '--tenant <id>', display: (t) => '${t.id} (${t.name})')
                  .id,
        );
        if (target.registration != null && p.machineTenant != t.id) {
          throw CliError(
            CliExit.usage,
            'This machine already serves tenant ${p.machineTenant}. '
            'Run `idrt logout` to move it.',
          );
        }

        // Seats come from the tenant's billing org.
        final slug = _billingOrg(p, t);
        var org = await loadOrg();
        if (org?.slug != slug) {
          org = await _bindBilling(target, slug, fallback: org?.slug ?? p.org);
          await saveOrg(org, target.session!.email);
        }
        _requireNoOtherPlan(target, org!.name);
        final open = argResults!['open'] as bool;
        await requireBilling(target, _plan, open: open);

        try {
          await registerThisMachine(target, _plan, host,
              approveHere: true);
        } on IdrTargetException catch (e) {
          if (e.code != IdrTargetErrorCode.quotaExceeded) rethrow;
          ui.info('${org.name} has no free Target seat.');
          await openPortal(target, portalPaths(_plan).subscribe, open: open);
          throw const CliError(
            CliExit.billing,
            'Add a seat in the portal, then re-run this command.',
          );
        }
        await _save((
          org: p.org,
          orgName: p.orgName,
          tenants: p.tenants,
          machineTenant: t.id,
        ));
        ui.info('Serving tenant ${t.name}, billed to ${org.name}.');
        return CliExit.ok;
      });
}

/// `idrt provider billing <tenant> [--buy]` — manage a tenant's seats.
class _Billing extends Command<int> {
  _Billing() {
    argParser
      ..addFlag('buy', negatable: false, help: 'Go to checkout for more seats.')
      ..addFlag('open', defaultsTo: true, help: 'Open the browser.');
  }

  @override
  String get name => 'billing';

  @override
  String get description =>
      'Open the portal for a tenant\'s billing org: billing <tenant> [--buy].';

  @override
  Future<int> run() => withTarget((target) async {
        final rest = argResults!.rest;
        if (rest.length != 1) usageException('Expected <tenant>.');
        final p = await _requireProvider(target);
        final t = _findTenant(p, rest.single);
        final slug = _billingOrg(p, t);
        ui.info('Tenant ${t.name} is billed to $slug.');
        final paths = portalPaths(_plan);
        await openPortal(
          target,
          argResults!['buy'] as bool ? paths.subscribe : paths.manage,
          open: argResults!['open'] as bool,
          orgSlug: slug,
        );
        return CliExit.ok;
      });
}
