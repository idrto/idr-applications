import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_source/idr_source.dart';

import '../bootstrap.dart';

/// Connects (prompting for the Target when none is known) behind a spinner.
Future<void> connectWithProgress(IdrSource source, [String? fqhn]) async {
  requireSignedIn(source);
  final target = fqhn ??
      source.state.fqhn ??
      ui.ask('Target FQHN (e.g. gpu-box--admin@acme.com)',
          flag: '<target-fqhn>');
  await ui.task(
    'Connecting to $target via Presence',
    () => source.ensureConnected(target),
    done: (_) => 'Connected to ${source.state.fqhn}.',
  );
}

class ConnectCommand extends Command<int> {
  @override
  String get name => 'connect';

  @override
  String get description =>
      'Connect to a Target via Presence and list the services you may use.';

  @override
  String get invocation => 'idr connect [<target-fqhn>]';

  @override
  Future<int> run() => withSource((source) async {
        await connectWithProgress(source, argResults!.rest.firstOrNull);
        final s = source.state;
        // idr_c_api reports neither the ICE path (direct/TURN) nor a local
        // port: streams are opened in-process, no tunnel is listening.
        ui.result(
          {
            'target': s.fqhn,
            'transport': 'webrtc',
            'path': null,
            'localPort': null,
            'services': [
              for (final svc in s.services) {'name': svc.name, 'kind': svc.kind},
            ],
            'activeService': s.activeService,
            'activeModel': s.activeModel,
          },
          human: () {
            ui.fields({
              'target': s.fqhn,
              'transport': 'WebRTC data channel via Presence '
                  '(direct/TURN not reported)',
              'local port': 'none (in-process streams, no tunnel)',
            });
            ui.info('');
            if (s.services.isEmpty) {
              ui.info('This Target offers no services to this device.');
              ui.hint(
                'Its policy may allow none, or Presence sent no verified '
                'policy for this session (operator: PRESENCE_SERVICE_TOKEN).',
              );
              return;
            }
            ui.table(
              ['service', 'kind'],
              [for (final svc in s.services) [svc.name, svc.kind]],
            );
            writeAttention(source);
            ui.hint('\nNext: idr active <service>');
          },
        );
        return CliExit.ok;
      });
}
