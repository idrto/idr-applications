/// Logging helpers — never pass secrets/JWTs/private keys.
void idrLog(String message) {
  // ignore: avoid_print
  print('[idr_target] $message');
}
