import 'dart:io';

import 'package:idr_target_cli/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runIdrtCli(args);
}
