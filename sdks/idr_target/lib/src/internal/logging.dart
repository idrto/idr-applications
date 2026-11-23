import 'package:idr_telemetry/idr_telemetry.dart';

const _log = IdrLog('idr_target.sdk');

/// Steps slower than this also log `target.phase.slow` at WARN.
const slowPhaseMs = 3000;

/// Diagnostic note routed through idr_telemetry (redacted before it is stored).
/// Without an initialised Telemetry (tests, bare SDK use) it falls back to stdout.
/// Never pass secrets/JWTs/private keys.
void idrLog(String message) {
  // Without Telemetry (bare SDK use, tests) nothing is printed: stdout belongs to the caller.
  if (Telemetry.instance == null) return;
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
    if (Telemetry.instance != null) {
      final ms = clock.elapsedMilliseconds;
      final attrs = {'phase': phase, 'duration_ms': ms, 'outcome': outcome};
      _log.info('target.phase.completed', attrs: attrs);
      // A step that takes this long is what a user experiences as "stuck": make it findable.
      if (ms >= slowPhaseMs) {
        _log.warn('target.phase.slow', errorType: 'slow_phase', attrs: {...attrs, 'threshold_ms': slowPhaseMs});
      }
    }
  }
}

/// A named, registered event (spec/telemetry/events.yaml). [errorType] makes it a WARN with
/// [error] as its (redacted) message. Never pass secrets, tokens or personal data in [attrs].
void idrEvent(String event, {Map<String, Object?>? attrs, String? errorType, Object? error}) {
  if (Telemetry.instance == null) return;
  if (errorType == null) {
    _log.info(event, attrs: attrs);
  } else {
    _log.warn(event, errorType: errorType, attrs: attrs, msg: error?.toString(), error: error);
  }
}

/// A line of agent output, kept at DEBUG: the agent writes its own structured logs.
void idrDebugLine(String source, String line) {
  if (Telemetry.instance == null) return;
  _log.debug('target.sdk.agent_output', lazy: () => {'source': source}, msg: line);
}
