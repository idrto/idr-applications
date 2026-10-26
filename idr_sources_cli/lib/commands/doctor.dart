import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_source/idr_source.dart';

import '../bootstrap.dart';
import '../prefs/cli_prefs.dart';

class DoctorCommand extends Command<int> {
  DoctorCommand() {
    argParser.addFlag(
      'connect',
      negatable: false,
      help: 'Also connect to the last (or given) Target to test the full path.',
    );
  }

  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check configuration, connectivity, native libraries, sign-in and '
      'enrollment.';

  @override
  String get invocation => 'idr doctor [--connect [<target-fqhn>]]';

  @override
  Future<int> run() => withSource((source) async {
        final cfg = source.config;
        final dir = cliConfigDirectory();
        final session = source.state.session;
        final enrolled = await source.enrolledSourceHost();
        final target = argResults!.rest.firstOrNull ?? source.state.fqhn;
        final checks = <Check>[
          Check('mode', CheckStatus.ok,
              '${cfg.mode.name}${cfg.insecureDev ? ' (insecure dev Presence)' : ''}'),
          dir.existsSync()
              ? Check('config dir', CheckStatus.ok, dir.path)
              : Check('config dir', CheckStatus.warn,
                  '${dir.path} (not created yet)',
                  hint: 'Created on first sign-in (`idr login`).'),
          await httpCheck('billing API', cfg.apiBase,
              hint: 'Start billing, or set IDR_API_BASE_URL.'),
          await httpCheck(
            'Presence discovery',
            cfg.discoveryUrl,
            hint: 'Start Presence, or set IDR_DISCOVERY_URL.',
            expect: (status, body) {
              if (status != 200) return 'HTTP $status';
              try {
                return jsonDecode(body) is Map ? null : 'not a JSON object';
              } on FormatException {
                return 'not a discovery document';
              }
            },
          ),
          libraryCheck(
            'idr_c_api (WebRTC)',
            source.resolvedLibraryPath,
            hint: 'cargo build --release -p idr-c-api --features native, then '
                'copy it next to idr (with OpenSSL libcrypto/libssl on Windows) '
                'or set IDR_C_API_LIB.',
          ),
          dpCheck(
            hint: 'cargo build --release -p idr-dp-ffi, then copy it next to '
                'idr or set IDR_DP_LIB.',
          ),
          session == null
              ? const Check('sign-in', CheckStatus.fail, 'signed out',
                  hint: 'idr login', exitCode: CliExit.auth)
              : Check(
                  'sign-in',
                  CheckStatus.ok,
                  '${session.email}${session.accessTokenLikelyExpired ? ' (access token expired; refreshed on next use)' : ''}',
                ),
          enrolled == null
              ? const Check('identity', CheckStatus.warn,
                  'not enrolled (connects with the bearer token only)',
                  hint: 'idr enroll <target-fqhn> [--org <slug>]')
              : Check('identity', CheckStatus.ok, 'enrolled as $enrolled'),
          target == null
              ? const Check('target', CheckStatus.warn, 'none chosen yet',
                  hint: 'idr connect <target-fqhn>')
              : Check('target', CheckStatus.ok, target),
        ];
        if (argResults!['connect'] as bool) {
          checks.add(await _connectCheck(source, target));
        }
        return reportChecks(checks);
      });

  Future<Check> _connectCheck(IdrSource source, String? target) async {
    const name = 'connection';
    if (target == null) {
      return const Check(name, CheckStatus.skip, 'no Target to connect to');
    }
    try {
      await ui.task('Connecting to $target', () => source.connect(target));
      return Check(name, CheckStatus.ok,
          '${source.state.fqhn}: ${source.state.services.length} service(s)');
    } catch (e) {
      final error = translateSourceError(e) ??
          CliError(CliExit.connect, '$e', code: 'CONNECT_FAILED');
      return Check(name, CheckStatus.fail, error.message,
          hint: error.hint, exitCode: error.exitCode);
    }
  }
}
