import 'package:idr_session/idr_session.dart';

/// Better Auth + billing request headers for Flutter desktop clients.
class BaHeaders {
  BaHeaders._();

  /// Trusted Flutter deep-link origin (must be in billing `trustedOrigins`).
  static const flutterOrigin = 'scomm://';

  /// Headers for BA cookie-bearing calls (enroll / kickstart / billing).
  static Map<String, String> forSession(
    IdrAuthSession session, {
    bool jsonBody = false,
  }) {
    final cookie = session.sessionCookie;
    // Use flutter-origin only — Better Auth copies it to Origin for BA CSRF.
    // Do not set Origin here: Express CORS rejects custom schemes like scomm://.
    return {
      'accept': 'application/json',
      'flutter-origin': flutterOrigin,
      'authorization': 'Bearer ${session.token}',
      if (jsonBody) 'content-type': 'application/json',
      if (cookie != null && cookie.isNotEmpty) 'cookie': cookie,
    };
  }
}
