import 'dart:io';

import 'package:idr_cli_core/idr_cli_core.dart';

import 'bootstrap.dart';
import 'commands/transfer.dart';
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
        ('Send a file or folder to this Target', () => _send(target)),
        submenu('File transfers', transfersMenu),
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

/// One path; a folder is sent as a folder. Several files: `idr transfer send`.
List<String> _send(String target) {
  final path = _unquote(ui.ask(
    'File or folder to send',
    flag: '--file <path> / --dir <path>',
    validate: (v) => FileSystemEntity.typeSync(_unquote(v)) == FileSystemEntityType.notFound
        ? 'Not found: ${_unquote(v)}'
        : null,
  ));
  final dir = FileSystemEntity.isDirectorySync(path);
  return ['transfer', 'send', '--target', target, dir ? '--dir' : '--file', path];
}

/// A prompt gets quotes literally (Explorer's "Copy as path" adds them).
String _unquote(String v) {
  final t = v.trim();
  final quoted = t.length > 1 &&
      ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'")));
  return quoted ? t.substring(1, t.length - 1) : t;
}

/// Pending offers to answer, and the full list. Loading asks the Source
/// agent, so a stopped agent shows its "start source-agent run" hint here.
Future<Menu> transfersMenu({String? executable}) async {
  final all = ((await agentTransfer(['list'], executable: executable)) as List)
      .cast<Map<dynamic, dynamic>>();
  final pending = [
    for (final t in all)
      if (t['direction'] == 'incoming' && t['state'] == 'pending') t,
  ];
  return (
    title: 'File transfers',
    header: '${all.length} transfer(s); ${pending.length} waiting for you.',
    items: <MenuItem>[
      for (final t in pending) ...[
        ('Accept ${_contents(t)} from ${t['peer']}', () => ['transfer', 'accept', t['id'] as String]),
        (
          'Accept ${_contents(t)} into a folder…',
          () => [
            'transfer',
            'accept',
            t['id'] as String,
            '--out',
            _unquote(ui.ask('Folder (inside your receive folder or a permitted one)', flag: '--out <dir>')),
          ],
        ),
        ('Reject ${_contents(t)}', () => ['transfer', 'reject', t['id'] as String]),
      ],
      ('Show all transfers', () => ['transfer', 'list']),
      backItem,
    ],
  );
}

/// `photo.png (41 KB)` / `Screenshots +2 (33 MB)`.
String _contents(Map<dynamic, dynamic> t) {
  final s = t['summary'] as Map?;
  if (s == null) return 'transfer ${t['id']}';
  final top = (s['top_level'] as List).join(', ');
  final more = s['more_top_level'] as int? ?? 0;
  final kb = (s['total_bytes'] as int) / 1024;
  final size = kb < 1024 ? '${kb.ceil()} KB' : '${(kb / 1024).toStringAsFixed(1)} MB';
  return '$top${more > 0 ? ' +$more' : ''} ($size)';
}

String? _slugProblem(String value) => RegExp(r'\s').hasMatch(value)
    ? 'No spaces allowed (e.g. acme, or gpu-box--admin@acme.com).'
    : null;
