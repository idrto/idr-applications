import 'dart:io';

import 'package:idr_cli_core/idr_cli_core.dart' show runCliWithTelemetry;
import 'package:idr_source/idr_source.dart' show IdrFlavor;
import 'package:idr_sources_cli/bootstrap.dart' show idrVersion;
import 'package:idr_sources_cli/cli.dart';

/// `idrs [--flavor dev|staging|prod] …`: the flavor's `config/<name>.json`
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
    service: 'idrs',
    version: idrVersion,
    args: rest,
    body: () async {
      if (flavorError != null) {
        stderr.writeln('error: $flavorError');
        return 2;
      }
      return runIdrCli(rest);
    },
  );
}
