import 'dart:io';

import 'package:idr_source/idr_source.dart';

import 'package:idr_cli_core/idr_cli_core.dart';

/// Interactive chat REPL. Owns transcript/history locally.
Future<int> runChatRepl(IdrSource source) async {
  final history = <ChatTurn>[];
  stdout.writeln(
    '${source.state.activeService}'
    '${source.state.activeModel != null ? " · ${source.state.activeModel}" : ""}'
    '  (/quit /model /models /status)',
  );

  while (true) {
    stdout.write('> ');
    final line = stdin.readLineSync();
    if (line == null) break;
    final text = line.trim();
    if (text.isEmpty) continue;

    if (text == '/quit' || text == '/exit' || text == '/q') {
      return CliExit.ok;
    }

    if (text == '/status') {
      final s = source.state;
      stdout.writeln(
        '${s.fqhn}  ${s.activeService ?? "-"}  ${s.activeModel ?? "-"}',
      );
      continue;
    }

    if (text == '/models') {
      try {
        final models = await source.listModels();
        final active = source.state.activeModel;
        for (final m in models) {
          stdout.writeln('${m == active ? "*" : " "} $m');
        }
      } catch (e) {
        stderr.writeln(redact('models failed: $e'));
      }
      continue;
    }

    if (text.startsWith('/model')) {
      final parts = text.split(RegExp(r'\s+'));
      if (parts.length < 2 || parts[1].isEmpty) {
        stdout.writeln(source.state.activeModel ?? '(none)');
        continue;
      }
      final id = parts.sublist(1).join(' ');
      final svc = source.state.activeService;
      if (svc == null) {
        stderr.writeln('No active service.');
        continue;
      }
      try {
        await source.activate(svc, model: id);
        stdout.writeln(source.state.activeModel);
      } catch (e) {
        stderr.writeln(redact('model switch failed: $e'));
      }
      continue;
    }

    if (text.startsWith('/')) {
      stdout.writeln('Unknown command. Try /quit /model /models /status');
      continue;
    }

    try {
      var sawDelta = false;
      final reply = await source.chat(
        text,
        history: List.of(history),
        onDelta: (delta) async {
          sawDelta = true;
          stdout.write(delta);
          await stdout.flush();
        },
      );
      // Non-streaming backends may return text without calling onDelta.
      if (!sawDelta) {
        if (reply.isEmpty) {
          stdout.writeln('(empty reply)');
        } else {
          stdout.write(reply);
          if (!reply.endsWith('\n')) stdout.writeln();
        }
      } else if (reply.isNotEmpty && !reply.endsWith('\n')) {
        stdout.writeln();
      } else if (reply.isEmpty) {
        stdout.writeln('(empty reply)');
      }
      await stdout.flush();
      history.add(ChatTurn(role: 'user', content: text));
      history.add(ChatTurn(role: 'assistant', content: reply));
    } catch (e) {
      stderr.writeln(redact('chat failed: $e'));
    }
  }
  return CliExit.ok;
}
