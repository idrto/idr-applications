import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_source/idr_source.dart';

import '../bootstrap.dart';
import 'connect.dart';

Future<int> runServices(IdrSource source) async {
  await connectWithProgress(source);
  final services = await source.listServices();
  ui.result(
    [
      for (final s in services)
        {
          'name': s.name,
          'kind': s.kind,
          'credentialMode': s.credentialMode,
          'requireUpstreamTls': s.requireUpstreamTls,
        },
    ],
    human: () {
      if (services.isEmpty) {
        ui.info('No named services advertised by the Target.');
        return;
      }
      ui.table(
        ['name', 'kind', 'cred', 'tls'],
        [
          for (final s in services)
            [s.name, s.kind, s.credentialMode, s.requireUpstreamTls ? 'yes' : 'no'],
        ],
      );
    },
  );
  return CliExit.ok;
}

class ServicesCommand extends Command<int> {
  @override
  String get name => 'services';

  @override
  String get description =>
      'List the Target\'s services you may use (live catalog).';

  @override
  Future<int> run() => withSource(runServices);
}

/// `idr list services` alias.
class ListCommand extends Command<int> {
  ListCommand() {
    addSubcommand(_ListServicesCommand());
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List resources (services).';
}

class _ListServicesCommand extends Command<int> {
  @override
  String get name => 'services';

  @override
  String get description => 'Alias for `idr services`.';

  @override
  Future<int> run() => withSource(runServices);
}
