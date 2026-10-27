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
        String host;
        Future<String> enrollOnce() => ui.task(
              'Enrolling with $fqhn',
              () => source.enroll(
                fqhn: fqhn,
                sourceLabel: argResults!['label'] as String?,
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
