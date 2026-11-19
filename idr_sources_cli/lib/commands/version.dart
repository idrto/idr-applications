import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';

import '../bootstrap.dart';

class VersionCommand extends Command<int> {
  @override
  String get name => 'version';

  @override
  String get description => 'Print CLI, SDK and Dart versions.';

  @override
  Future<int> run() async {
    final dart = Platform.version.split(' ').first;
    ui.result(
      {'idrs': idrVersion, 'idr_source': idrSourceVersion, 'dart': dart},
      human: () => ui.fields(
          {'idrs': idrVersion, 'idr_source': idrSourceVersion, 'dart': dart}),
    );
    return CliExit.ok;
  }
}
