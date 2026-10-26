import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';

import '../bootstrap.dart';
import 'connect.dart';

class ModelsCommand extends Command<int> {
  @override
  String get name => 'models';

  @override
  String get description =>
      'List models of the active service (* marks the active one).';

  @override
  Future<int> run() => withSource((source) async {
        await connectWithProgress(source);
        final service = source.state.activeService;
        if (service == null) {
          throw const CliError(
            CliExit.usage,
            'No active service.',
            hint: 'Run `idr active <service>` first.',
            code: 'SERVICE_REQUIRED',
          );
        }
        final models = await source.listModels();
        final active = source.state.activeModel;
        ui.result(
          {'service': service, 'activeModel': active, 'models': models},
          human: () {
            if (models.isEmpty) {
              ui.info('No models returned for $service.');
            }
            for (final m in models) {
              ui.info('${m == active ? '*' : ' '} $m');
            }
          },
        );
        return CliExit.ok;
      });
}
