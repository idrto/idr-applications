/// Logging helpers — never pass secrets/JWTs/private keys.
void idrLog(String message) {
  // ignore: avoid_print
  print('[idr_target] $message');
}

/// Monotonic timings for startup diagnostics; never include request payloads.
Future<T> idrTimed<T>(String phase, Future<T> Function() action) async {
  final clock = Stopwatch()..start();
  var outcome = 'error';
  try {
    final result = await action();
    outcome = 'ok';
    return result;
  } finally {
    idrLog(
        'timing phase=$phase elapsed_ms=${clock.elapsedMilliseconds} outcome=$outcome');
  }
}
