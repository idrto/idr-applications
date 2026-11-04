import 'package:two_key_dart_sdk/two_key_headless.dart';

export 'src/file_auth_storage.dart';
export 'src/flavor.dart';

/// Billing API JWT plus the Better Auth cookie, shared by Source and Target.
class IdrAuthSession {
  const IdrAuthSession({
    required this.token,
    required this.email,
    this.name,
    this.userId,
    this.sessionCookie,
    this.accessExpiresAt,
  });

  /// Access JWT for Billing `/api/v1/*` (Bearer).
  final String token;

  final String email;
  final String? name;
  final String? userId;

  /// Ready-to-send `Cookie` header value for Better Auth endpoints.
  /// Null when only a bearer JWT is known.
  final String? sessionCookie;

  /// When [token] expires; null if unknown.
  final DateTime? accessExpiresAt;

  bool get accessTokenLikelyExpired {
    final exp = accessExpiresAt;
    if (exp == null) return false;
    return DateTime.now().isAfter(exp.subtract(const Duration(seconds: 60)));
  }

  Map<String, dynamic> toJson() => {
        'token': token,
        'email': email,
        'name': name,
        'userId': userId,
        'sessionCookie': sessionCookie,
        'accessExpiresAt': accessExpiresAt?.toUtc().toIso8601String(),
      };

  factory IdrAuthSession.fromJson(Map<String, dynamic> j) {
    final rawExp = j['accessExpiresAt'];
    return IdrAuthSession(
      token: j['token'] as String,
      email: j['email'] as String? ?? '',
      name: j['name'] as String?,
      userId: j['userId'] as String?,
      sessionCookie: j['sessionCookie'] as String?,
      accessExpiresAt: rawExp is String && rawExp.isNotEmpty
          ? DateTime.tryParse(rawExp)?.toUtc()
          : null,
    );
  }

  IdrAuthSession copyWith({
    String? token,
    String? email,
    String? name,
    String? userId,
    String? sessionCookie,
    DateTime? accessExpiresAt,
  }) {
    return IdrAuthSession(
      token: token ?? this.token,
      email: email ?? this.email,
      name: name ?? this.name,
      userId: userId ?? this.userId,
      sessionCookie: sessionCookie ?? this.sessionCookie,
      accessExpiresAt: accessExpiresAt ?? this.accessExpiresAt,
    );
  }
}

/// Mint a billing API JWT from the live Better Auth session. Null if signed out.
Future<IdrAuthSession?> mintIdrSession(BillingAuthClient client) async {
  final live = await client.getSession();
  if (live == null) return null;
  final tokens = await client.acquireApiToken();
  return IdrAuthSession(
    token: tokens.accessToken,
    email: live.user.email ?? '',
    name: live.user.name,
    userId: live.user.id,
    sessionCookie: await client.getSessionCookie(),
    accessExpiresAt: tokens.expiresAt,
  );
}

/// Loopback browser sign-in, then [mintIdrSession]. Null if the browser did not finish.
Future<IdrAuthSession?> signInLoopback({
  required BillingAuthClient client,
  required LoopbackAuthSessionLauncher launcher,
  String provider = 'google',
}) async {
  try {
    final callback = await launcher.bind();
    await client.signInSocial(
      provider: provider,
      callbackURL: callback.toString(),
    );
  } finally {
    await launcher.close();
  }
  return mintIdrSession(client);
}
