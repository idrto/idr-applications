import 'dart:convert';

/// `"<what> failed (HTTP <status>) [<code>]: <message>"` from a JSON error body.
///
/// Never includes the raw body, which can carry tokens or personal data
/// (agent docs/observability/04 §5.4). Keeps the server's stable `code` and its human
/// `error`/`message` text (clipped), which error classification relies on.
String httpFailure(String what, int status, String body) {
  String? code;
  String? message;
  try {
    final j = jsonDecode(body);
    if (j is Map) {
      final c = j['code'];
      if (c is String && RegExp(r'^[A-Za-z0-9_.\-]{1,64}$').hasMatch(c)) code = c;
      final e = j['error'];
      final m = e is String ? e : (e is Map ? e['message'] : null) ?? j['message'];
      if (m is String && m.trim().isNotEmpty) message = m.length > 300 ? '${m.substring(0, 300)}…' : m;
    }
  } on FormatException {
    // Not JSON (HTML error page, proxy text): report the status only.
  }
  return '$what failed (HTTP $status)${code != null ? ' [$code]' : ''}${message != null ? ': $message' : ''}';
}
