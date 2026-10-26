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
      );
  }

  @override
  String get name => 'enroll';

  @override
  String get description =>
      'Enroll this machine as a Source device for a Target (Admin approves).';

  @override
  String get invocation =>
      'idr enroll [<target-fqhn>] [--label <name>] [--org <slug>]';

  @override
  String get usageFooter => '\nExamples:\n'
      '  idr enroll laptop--you@example.com\n'
      '  idr enroll gpu-box--admin@acme.com --org acme --label alice-laptop';

  @override
  Future<int> run() => withSource((source) async {
        requireSignedIn(source);
        final org = (argResults!['org'] as String?)?.trim();
        String? boundOrg;
        if (org != null && org.isNotEmpty) {
          final bound = await ui.task(
            'Binding to organization $org',
            () => source.bindOrganization(org),
            done: (b) => 'Bound to ${b.name} (${b.slug}) as ${b.role}.',
          );
          boundOrg = bound.slug;
          rememberOrg(knownOrgsFile, source.state.session!.email, bound.slug,
              bound.name);
        }
        final fqhn = ui.ask(
          'Target FQHN (e.g. gpu-box--admin@acme.com)',
          value: argResults!.rest.firstOrNull ?? source.state.fqhn,
          flag: '<target-fqhn>',
        );
        final String host;
        try {
          host = await ui.task(
            'Enrolling with $fqhn',
            () => source.enroll(
              fqhn: fqhn,
              sourceLabel: argResults!['label'] as String?,
            ),
            done: (h) => 'Source device approved: $h',
          );
        } on IdrSourceException catch (e) {
          if (e.code != 'ENROLLMENT_PENDING') rethrow;
          // Not a failure: the admin hasn't decided yet.
          ui.result({'status': 'pending', 'target': fqhn, 'message': e.message},
              human: () {
            ui.info(e.message);
            ui.hint(translateSourceError(e)!.hint!);
          });
          return CliExit.connect;
        }
        ui.result(
          {
            'status': 'approved',
            'target': fqhn,
            'sourceHost': host,
            'org': boundOrg,
          },
          human: () {
            writeAttention(source);
            ui.hint('Next: idr connect');
          },
        );
        return CliExit.ok;
      });
}
