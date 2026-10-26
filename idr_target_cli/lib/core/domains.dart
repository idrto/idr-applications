import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';

import 'devices.dart';
import 'target.dart';

/// `idrt <mode> domain add|verify|list|remove` — customer domains CNAME'd to
/// this Target. Billing verifies the CNAME; the agent then gets a Let's
/// Encrypt certificate on its next start.
class DomainCommand extends Command<int> {
  DomainCommand(IdrBusinessPlan plan) {
    addSubcommand(_Add(plan));
    addSubcommand(_Verify(plan));
    addSubcommand(_List(plan));
    addSubcommand(_Remove(plan));
  }

  @override
  String get name => 'domain';

  @override
  String get description =>
      'Custom domains for this Target (CNAME + Let\'s Encrypt certificate).';
}

/// Billing refusals the user can fix exit 64 with billing's message.
Future<T> _billing<T>(Future<T> Function() call) async {
  try {
    return await call();
  } on CustomDomainException catch (e) {
    throw CliError(
      e.isClientError ? CliExit.usage : CliExit.failure,
      e.message,
    );
  } on StateError catch (e) {
    throw CliError(CliExit.usage, e.message);
  }
}

/// The DNS record to create, then the check result (`add`).
List<String> addReport(CustomDomain d) => [
      'Added ${d.domain} to ${d.targetFqhn}.',
      'Create this DNS record at the domain\'s DNS provider:',
      '  ${d.domain}  CNAME  ${d.cnameTarget}',
      ...checkReport(d),
    ];

/// What the last CNAME check says and what to do next.
List<String> checkReport(CustomDomain d) => d.verified
    ? [
        'Verified: ${d.domain} points to this Target.',
        'Restart `idrt start` so the agent requests its certificate.',
      ]
    : [
        'Not verified yet: ${d.lastError?.message ?? 'not checked yet.'}',
        'Then run `idrt provider domain verify ${d.domain}`.',
      ];

/// One-line certificate state from the agent's `acme-status.json`.
String certLine(AcmeDomainStatus? s) {
  if (s == null) return 'certificate: not requested yet';
  final staging = s.staging ? ' (staging)' : '';
  String day(DateTime? t) => t?.toIso8601String().substring(0, 10) ?? '?';
  return switch (s.state) {
    'issued' ||
    'valid' =>
      'certificate: issued$staging, expires ${day(s.notAfter)}, renews ${day(s.renewAt)}',
    'issuing' => 'certificate: requesting from Let\'s Encrypt$staging',
    'failed' =>
      'certificate: failed$staging: ${s.lastError ?? 'unknown error'}',
    _ => 'certificate: ${s.state}$staging',
  };
}

class _Add extends Command<int> {
  _Add(this.plan);
  final IdrBusinessPlan plan;

  @override
  String get name => 'add';

  @override
  String get description =>
      'Add a domain: add app.customer.com (prints the CNAME to create).';

  @override
  Future<int> run() => withTarget((target) async {
        final rest = argResults!.rest;
        if (rest.length != 1) usageException('Expected <domain>.');
        requireMode(target, plan);
        final d = await _billing(() => target.addCustomDomain(rest.single));
        addReport(d).forEach(ui.info);
        return CliExit.ok;
      });
}

class _Verify extends Command<int> {
  _Verify(this.plan);
  final IdrBusinessPlan plan;

  @override
  String get name => 'verify';

  @override
  String get description =>
      'Check a domain\'s CNAME now: verify app.customer.com (exit 1 until verified).';

  @override
  Future<int> run() => withTarget((target) async {
        final rest = argResults!.rest;
        if (rest.length != 1) usageException('Expected <domain>.');
        requireMode(target, plan);
        final d = await _billing(() => target.verifyCustomDomain(rest.single));
        checkReport(d).forEach(ui.info);
        return d.verified ? CliExit.ok : CliExit.failure;
      });
}

class _List extends Command<int> {
  _List(this.plan);
  final IdrBusinessPlan plan;

  @override
  String get name => 'list';

  @override
  String get description =>
      'This Target\'s domains, CNAME targets and certificates.';

  @override
  Future<int> run() => withTarget((target) async {
        requireMode(target, plan);
        final domains = await _billing(target.customDomains);
        ui.result(
          [
            for (final d in domains)
              {
                'domain': d.domain,
                'status': d.status,
                'cnameTarget': d.cnameTarget,
                'verified': d.verified,
                'lastError': d.lastError?.message,
                'certificate': d.verified ? target.acmeStatus(d.domain)?.state : null,
              },
          ],
          human: () {
            if (domains.isEmpty) {
              ui.info('No custom domains. Add one with '
                  '`idrt provider domain add <domain>`.');
            }
            for (final d in domains) {
              ui
                ..info('${d.domain.padRight(28)} ${d.status}')
                ..info('  CNAME → ${d.cnameTarget}');
              if (!d.verified && d.lastError != null) {
                ui.info('  ${d.lastError!.message}');
              }
              if (d.verified) {
                ui.info('  ${certLine(target.acmeStatus(d.domain))}');
              }
            }
          },
        );
        return CliExit.ok;
      });
}

class _Remove extends Command<int> {
  _Remove(this.plan);
  final IdrBusinessPlan plan;

  @override
  String get name => 'remove';

  @override
  String get description => 'Remove a domain: remove app.customer.com.';

  @override
  Future<int> run() => withTarget((target) async {
        final rest = argResults!.rest;
        if (rest.length != 1) usageException('Expected <domain>.');
        requireMode(target, plan);
        final d = await _billing(() => target.removeCustomDomain(rest.single));
        ui.info(
            'Removed ${d.domain}. It stops routing here within 5 minutes; '
            'restart `idrt start` to drop its certificate request.');
        return CliExit.ok;
      });
}
