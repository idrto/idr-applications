import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_source/idr_source.dart';

import '../bootstrap.dart';
import '../repl/chat_repl.dart';
import 'connect.dart';

class ActiveCommand extends Command<int> {
  ActiveCommand() {
    argParser.addOption(
      'model',
      abbr: 'm',
      help: 'Model id to activate with the service.',
    );
    argParser.addOption(
      'prompt',
      abbr: 'p',
      help: 'Send one message and print the reply (no REPL; works with '
          '--json).',
    );
  }

  @override
  String get name => 'active';

  @override
  String get description =>
      'Activate a Target service; chat services open a REPL.';

  @override
  String get invocation =>
      'idr active [<service>] [--model <id>] [--prompt "<text>"]';

  @override
  String get usageFooter => '\nExamples:\n'
      '  idr active ollama\n'
      '  idr active ollama --model gemma3:1b --prompt "Reply with: pong"';

  @override
  Future<int> run() => withSource((source) async {
        await connectWithProgress(source);
        final serviceName = argResults!.rest.firstOrNull ??
            ui
                .choose<ServiceSelection>(
                  'Which service?',
                  source.state.services,
                  flag: '<service>',
                  display: (s) => '${s.name} (${s.kind})',
                )
                .name;
        final model = argResults!['model'] as String?;
        await ui.task(
          'Activating $serviceName',
          () => source.activate(serviceName, model: model),
          done: (_) => 'Active: ${_label(source)}',
        );

        final active = source.state.activeService?.toLowerCase();
        final kind = source.state.services
                .where((s) => s.name.toLowerCase() == active)
                .firstOrNull ??
            ServiceSelection.fromAdvertisedName(serviceName);
        final prompt = (argResults!['prompt'] as String?)?.trim();
        final data = {
          'service': source.state.activeService,
          'model': source.state.activeModel,
          'kind': kind.kind,
        };

        if (!kind.isChatKind) {
          ui.result({...data, 'chat': false}, human: () {
            ui.info('No chat REPL for ${kind.kind} services.');
          });
          return CliExit.ok;
        }
        if (prompt != null && prompt.isNotEmpty) {
          final reply = await ui.task(
            'Waiting for ${source.state.activeModel ?? serviceName}',
            () => source.chat(prompt),
          );
          ui.result({...data, 'reply': reply}, human: () => ui.info(reply));
          return CliExit.ok;
        }
        if (!ui.interactive) {
          throw const CliError(
            CliExit.usage,
            'The chat REPL needs an interactive terminal.',
            hint: 'Use --prompt "…" to send one message.',
            code: 'TTY_REQUIRED',
          );
        }
        return runChatRepl(source);
      });
}

String _label(IdrSource source) =>
    '${source.state.activeService}'
    '${source.state.activeModel == null ? '' : ' · ${source.state.activeModel}'}';
