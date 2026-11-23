import 'dart:convert';

/// The `sourceId` sent to Presence: the enrolled device's `ski` (pseudonymous, already
/// known to Presence), never the user's email, which would otherwise travel to Presence,
/// TURN usernames and coturn logs (docs/observability/09 D9, 04 §5.1).
///
/// With no enrolled device identity (anonymous Source) it is the constant `'dart'`.
String presenceSourceId(String? approvedIdentityJson) {
  if (approvedIdentityJson == null) return 'dart';
  try {
    final j = jsonDecode(approvedIdentityJson);
    // DeviceIdentityJson has `ski` at the top; the CLI's stored identity nests it in `credential`.
    final cred = j is Map ? j['credential'] : null;
    final ski = j is Map ? (j['ski'] ?? (cred is Map ? cred['ski'] : null)) : null;
    return ski is String && ski.isNotEmpty ? ski : 'dart';
  } on FormatException {
    return 'dart';
  }
}
