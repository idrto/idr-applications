import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth.dart';
import '../crypto/idr_crypto.dart';
import '../dp/pop.dart';

/// Cached entitlement JWT (never log [token]).
class EntitlementToken {
  const EntitlementToken({
    required this.token,
    required this.expiresAt,
    this.targetFqhn,
  });

  final String token;
  final DateTime expiresAt;
  final String? targetFqhn;

  bool get isExpired => DateTime.now().toUtc().isAfter(expiresAt);
  bool shouldRefresh({Duration skew = const Duration(minutes: 5)}) =>
      DateTime.now().toUtc().isAfter(expiresAt.subtract(skew));
}

class AgentTokenClient {
  AgentTokenClient({
    required this.apiBaseUrl,
    required this.store,
    required this.crypto,
    http.Client? httpClient,
  })  : _http = httpClient ?? http.Client(),
        _pop = PopBuilder(crypto);

  final String apiBaseUrl;
  final SessionStore store;
  final IdrCrypto crypto;
  final http.Client _http;
  final PopBuilder _pop;

  String get _base => apiBaseUrl.replaceAll(RegExp(r'/$'), '');
  static const _cacheKey = 'entitlement.jwt';

  Future<EntitlementToken?> loadCached() async {
    final j = await store.readJson(_cacheKey);
    if (j == null) return null;
    return EntitlementToken(
      token: j['token'] as String,
      expiresAt: DateTime.parse(j['expiresAt'] as String),
      targetFqhn: j['targetFqhn'] as String?,
    );
  }

  Future<void> _save(EntitlementToken t) => store.writeJson(_cacheKey, {
        'token': t.token,
        'expiresAt': t.expiresAt.toUtc().toIso8601String(),
        'targetFqhn': t.targetFqhn,
      });

  Future<void> clear() => store.deleteSecret(_cacheKey);

  /// Mint or refresh entitlement JWT. [credential] is the machine CapabilityCredential map.
  Future<EntitlementToken> mint({
    required Map<String, dynamic> credential,
    required String privatePem,
    required String targetIdentityB64url,
    String? sessionCookie,
  }) async {
    final ski = credential['ski'] as String? ??
        crypto.ski(credential['publicJwk'] != null
            ? ((credential['publicJwk'] as Map)['x'] as String? ?? '')
            : '');
    final proof = _pop.buildProof(privatePem: privatePem, ski: ski);

    final headers = <String, String>{
      'content-type': 'application/json',
      'flutter-origin': BaHeaders.flutterOrigin,
      if (sessionCookie != null) 'cookie': sessionCookie,
    };

    final res = await _http.post(
      Uri.parse('$_base/api/auth/agent/token'),
      headers: headers,
      body: jsonEncode({
        'credential': credential,
        'proof': proof,
        'targetIdentity': targetIdentityB64url,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'agent/token failed (${res.statusCode}): ${res.body}',
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (body['data'] as Map<String, dynamic>?) ?? body;
    final token = data['token'] as String?;
    final expiresIn = (data['expiresIn'] as num?)?.toInt() ?? 3600;
    if (token == null || token.isEmpty) {
      throw StateError('agent/token missing token');
    }
    final fqhn = _fqhnFromJwt(token);
    final ent = EntitlementToken(
      token: token,
      expiresAt: DateTime.now().toUtc().add(Duration(seconds: expiresIn)),
      targetFqhn: fqhn,
    );
    await _save(ent);
    return ent;
  }

  /// Best-effort decode of JWT payload for target_fqhn (no signature verify here).
  String? _fqhnFromJwt(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length < 2) return null;
      var payload = parts[1];
      while (payload.length % 4 != 0) {
        payload += '=';
      }
      final json = utf8.decode(base64Url.decode(payload));
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map['target_fqhn'] as String?;
    } catch (_) {
      return null;
    }
  }
}
