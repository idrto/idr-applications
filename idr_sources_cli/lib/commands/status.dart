import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_source/idr_source.dart';

import '../bootstrap.dart';
import '../prefs/cli_prefs.dart';

class StatusCommand extends Command<int> {
  @override
  String get name => 'status';

  @override
  String get description =>
      'Show sign-in, enrollment, last Target and active service/model.';

  @override
  Future<int> run() => withSource((source) async {
        final s = source.state;
        final cfg = source.config;
        final data = {
          'mode': cfg.mode.name,
          'api': cfg.apiBase,
          'discovery': cfg.discoveryUrl,
          'configDir': cliConfigDirectory().path,
          'account': s.session?.email,
          'enrolledAs': await source.enrolledSourceHost(),
          'lastTarget': s.fqhn,
          'activeService': s.activeService,
          'activeModel': s.activeModel,
          'ready': readyName(s.ready),
          'attention': s.attention == null
              ? null
              : {'code': s.attention!.code, 'message': s.attention!.message},
        };
        ui.result(data, human: () {
          ui.fields({
            'mode': data['mode'],
            'api': data['api'],
            'discovery': data['discovery'],
            'config dir': data['configDir'],
            'account': data['account'] ?? '(signed out)',
            'enrolled as': data['enrolledAs'] ?? '(not enrolled)',
            'last target': data['lastTarget'] ?? '(none)',
            'active': s.activeService == null
                ? '(none)'
                : '${s.activeService}'
                    '${s.activeModel == null ? '' : ' · ${s.activeModel}'}',
            'ready': data['ready'],
          });
          writeAttention(source);
        });
        return CliExit.ok;
      });
}

String readyName(SourceReadyStep step) => switch (step) {
      SignedOut() => 'signed_out',
      SignedIn() => 'signed_in',
      Connected() => 'connected',
      ServiceActive() => 'service_active',
    };
