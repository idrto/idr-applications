import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';

import 'billing.dart';
import 'target.dart';
import 'zones.dart';

/// Shared machine / enrollment flow. Personal and Enterprise both register
/// hosts under the signed-in email entity; the admin machine for that entity
/// approves enrollments.

String _cmd(IdrBusinessPlan plan) => switch (plan) {
  IdrBusinessPlan.personal => 'personal',
  IdrBusinessPlan.enterprise => 'enterprise',
  IdrBusinessPlan.serviceProvider => 'provider',
};

bool isAdminMachine(IdrTarget target) =>
    target.userState.accountPath == 'rootAdmin';

/// Signed in and set up for [plan].
void requireMode(IdrTarget target, IdrBusinessPlan plan) {
  requireSession(target);
  final current = currentPlan(target);
  if (current != plan) {
    throw CliError(
      CliExit.usage,
      current == null
          ? 'Run `idrt ${_cmd(plan)} setup` first.'
          : 'This machine is set up for ${current.title}, not ${plan.title}.',
    );
  }
}

void requireAdminMachine(IdrTarget target, IdrBusinessPlan plan) {
  requireMode(target, plan);
  if (!isAdminMachine(target)) {
    throw CliError(
      CliExit.usage,
      'Only an admin machine can review enrollments '
      '(`idrt ${_cmd(plan)} setup --role admin`).',
    );
  }
}

/// Approves enrollments: the admin machine, or a zone admin's machine that
/// holds a zone key (it decides only its zones; billing enforces that).
Future<bool> isApprover(IdrTarget target) async =>
    isAdminMachine(target) || (await target.zoneAuthorities()).isNotEmpty;

Future<void> requireApprover(IdrTarget target, IdrBusinessPlan plan) async {
  requireMode(target, plan);
  if (await isApprover(target)) return;
  final waiting = await target.zoneKeyRequests();
  throw CliError(
    CliExit.usage,
    waiting.isNotEmpty
        ? 'This machine\'s key for zone ${waiting.join(', ')} is not signed '
              'yet, so it cannot approve.'
        : 'Only an admin machine can review enrollments.',
    hint: waiting.isNotEmpty
        ? 'The root admin approves it in `idrt` > Pending approvals.'
        : 'Root admin: `idrt ${_cmd(plan)} setup --role admin`. Zone admin: '
              '`idrt ${_cmd(plan)} setup` picks up your zone.',
    code: 'NOT_APPROVER',
  );
}

/// Entity whose requests this machine reviews: its own registration's, the
/// zone's org, or the signed-in email.
Future<String> approverEntity(IdrTarget target) async =>
    (target.registration?.entityId ??
            (await loadZoneContext())?.entityId ??
            target.session!.email)
        .trim()
        .toLowerCase();

/// Register this machine as a Target under the signed-in email entity.
///
/// [approveHere]: this machine can approve its own enrollment (admin
/// machines, or modes without an admin machine).
Future<void> registerThisMachine(
  IdrTarget target,
  IdrBusinessPlan plan,
  String label, {
  bool? approveHere,
  String? entityId,
  String? zone,
}) async {
  final host = label.trim().toLowerCase();
  if (!EnterpriseFqhn.isValidHostLabel(host)) {
    final fixed = host
        .replaceAll(RegExp(r'[^a-z0-9-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    throw CliError(
      CliExit.usage,
      'Invalid host name "$label": use lowercase letters, digits and -.',
      hint: fixed.isEmpty ? null : 'Try "$fixed".',
      code: 'INVALID_HOST',
    );
  }
  final existing = target.registration;
  if (existing != null) {
    ui.info('Already registered as ${existing.verifiedFqhn}.');
    return;
  }
  final check = await target.isHostAvailable(
    hostLabel: host,
    entityId: entityId,
    zone: zone,
  );
  if (!check.available) {
    throw CliError(
      CliExit.usage,
      '${check.verifiedFqhn} is taken. Pick another host name.',
    );
  }
  final reg = await target.registerHost(
    label: host,
    joinEntityId: entityId,
    zone: zone,
  );
  if (isAdminMachine(target)) {
    await target.saveEnterpriseUiFlags(adminAlsoTarget: true);
  }
  ui.info(
    'Registered ${reg.verifiedFqhn}${zone == null ? '' : ' in zone $zone'}.',
  );
  final approver = await isApprover(target);
  if (approver && await approveSelfIfPending(target, plan)) {
    return;
  }
  if (target.state.enrollment.awaitingAdmin) {
    final cmd = _cmd(plan);
    ui.info(
      approveHere ?? approver
          ? 'Approve it here: `idrt $cmd pending`, then `idrt $cmd approve <id>`.'
          : zone != null
          ? 'Waiting for an admin of zone $zone to approve it '
                '(`idrt` > Pending approvals on their machine).'
          : 'Waiting for approval. On your admin machine run '
                '`idrt $cmd approve <id>`.',
    );
  } else {
    ui.info('Next: `idrt start`.');
  }
}

/// Admin machine: approve this machine's own pending Target registration,
/// so nobody has to run `pending` / `approve` for it. True when approved.
Future<bool> approveSelfIfPending(
  IdrTarget target,
  IdrBusinessPlan plan, {
  String? zone,
}) async {
  final reg = target.registration;
  if (reg == null || !target.state.enrollment.awaitingAdmin) return false;
  final mine =
      (await target.listPendingEnrollments(
        reg.entityId.trim().toLowerCase(),
      )).where(
        (r) =>
            r.isPending &&
            ((reg.machineSki != null && r.subjectSki == reg.machineSki) ||
                r.verifiedFqhn == reg.verifiedFqhn),
      );
  if (mine.isEmpty) return false;
  await requireBilling(target, plan, allowMembers: true);
  await target.approveEnrollment(enrollId: mine.first.id, zone: zone);
  ui.info('Approved ${reg.verifiedFqhn} on this machine.');
  ui.info('Next: `idrt start`.');
  return true;
}

/// `idrt <mode> pending` (admin machine)
class PendingCommand extends Command<int> {
  PendingCommand(this.plan, {this.adminOnly = true});

  final IdrBusinessPlan plan;

  /// False for modes with no admin machine (Service Provider).
  final bool adminOnly;

  @override
  String get name => 'pending';

  @override
  String get description => 'List machines waiting for approval.';

  @override
  Future<int> run() => withTarget((target) async {
    if (adminOnly) {
      await requireApprover(target, plan);
    } else {
      requireMode(target, plan);
    }
    final pending = (await target.listPendingEnrollments(
      await approverEntity(target),
    )).where((r) => r.isPending).toList();
    ui.result(
      [
        for (final r in pending)
          {
            'id': r.id,
            'kind': r.kind,
            'host': r.verifiedFqhn ?? r.hostLabel,
            'zone': r.zone,
            'requester': r.requesterEmail,
            'submittedAt': r.submittedAt.toUtc().toIso8601String(),
          },
      ],
      human: () {
        if (pending.isEmpty) {
          ui.info('No pending enrollments.');
          final fqhn = target.registration?.verifiedFqhn;
          ui.hint(
            fqhn == null
                ? 'Nobody can enroll yet: register this machine as a Target '
                      'first (`idrt ${_cmd(plan)} register`).'
                : 'People appear here after they run '
                      '`idr enroll $fqhn`'
                      '${plan == IdrBusinessPlan.enterprise ? ' --org <org-slug>' : ''}.',
          );
          return;
        }
        ui.table(
          ['id', 'request', 'zone', 'requester', 'submitted'],
          [
            for (final r in pending)
              [
                r.id,
                requestLabel(r),
                r.zone ?? '(root)',
                r.requesterEmail,
                '${r.submittedAt.toLocal()}'.split('.').first,
              ],
          ],
        );
        ui.hint('Approve: idrt ${_cmd(plan)} approve <id>');
      },
    );
    return CliExit.ok;
  });
}

/// What a pending request is, in words.
String requestLabel(EnrollmentRequest r) => switch (r.kind) {
  'zone_authority' => 'zone key for ${r.zone}',
  'machine_source' =>
    'Source ${r.verifiedFqhn ?? r.hostLabel}'
        '${r.target == null ? '' : ' for ${r.target}'}',
  _ => 'Target ${r.verifiedFqhn ?? r.hostLabel}',
};

/// Asks which pending enrollment (none given on the command line).
Future<EnrollmentRequest> _choosePending(IdrTarget target) async {
  final pending = (await target.listPendingEnrollments(
    await approverEntity(target),
  )).where((r) => r.isPending).toList();
  if (pending.isEmpty) {
    throw const CliError(
      CliExit.failure,
      'No pending enrollments.',
      code: 'NOTHING_PENDING',
    );
  }
  return ui.choose<EnrollmentRequest>(
    'Which request?',
    pending,
    flag: '<id>',
    display: (r) =>
        '${requestLabel(r)}${r.zone == null || r.isZoneKey ? '' : ' in ${r.zone}'}'
        '${r.requesterEmail.isEmpty ? '' : '  from ${r.requesterEmail}'}',
  );
}

/// `idrt <mode> approve <id>` / `idrt <mode> reject <id>` (admin machine)
class DecideCommand extends Command<int> {
  DecideCommand(
    this.plan, {
    required this.approve,
    this.adminOnly = true,
    this.zones = false,
  }) {
    if (approve && zones) {
      argParser.addOption(
        'zone',
        help:
            'Sign the machine under this zone\'s certificate (e.g. fin). '
            'Default: under the root.',
      );
    }
  }

  final IdrBusinessPlan plan;
  final bool approve;
  final bool adminOnly;

  /// Offer `--zone` (modes with zone certificates: Enterprise).
  final bool zones;

  @override
  String get name => approve ? 'approve' : 'reject';

  @override
  String get description =>
      '${approve ? 'Approve' : 'Reject'} a pending enrollment: $name <id>.';

  @override
  Future<int> run() => withTarget((target) async {
    final rest = argResults!.rest;
    if (rest.length > 1) usageException('Expected <id>.');
    if (adminOnly) {
      await requireApprover(target, plan);
    } else {
      requireMode(target, plan);
    }
    final picked = rest.isEmpty ? await _choosePending(target) : null;
    final id = rest.firstOrNull ?? picked!.id;
    final keys = {for (final z in await target.zoneAuthorities()) z.zone};
    // A request made into a zone is signed under it; otherwise ask (root).
    var zone = approve && zones
        ? (argResults!['zone'] as String?)?.trim().toLowerCase()
        : null;
    if (zone == null &&
        approve &&
        zones &&
        picked != null &&
        picked.zone == null &&
        !picked.isZoneKey &&
        keys.isNotEmpty &&
        ui.interactive) {
      final chosen = ui.choose(
        'Sign it under which zone?',
        ['', ...keys],
        flag: '--zone',
        display: (z) => z.isEmpty ? 'No zone (directly under the root)' : z,
      );
      zone = chosen.isEmpty ? null : chosen;
    }
    final needed = zone ?? (picked?.isZoneKey == true ? null : picked?.zone);
    if (needed != null && !keys.contains(needed)) {
      throw CliError(
        CliExit.usage,
        'This machine has no key for zone $needed.',
        hint: isAdminMachine(target)
            ? 'Issue it with `idrt enterprise zone add $needed`, or let an '
                  'admin of $needed approve it on their machine.'
            : 'If you are an admin of $needed: `idrt enterprise setup '
                  '--zone $needed`.',
        code: 'NO_ZONE_KEY',
      );
    }
    final what = picked == null ? id : requestLabel(picked);
    if (approve) {
      // Approval allocates the seat, so the plan must be paid.
      await requireBilling(target, plan, allowMembers: true);
      await target.approveEnrollment(enrollId: id, zone: zone);
    } else {
      await target.rejectEnrollment(id);
    }
    ui.info(
      '${approve ? 'Approved' : 'Rejected'} $what'
      '${needed == null ? '' : ' in zone $needed'}.',
    );
    if (approve && picked?.isZoneKey == true) {
      ui.hint(
        '${picked!.requesterEmail.isEmpty ? 'The zone admin' : picked.requesterEmail} '
        'can now approve zone ${picked.zone}\'s requests on their machine.',
      );
    }
    return CliExit.ok;
  });
}
