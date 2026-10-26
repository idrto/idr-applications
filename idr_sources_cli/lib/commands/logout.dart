import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';

import '../bootstrap.dart';

class LogoutCommand extends Command<int> {
  LogoutCommand() {
    argParser.addFlag(
      'forget-device',
      negatable: false,
      help: 'Also delete this machine\'s Source key and certificate; you must '
          'enroll again. Ask the admin to revoke the old device too.',
    );
  }

  @override
  String get name => 'logout';

  @override
  String get description =>
      'Sign out and clear connection prefs (the enrolled device is kept).';

  @override
  Future<int> run() => withSource((source) async {
        final forget = argResults!['forget-device'] as bool;
        await source.logout(forgetDevice: forget);
        ui.result({'signedOut': true, 'forgotDevice': forget}, human: () {
          ui.success(forget
              ? 'Signed out and forgot this Source device.'
              : 'Signed out. This machine stays enrolled; `idr login` '
                  'resumes.');
        });
        return CliExit.ok;
      });
}
