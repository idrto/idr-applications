import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_source/idr_source.dart';

import '../bootstrap.dart';
import '../prefs/cli_prefs.dart';

class EnrollCommand extends Command<int> {
  EnrollCommand() {
    argParser
      ..addOption(
        'label',
        help: 'Source machine label (default: hostname).',
      )
      ..addOption(
        'org',
        help: 'Billing organization to enroll into (its slug). Binds this '
            'sign-in to that org first; you must be a member.',
      )
      ..addOption(
        'zone',
        help: 'Join this zone of the organization (e.g. fin). Its admin '
            'approves, and its policy decides which services you may use.',
      );
  }

  @override
  String get name => 'enroll';

  @override
  String get description =>
      'Enroll this machine as a Source device for a Target (Admin approves).';

  @override
  String get invocation =>
      'idr enroll [<target-fqhn>] [--label <name>] [--org <slug>] [--zone <zone>]';

  @override
  String get usageFooter => '\nExamples:\n'
      '  idr enroll laptop--you@example.com\n'
      '  idr enroll gpu-box--admin@acme.com --org acme --label alice-laptop\n'
      '  idr enroll gpu-box--admin@acme.com --org acme --zone fin';

  @override
  Future<int> run() => withSource((source) async {
        requireSignedIn(source);
        var org = (argResults!['org'] as String?)?.trim();
        String? boundOrg;
        Future<void> bind(String slug) async {
          final bound = await ui.task(
            'Binding to organization $slug',
            () => source.bindOrganization(slug),
            done: (b) => 'Bound to ${b.name} (${b.slug}) as ${b.role}.',
          );
          boundOrg = bound.slug;
          rememberOrg(knownOrgsFile, source.state.session!.email, bound.slug,
              bound.name);
        }

        if (org != null && org.isNotEmpty) await bind(org);
        final fqhn = ui.ask(
          'Target FQHN (e.g. gpu-box--admin@acme.com)',
          value: argResults!.rest.firstOrNull ?? source.state.fqhn,
          flag: '<target-fqhn>',
        );
        var zone = (argResults!['zone'] as String?)?.trim().toLowerCase();
        // A zoned Target's name carries its zone; billing files it there.
        final targetZone = SourceIdentityManager.zoneFromFqhn(fqhn);
        if ((zone == null || zone.isEmpty) &&
            targetZone == null &&
            boundOrg != null &&
            ui.interactive &&
            ui.confirm('Join a specific zone of $boundOrg? (No: the '
                'organization admin decides)')) {
          zone = ui.ask('Zone (e.g. fin)', flag: '--zone').toLowerCase();
        }
        if (zone != null && zone.isEmpty) zone = null;
        final shownZone = zone ?? targetZone;
        String host;
        Future<String> enrollOnce() => ui.task(
              'Enrolling with $fqhn',
              () => source.enroll(
                fqhn: fqhn,
                sourceLabel: argResults!['label'] as String?,
                zone: zone,
              ),
              done: (h) => 'Source device approved: $h',
            );
        try {
          try {
            host = await enrollOnce();
          } on IdrSourceException catch (e) {
            // The Target's entity belongs to an organization this sign-in
            // is not bound to: ask which one, then retry once.
            if (!e.toString().contains('NOT_REGISTERED') &&
                !e.message.contains('NOT_REGISTERED') ||
                (org != null && org.isNotEmpty) ||
                !ui.interactive) {
              rethrow;
            }
            ui.hint('$fqhn belongs to an organization. Pick yours.');
            org = pickOrg(knownOrgsFile, source.state.session!.email);
            await bind(org);
            host = await enrollOnce();
          }
        } on IdrSourceException catch (e) {
          if (e.code != 'ENROLLMENT_PENDING') rethrow;
          // Not a failure: the admin hasn't decided yet.
          if (!ui.interactive) {
            ui.result(
                {'status': 'pending', 'target': fqhn, 'message': e.message},
                human: () {
              ui.info(e.message);
              ui.hint(translateSourceError(e)!.hint!);
            });
            return CliExit.connect;
          }
          // A person is watching: wait here instead of asking them to rerun.
          ui.hint(shownZone == null
              ? 'Ask the Target admin to approve it: `idrt` > Pending '
                  'approvals.'
              : 'Ask an admin of zone $shownZone to approve it: `idrt` > Pending '
                  'approvals.');
          host = await ui.task(
            'Waiting for the admin to approve (Ctrl+C stops; '
            '`idr enroll` resumes)',
            () async {
              while (true) {
                try {
                  return await source.enroll(
                    fqhn: fqhn,
                    sourceLabel: argResults!['label'] as String?,
                    zone: zone,
                  );
                } on IdrSourceException catch (e) {
                  if (e.code != 'ENROLLMENT_PENDING') rethrow;
                }
              }
            },
            done: (h) => 'Source device approved: $h',
          );
        }
        ui.result(
          {
            'status': 'approved',
            'target': fqhn,
            'sourceHost': host,
            'org': boundOrg,
            'zone': zone,
          },
          human: () {
            writeAttention(source);
            ui.hint('Next: idr connect');
          },
        );
        return CliExit.ok;
      });
}
