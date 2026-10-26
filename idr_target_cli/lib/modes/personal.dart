import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';

import '../core/billing.dart';
import '../core/devices.dart';
import '../core/target.dart';

/// Personal mode: one user, one personal subscription, email is the entity.
///
/// The first machine becomes the admin (Entity CA). Later machines join as
/// Targets and the admin approves their enrollment (`pending` / `approve`).
const _plan = IdrBusinessPlan.personal;

class PersonalCommand extends Command<int> {
  PersonalCommand() {
    addSubcommand(_Setup());
    addSubcommand(_Register());
    addSubcommand(PendingCommand(_plan));
    addSubcommand(DecideCommand(_plan, approve: true));
    addSubcommand(DecideCommand(_plan, approve: false));
  }

  @override
  String get name => 'personal';

  @override
  String get description =>
      'Personal mode: your own subscription and machines.';
}

/// `idrt personal setup [--host <label>]`
class _Setup extends Command<int> {
  _Setup() {
    argParser
      ..addOption('host', help: 'Also register this machine, e.g. laptop.')
      ..addFlag(
        'open',
        defaultsTo: true,
        help: 'Open the billing portal if a subscription is needed.',
      );
  }

  @override
  String get name => 'setup';

  @override
  String get description =>
      'Choose Personal mode, check your subscription, set up this machine.';

  @override
  Future<int> run() => withTarget((target) async {
        requireSession(target);
        // Personal billing is the user's own org; leave any Enterprise org.
        if (await loadOrg() != null) {
          await target.bindOrganization('me');
          await clearOrg();
        }
        final paid =
            target.userState.hasActivePlan ? currentPlan(target) : null;
        if (paid != null && paid != _plan) {
          throw CliError(
            CliExit.usage,
            'Your account has an active ${paid.title} subscription. '
            'Personal setup needs a Personal subscription.',
          );
        }
        await target.savePlanSelection(planCode: _plan.planCode);

        // Role is decided once: the first machine for this email is the admin.
        var admin = isAdminMachine(target);
        if (target.userState.accountPath == null) {
          final roles = await target.resolveRoleAvailability(_plan);
          admin = roles.adminPathEnabled;
          await target.saveAccountPath(admin ? 'rootAdmin' : 'joinTarget');
          await target.saveEnterpriseUiFlags(
            entityRole: admin ? 'adminCa' : 'enrollTarget',
          );
        }

        await requireBilling(
          target,
          _plan,
          open: argResults!['open'] as bool,
        );

        if (admin) {
          await target.ensureAdminCa();
          ui.info(
            'This machine is the Personal admin for ${target.session!.email}.',
          );
        } else {
          ui.info(
              'This machine joins ${target.session!.email} as a Target.');
        }
        await target.markOnboardingDone();

        final host = argResults!['host'] as String?;
        if (host != null && host.trim().isNotEmpty) {
          await registerThisMachine(target, _plan, host);
        } else if (target.registration == null) {
          ui
              .info('Next: `idrt personal register <host>` (e.g. laptop).');
        }
        return CliExit.ok;
      });
}

/// `idrt personal register <host>`
class _Register extends Command<int> {
  @override
  String get name => 'register';

  @override
  String get description =>
      'Register this machine as a Target: register <host> (e.g. laptop).';

  @override
  Future<int> run() => withTarget((target) async {
        final host = ui.ask('Host name for this machine (e.g. laptop)',
            value: argResults!.rest.firstOrNull, flag: '<host>');
        requireMode(target, _plan);
        await requireBilling(target, _plan);
        await registerThisMachine(target, _plan, host);
        return CliExit.ok;
      });
}
