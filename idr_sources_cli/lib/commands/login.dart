import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';

import '../bootstrap.dart';

class LoginCommand extends Command<int> {
  LoginCommand() {
    argParser.addFlag(
      'force',
      abbr: 'f',
      help: 'Re-run Google SSO even if a session already exists.',
      negatable: false,
    );
  }

  @override
  String get name => 'login';

  @override
  String get description =>
      'Sign in with Google via billing SSO (then run enroll).';

  @override
  Future<int> run() => withSource((source) async {
        final force = argResults!['force'] as bool;
        final existing = source.state.session;
        if (!force && existing != null) {
          ui.result({'account': existing.email, 'alreadySignedIn': true},
              human: () {
            ui.info('Already signed in as ${existing.email}.');
            ui.hint('Use --force to sign in again.');
          });
          return CliExit.ok;
        }
        final session = await ui.task(
          'Waiting for sign-in in your browser',
          () => source.login(force: force),
          done: (s) => 'Signed in as ${s.email}.',
        );
        final enrolled = await source.enrolledSourceHost();
        ui.result({'account': session.email, 'enrolledAs': enrolled},
            human: () {
          writeAttention(source);
          // In a terminal the home menu follows instead.
          if (enrolled == null && !ui.interactive) {
            ui.hint('Next: idr enroll <target-fqhn>');
          }
        });
        return CliExit.ok;
      });
}
