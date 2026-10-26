import 'dart:io';

import 'package:idr_sources_cli/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runIdrCli(args);
}
