import 'package:idr_cli_core/idr_cli_core.dart';

import 'bootstrap.dart';
import 'prefs/cli_prefs.dart';

/// `idr`'s home menu: only what fits this machine's state. Every entry runs
/// an existing command; commands ask for anything still missing.
Future<Menu> idrMenu() => withSource((source) async {
  final s = source.state;
  final session = s.session;
  if (session == null) {
    return (
      title: 'IDR',
      header: 'You are not signed in.',
      items: <MenuItem>[
        ('Sign in', () => ['login']),
        exitItem,
      ],
    );
  }
  final enrolled = await source.enrolledSourceHost();
  final target = s.fqhn;
  return (
    title: 'IDR',
    header: [
      'Signed in as ${session.email}',
      enrolled == null
          ? 'Source device: not enrolled yet'
          : 'Source device: enrolled as $enrolled',
      if (target != null) 'Target: $target',
      if (enrolled == null)
        'Next step: enroll this machine with a Target, then an admin approves it.',
      'Zones, approvals and revocation are managed with idrt on the admin '
          'machine.',
    ].join('\n'),
    items: <MenuItem>[
      if (enrolled == null) ...[
        (
          target == null
              ? 'Enroll this machine with a Target'
              : 'Enroll with $target (or check approval)',
          () => ['enroll'],
        ),
        (
          'Enroll into an organization',
          () => [
            'enroll',
            '--org',
            pickOrg(knownOrgsFile, session.email, validate: _slugProblem),
          ],
        ),
      ],
      if (target != null) ...[
        ('Chat or use a service', () => ['active']),
        ('List services', () => ['services']),
        ('List models', () => ['models']),
      ],
      (
        target == null ? 'Connect to a Target' : 'Connect to another Target',
        () => [
          'connect',
          ui.ask(
            'Target FQHN (e.g. gpu-box--admin@acme.com)',
            flag: '<target-fqhn>',
            validate: _slugProblem,
          ),
        ],
      ),
      ('Status', () => ['status']),
      ('Run diagnostics', () => ['doctor', '--connect']),
      (
        'Sign out',
        () =>
            ui.confirm(
              'Sign out? This machine stays enrolled, so '
              'signing in again resumes.',
            )
            ? ['logout']
            : const [],
      ),
      exitItem,
    ],
  );
});

String? _slugProblem(String value) => RegExp(r'\s').hasMatch(value)
    ? 'No spaces allowed (e.g. acme, or gpu-box--admin@acme.com).'
    : null;
