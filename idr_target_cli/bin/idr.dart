import 'dart:io';

import 'package:idr_cli_core/idr_cli_core.dart' show runCliWithTelemetry;
import 'package:idr_target/idr_target.dart' show IdrFlavor;
import 'package:idr_target_cli/cli.dart';

/// `idr [--flavor dev|staging|prod] …`: the flavor's `config/<name>.json`
/// sets the endpoints (default: prod when compiled, dev under `dart run`;
/// see [IdrFlavor]).
Future<void> main(List<String> args) async {
  final List<String> rest;
  try {
    rest = IdrFlavor.init(args);
  } catch (e) {
    stderr.writeln('error: $e');
    exitCode = 2;
    return;
  }
  exitCode = await runCliWithTelemetry(
    service: 'idr',
    version: idrtVersion,
    args: rest,
    body: () => runIdrtCli(rest),
  );
}
