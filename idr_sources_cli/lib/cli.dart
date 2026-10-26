import 'package:idr_cli_core/idr_cli_core.dart';

import 'bootstrap.dart';
import 'commands/active.dart';
import 'commands/connect.dart';
import 'commands/disconnect.dart';
import 'commands/doctor.dart';
import 'commands/enroll.dart';
import 'commands/login.dart';
import 'commands/logout.dart';
import 'commands/models.dart';
import 'commands/services.dart';
import 'commands/status.dart';
import 'commands/version.dart';
import 'menu.dart';

Future<int> runIdrCli(List<String> args) => (CliRunner(
      'idr',
      'IDR Source: sign in, enroll this machine, connect to a Target and use '
          'its services.',
      version: idrVersion,
      home: idrMenu,
      homeAfter: const {'login', 'enroll'},
    )
          ..addCommand(LoginCommand())
          ..addCommand(EnrollCommand())
          ..addCommand(LogoutCommand())
          ..addCommand(StatusCommand())
          ..addCommand(ConnectCommand())
          ..addCommand(DisconnectCommand())
          ..addCommand(ServicesCommand())
          ..addCommand(ListCommand())
          ..addCommand(ModelsCommand())
          ..addCommand(ActiveCommand())
          ..addCommand(DoctorCommand())
          ..addCommand(VersionCommand()))
        .execute(args, translate: translateSourceError);
