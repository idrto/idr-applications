import 'dart:async';
import 'dart:io';

import 'package:idr_telemetry/idr_telemetry.dart';

const _log = IdrLog('idr_cli_core.command');

/// Runs a CLI invocation under `idr_telemetry` (docs/observability/01 §3, 07):
///
/// - files under `IDR_LOG_DIR` or the per-OS default log root, `-v` also prints DEBUG+
///   records to stderr;
/// - `ui.command.invoked` / `ui.command.completed{command, exit_code, duration_ms}`; the
///   command is the first non-flag word, never an argument value;
/// - stray async errors become crash records instead of silently killing the process;
/// - the run always ends with `app.stopping`, so recovery can tell a clean exit from a crash.
///
/// Logging never stops the CLI: if telemetry cannot start, [body] simply runs without it.
/// [logRoot] is a test hook.
Future<int> runCliWithTelemetry({
  required String service,
  required String version,
  required List<String> args,
  required Future<int> Function() body,
  String? logRoot,
}) async {
  final verbose = args.contains('-v') || args.contains('--verbose');
  try {
    await Telemetry.init(TelemetryConfig(
      service: service,
      serviceVersion: version,
      logRoot: logRoot ?? defaultLogRoot(),
      filter: Platform.environment['IDR_LOG'] ?? 'info',
      stderrLevel: verbose ? Level.debug : null,
    ));
  } on Object {
    return body();
  }
  final command = args.firstWhere((a) => !a.startsWith('-'), orElse: () => '');
  final clock = Stopwatch()..start();
  _log.info('ui.command.invoked', attrs: {'command': command});
  final done = Completer<int>();
  runGuarded(() async {
    try {
      done.complete(await body());
    } catch (e, st) {
      Telemetry.instance?.recordCrash(e, st);
      done.complete(70); // INTERNAL, as CliRunner maps unknown errors
    }
  });
  final code = await done.future;
  _log.info('ui.command.completed',
      attrs: {'command': command, 'exit_code': code, 'duration_ms': clock.elapsedMilliseconds});
  await Telemetry.shutdown(reason: code == 0 ? 'exit' : 'error');
  return code;
}
