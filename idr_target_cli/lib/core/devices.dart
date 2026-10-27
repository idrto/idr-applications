import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';

import 'billing.dart';
import 'target.dart';

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
}) async {
  final host = label.trim().toLowerCase();
  final existing = target.registration;
  if (existing != null) {
    ui.info('Already registered as ${existing.verifiedFqhn}.');
    return;
  }
  final check = await target.isHostAvailable(
    hostLabel: host,
    entityId: entityId,
  );
  if (!check.available) {
    throw CliError(
      CliExit.usage,
      '${check.verifiedFqhn} is taken. Pick another host name.',
    );
  }
  final reg = await target.registerHost(label: host, joinEntityId: entityId);
  if (isAdminMachine(target)) {
    await target.saveEnterpriseUiFlags(adminAlsoTarget: true);
  }
  ui.info('Registered ${reg.verifiedFqhn}.');
  if (target.state.enrollment.awaitingAdmin) {
    final cmd = _cmd(plan);
    ui.info(
      approveHere ?? isAdminMachine(target)
          ? 'Approve it here: `idrt $cmd pending`, then `idrt $cmd approve <id>`.'
          : 'Waiting for approval. On your admin machine run '
                '`idrt $cmd approve <id>`.',
    );
  } else {
    ui.info('Next: `idrt start`.');
  }
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
      requireAdminMachine(target, plan);
    } else {
      requireMode(target, plan);
    }
    final email = target.session!.email.trim().toLowerCase();
    final pending = (await target.listPendingEnrollments(
      email,
    )).where((r) => r.isPending).toList();
    ui.result(
      [
        for (final r in pending)
          {
            'id': r.id,
            'host': r.verifiedFqhn ?? r.hostLabel,
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
          ['id', 'host', 'requester', 'submitted'],
          [
            for (final r in pending)
              [
                r.id,
                r.verifiedFqhn ?? r.hostLabel,
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

/// Asks which pending enrollment (none given on the command line).
Future<String> _choosePending(IdrTarget target) async {
  final email = target.session!.email.trim().toLowerCase();
  final pending = (await target.listPendingEnrollments(
    email,
  )).where((r) => r.isPending).toList();
  if (pending.isEmpty) {
    throw const CliError(
      CliExit.failure,
      'No pending enrollments.',
      code: 'NOTHING_PENDING',
    );
  }
  return ui
      .choose(
        'Which enrollment?',
        pending,
        flag: '<id>',
        display: (r) =>
            '${r.verifiedFqhn ?? r.hostLabel}  ${r.requesterEmail}  (${r.id})',
      )
      .id;
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
      requireAdminMachine(target, plan);
    } else {
      requireMode(target, plan);
    }
    final id = rest.firstOrNull ?? await _choosePending(target);
    final zone = approve && zones
        ? (argResults!['zone'] as String?)?.trim().toLowerCase()
        : null;
    if (zone != null &&
        !target.enterpriseZones.any(
          (z) => z.pathKey == zone && z.hasCertificate,
        )) {
      throw CliError(
        CliExit.usage,
        'Zone $zone has no certificate on this machine. '
        'Issue it with `idrt enterprise zone add $zone`.',
      );
    }
    if (approve) {
      // Approval allocates the seat, so the plan must be paid.
      await requireBilling(target, plan);
      await target.approveEnrollment(enrollId: id, zone: zone);
    } else {
      await target.rejectEnrollment(id);
    }
    ui.info(
      '${approve ? 'Approved' : 'Rejected'} ${id}'
      '${zone == null ? '' : ' under zone $zone'}.',
    );
    return CliExit.ok;
  });
}
