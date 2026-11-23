import 'package:idr_telemetry/idr_telemetry.dart';

const _log = IdrLog('idr_target.sdk');

/// Diagnostic note routed through idr_telemetry (redacted before it is stored).
/// Without an initialised Telemetry (tests, bare SDK use) it falls back to stdout.
/// Never pass secrets/JWTs/private keys.
void idrLog(String message) {
  if (Telemetry.instance == null) {
    // ignore: avoid_print
    print('[idr_target] $message');
    return;
  }
  _log.info('target.sdk.note', msg: message);
}

/// Monotonic phase timing: one `target.phase.completed{phase, duration_ms, outcome}` record.
Future<T> idrTimed<T>(String phase, Future<T> Function() action) async {
  final clock = Stopwatch()..start();
  var outcome = 'error';
  try {
    final result = await action();
    outcome = 'ok';
    return result;
  } finally {
    if (Telemetry.instance == null) {
      // ignore: avoid_print
      print('[idr_target] timing phase=$phase elapsed_ms=${clock.elapsedMilliseconds} outcome=$outcome');
    } else {
      _log.info('target.phase.completed',
          attrs: {'phase': phase, 'duration_ms': clock.elapsedMilliseconds, 'outcome': outcome});
    }
  }
}
