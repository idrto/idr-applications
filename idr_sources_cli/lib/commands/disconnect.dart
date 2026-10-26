import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';

import '../bootstrap.dart';

class DisconnectCommand extends Command<int> {
  @override
  String get name => 'disconnect';

  @override
  String get description =>
      'Tear down the live WebRTC peer (last Target is kept).';

  @override
  Future<int> run() => withSource((source) async {
        await source.disconnect();
        ui.result({'disconnected': true}, human: () {
          ui.success('Disconnected.');
        });
        return CliExit.ok;
      });
}
