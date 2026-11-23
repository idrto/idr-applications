import 'dart:io';

import 'package:idr_cli_core/idr_cli_core.dart' show runCliWithTelemetry;
import 'package:idr_target/idr_target.dart' show IdrFlavor;
import 'package:idr_target_cli/cli.dart';

/// `idr [--flavor dev|staging|prod] …`: the flavor's `config/<name>.json`
/// sets the endpoints (default: prod when compiled, dev under `dart run`;
/// see [IdrFlavor]).
Future<void> main(List<String> args) async {
  List<String> rest = args;
  String? flavorError;
  try {
    rest = IdrFlavor.init(args);
  } catch (e) {
    flavorError = '$e'; // reported inside the run so it is also logged
  }
  exitCode = await runCliWithTelemetry(
    service: 'idr',
    version: idrtVersion,
    args: rest,
    body: () async {
      if (flavorError != null) {
        stderr.writeln('error: $flavorError');
        return 2;
      }
      return runIdrtCli(rest);
    },
  );
}
