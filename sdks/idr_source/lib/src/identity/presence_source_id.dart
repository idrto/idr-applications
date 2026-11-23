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
    final ski = j is Map ? j['ski'] : null;
    return ski is String && ski.isNotEmpty ? ski : 'dart';
  } on FormatException {
    return 'dart';
  }
}
