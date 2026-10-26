import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';

import 'billing.dart';
import 'doctor.dart';
import 'target.dart';

class LoginCommand extends Command<int> {
  LoginCommand() {
    argParser.addFlag(
      'force',
      abbr: 'f',
      negatable: false,
      help: 'Sign in again even if a session exists.',
    );
  }

  @override
  String get name => 'login';

  @override
  String get description => 'Sign in with Google via billing SSO.';

  @override
  Future<int> run() => withTarget((target) async {
        if (target.session != null && !(argResults!['force'] as bool)) {
          final email = target.session!.email;
          ui.result({'account': email, 'alreadySignedIn': true}, human: () {
            ui.info('Already signed in as $email.');
            ui.hint('Use --force to sign in again.');
          });
          return CliExit.ok;
        }
        await ui.task(
          'Waiting for sign-in in your browser',
          () => target.signIn(launchAgent: false),
        );
        final session = target.session;
        if (session == null) {
          throw CliError(
            CliExit.auth,
            'Sign-in failed: ${target.attention?.message ?? 'unknown error'}',
            code: 'AUTH_FAILED',
          );
        }
        ui.result({'account': session.email}, human: () {
          ui.success('Signed in as ${session.email}.');
          // In a terminal the home menu follows instead.
          if (currentPlan(target) == null && !ui.interactive) {
            ui.hint('Next: `idrt personal setup`, `idrt enterprise setup '
                '--org <slug>` or `idrt provider setup --org <slug>`.');
          }
        });
        return CliExit.ok;
      });
}

class LogoutCommand extends Command<int> {
  @override
  String get name => 'logout';

  @override
  String get description =>
      'Sign out and forget this machine\'s host registration.';

  @override
  Future<int> run() => withTarget((target) async {
        await target.signOut();
        await clearOrg();
        ui.result({'signedOut': true}, human: () => ui.success('Signed out.'));
        return CliExit.ok;
      });
}

String readyStepName(TargetReadyStep step) => switch (step) {
      SignInRequired() => 'sign-in required',
      PlanRequired() => 'plan required',
      RoleRequired() => 'role required',
      BillingRequired() => 'billing required',
      RegistrationRequired() => 'host registration required',
      EnterpriseSetupRequired() => 'enterprise setup required',
      Ready() => 'ready',
    };

class StatusCommand extends Command<int> {
  @override
  String get name => 'status';

  @override
  String get description =>
      'Show sign-in, mode, subscription, registration, agent and enroll '
      'state.';

  @override
  Future<int> run() => withTarget((target) async {
        final s = target.state;
        final plan = currentPlan(target);
        final org = await loadOrg();
        final a = target.attention;
        final data = {
          'controlPlane': target.config.controlPlaneBase,
          'account': s.session?.email,
          'mode': plan?.title,
          'org': org == null
              ? null
              : {'slug': org.slug, 'name': org.name, 'role': org.role},
          'role': s.user.accountPath,
          'subscriptionActive': plan == null ? null : isCovered(target, plan),
          'host': target.registration?.verifiedFqhn,
          'awaitingApproval': s.enrollment.awaitingAdmin,
          'services': s.services.length,
          'agentRunning': await agentRunning(),
          'next': readyStepName(s.readyStep),
          'attention': a == null ? null : {'code': a.code.wire, 'message': a.message},
        };
        ui.result(data, human: () {
          ui.fields({
            'control plane': data['controlPlane'],
            'account': data['account'] ?? '(signed out)',
            'mode': data['mode'] ?? '(not set up)',
            if (org != null) 'org': '${org.name} (${org.slug}), ${org.role}',
            'role': data['role'],
            if (plan != null)
              'subscription':
                  isCovered(target, plan) ? 'active' : 'missing or expired',
            'host': data['host'] ?? '(not registered)',
            if (s.enrollment.awaitingAdmin) 'enroll': 'waiting for admin approval',
            'services': data['services'],
            'agent': data['agentRunning'] == true ? 'running' : 'not running',
            'next': data['next'],
          });
          printAttention(target);
        });
        return CliExit.ok;
      });
}

/// `idrt start` — run target-agent in the foreground until Ctrl+C.
class StartCommand extends Command<int> {
  @override
  String get name => 'start';

  @override
  String get description =>
      'Run the Target agent in the foreground (Ctrl+C to stop).';

  @override
  Future<int> run() async {
    final target = createTarget();
    final subs = <StreamSubscription<Object?>>[];
    try {
      await target.start(launchAgent: false);
      requireSession(target);
      final plan = currentPlan(target);
      if (plan == null) {
        throw const CliError(
          CliExit.usage,
          'No mode chosen yet.',
          hint: 'Run `idrt personal setup` (or enterprise / provider setup).',
          code: 'MODE_REQUIRED',
        );
      }
      await requireBilling(target, plan);

      // Status changes during startup would break the spinner line.
      var started = false;
      subs
        ..add(target.statusStream.distinct().listen((s) => started
            ? ui.info('status: ${s.name}')
            : ui.debug('status: ${s.name}')))
        ..add(target.attentionStream.listen((a) {
          if (a == null) return;
          ui.warn('${a.code.wire}: ${a.message}');
          if (billingAttentionCodes.contains(a.code)) {
            ui.hint('Run `idrt billing` to fix your subscription.');
          }
        }));

      await ui.task('Starting target-agent', target.start);
      started = true;
      if (target.status != IdrTargetStatus.running &&
          target.status != IdrTargetStatus.starting) {
        final code = target.attention?.code;
        throw CliError(
          code != null && billingAttentionCodes.contains(code)
              ? CliExit.billing
              : CliExit.failure,
          'target-agent did not start (${target.status.name})'
          '${target.attention == null ? '' : ': ${target.attention!.message}'}',
          hint: 'Run `idrt doctor`; add --verbose for the SDK log.',
          code: code?.wire ?? 'AGENT_START_FAILED',
        );
      }
      final summary = {
        'serving': target.registration?.verifiedFqhn,
        'status': target.status.name,
        'agent': target.config.agentBinaryPath,
        'presence': target.config.discoveryUrl,
        'services': [
          for (final s in target.services)
            {'name': s.name, 'type': s.type, 'endpoint': s.endpoint},
        ],
      };
      // JSON: one summary document now; the process keeps serving.
      ui.result(summary, human: () {
        ui.fields({
          'serving': summary['serving'],
          'agent': summary['agent'],
          'presence': summary['presence'],
          'services': target.services.isEmpty
              ? '(none: `idrt services add <name> <url>`)'
              : target.services.map((s) => s.name).join(', '),
        });
        ui.hint('Ctrl+C to stop.');
      });
      await ProcessSignal.sigint.watch().first;
      return CliExit.ok;
    } finally {
      for (final s in subs) {
        await s.cancel();
      }
      await target.dispose();
    }
  }
}

class ServicesCommand extends Command<int> {
  ServicesCommand() {
    addSubcommand(_ServicesList());
    addSubcommand(_ServicesAdd());
    addSubcommand(_ServicesRemove());
  }

  @override
  String get name => 'services';

  @override
  String get description => 'Manage services this Target exposes.';
}

class _ServicesList extends Command<int> {
  @override
  String get name => 'list';

  @override
  String get description => 'List exposed services.';

  @override
  Future<int> run() => withTarget((target) async {
        ui.result(
          [
            for (final s in target.services)
              {
                'name': s.name,
                'type': s.type,
                'endpoint': s.endpoint,
                'enabled': s.enabled,
              },
          ],
          human: () {
            if (target.services.isEmpty) {
              ui.info('No services. Add one with `idrt services add`.');
              return;
            }
            ui.table(['name', 'type', 'endpoint', 'enabled'], [
              for (final s in target.services)
                [s.name, s.type, s.endpoint, s.enabled ? 'yes' : 'no'],
            ]);
          },
        );
        return CliExit.ok;
      });
}

class _ServicesAdd extends Command<int> {
  _ServicesAdd() {
    argParser
      ..addOption('type', allowed: ['http', 'tcp'], defaultsTo: 'http')
      ..addOption('credential', defaultsTo: 'source', help: 'Credential mode.')
      ..addFlag('tls', help: 'Require TLS to the upstream.');
  }

  @override
  String get name => 'add';

  @override
  String get description => 'Add a service: add <name> <endpoint>.';

  @override
  String get invocation => 'idrt services add <name> <endpoint> [--type tcp]';

  @override
  String get usageFooter => '\nExamples:\n'
      '  idrt services add ollama http://127.0.0.1:11434\n'
      '  idrt services add lmstudio http://127.0.0.1:1234';

  @override
  Future<int> run() => withTarget((target) async {
        final rest = argResults!.rest;
        if (rest.length > 2) usageException('Expected <name> <endpoint>.');
        final name = ui.ask('Service name (what zone policies allow, e.g. '
            'ollama)', value: rest.elementAtOrNull(0), flag: '<name>');
        final endpoint = ui.ask('Local endpoint (e.g. http://127.0.0.1:11434)',
            value: rest.elementAtOrNull(1), flag: '<endpoint>');
        final error = await target.addServiceFromForm(
          name: name,
          type: argResults!['type'] as String,
          endpoint: endpoint,
          credentialMode: argResults!['credential'] as String,
          requireTls: argResults!['tls'] as bool,
        );
        if (error != null) throw CliError(CliExit.usage, error);
        ui.result({'added': name, 'endpoint': endpoint}, human: () {
          ui.success('Added $name.');
          ui.hint('Restart `idrt start` to publish it.');
        });
        return CliExit.ok;
      });
}

class _ServicesRemove extends Command<int> {
  @override
  String get name => 'remove';

  @override
  String get description => 'Remove a service: remove <name>.';

  @override
  Future<int> run() => withTarget((target) async {
        final rest = argResults!.rest;
        if (rest.length != 1) usageException('Expected <name>.');
        await target.removeService(rest.single);
        ui.result({'removed': rest.single},
            human: () => ui.success('Removed ${rest.single}.'));
        return CliExit.ok;
      });
}
