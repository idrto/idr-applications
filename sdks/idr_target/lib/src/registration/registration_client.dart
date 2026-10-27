import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth.dart';

import '../errors.dart';
import 'registration.dart';

/// Ensure personal email entity + register host label → verified FQHN (`host--entity.idr.to`).
class RegistrationClient {
  RegistrationClient({
    required this.controlPlaneUrl,
    required this.store,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String controlPlaneUrl;
  final SessionStore store;
  final http.Client _http;

  String get _base => controlPlaneUrl.replaceAll(RegExp(r'/$'), '');

  /// @Deprecated
  String get apiBaseUrl => controlPlaneUrl;
  /// @Deprecated
  String get billingBaseUrl => controlPlaneUrl;

  static const _regKey = 'registration';

  Future<IdrTargetRegistration?> load() async {
    final j = await store.readJson(_regKey);
    if (j == null) return null;
    return IdrTargetRegistration.fromJson(j);
  }

  Future<void> save(IdrTargetRegistration reg) =>
      store.writeJson(_regKey, reg.toJson());

  Future<void> clear() => store.deleteSecret(_regKey);

  /// Bearer = billing access JWT; cookie / x-idr-session-token = BA session.
  Map<String, String> _authHeaders(IdrAuthSession session) =>
      BaHeaders.forSession(session);

  /// Personal: create/fetch entity from session email on control plane.
  Future<String> ensureEmailEntity(IdrAuthSession session) async {
    final r = await ensureEmailEntityDetailed(session);
    return r.entityId;
  }

  /// Lookup whether the personal email entity already exists (no create).
  Future<({String entityId, bool exists})> lookupEmailEntity(
    IdrAuthSession session,
  ) async {
    final email = session.email.trim().toLowerCase();
    if (email.isEmpty) {
      throw StateError('session email required for personal entity');
    }
    final headers = _authHeaders(session);

    final billRes = await _http.get(
      Uri.parse('$_base/api/v1/registration/entities/email'),
      headers: headers,
    );
    if (billRes.statusCode == 200) {
      final body = _unwrapData(jsonDecode(billRes.body));
      return (
        entityId: (body['entityId'] as String?) ?? email,
        exists: body['exists'] == true,
      );
    }
    if (billRes.statusCode == 404 && _isEntityNotFoundBody(billRes.body)) {
      return (entityId: email, exists: false);
    }

    throw StateError(
      'lookup entity failed (${billRes.statusCode}): ${billRes.body}',
    );
  }

  /// Same as [ensureEmailEntity], plus whether the entity was newly created.
  Future<({String entityId, bool created})> ensureEmailEntityDetailed(
    IdrAuthSession session,
  ) async {
    final email = session.email.trim().toLowerCase();
    if (email.isEmpty) {
      throw StateError('session email required for personal entity');
    }
    if (session.token.trim().isEmpty) {
      throw StateError('access token missing — sign in again');
    }

    final url = '$_base/api/v1/registration/entities/email';
    final create = await _http.post(
      Uri.parse(url),
      headers: {
        ..._authHeaders(session),
        'content-type': 'application/json',
      },
      body: '{}',
    );
    if (create.statusCode == 201 || create.statusCode == 200) {
      final body = _unwrapData(jsonDecode(create.body));
      final createdFlag = body['created'];
      return (
        entityId: (body['entityId'] as String?) ?? email,
        created: createdFlag is bool
            ? createdFlag
            : create.statusCode == 201,
      );
    }
    if (create.statusCode == 409) {
      return (entityId: email, created: false);
    }
    throw StateError(
      'ensure entity failed (${create.statusCode}) $url: ${create.body}',
    );
  }

  static bool _isEntityNotFoundBody(String body) {
    // Entity miss: {"error":"not_found"} — not Fastify "Route POST:… not found".
    return body.contains('"error":"not_found"') ||
        body.contains('"exists":false');
  }

  /// Register host label (e.g. `laptop`). Returns verified
  /// `host[.zone]--entity.idr.to`: an Enterprise [zone] is part of the name.
  Future<IdrTargetRegistration> registerHost({
    required IdrAuthSession session,
    required String entityId,
    required String hostLabel,
    required String machineSki,
    String? payingPartyId,
    String? publicJwkJson,
    String role = 'target',
    String? zone,
  }) async {
    final label = _normalizeHostLabel(hostLabel);

    final hostRes = await _http.post(
      Uri.parse('$_base/api/v1/hosts'),
      headers: {
        ..._authHeaders(session),
        'content-type': 'application/json',
        if (payingPartyId != null) 'x-paying-party-id': payingPartyId,
      },
      body: jsonEncode({
        'entityId': entityId,
        'hostLabel': label,
        'machineSki': machineSki,
        'role': role,
        if (zone != null) 'zone': zone,
        if (publicJwkJson != null) 'publicJwk': jsonDecode(publicJwkJson),
      }),
    );

    if (hostRes.statusCode >= 200 && hostRes.statusCode < 300) {
      final body = _unwrapData(jsonDecode(hostRes.body));
      final fqhn = (body['verifiedFqhn'] as String?) ??
          (body['host'] as String?) ??
          (body['fqhn'] as String?);
      if (fqhn == null || fqhn.isEmpty) {
        throw StateError('host register missing verifiedFqhn');
      }
      if (zone != null && !fqhn.startsWith('$label.$zone--')) {
        // An older billing drops the zone; never serve a name without it.
        throw StateError(
          'host register returned $fqhn without zone $zone; update billing',
        );
      }
      final reg = IdrTargetRegistration(
        entityId: (body['entityId'] as String?) ?? entityId,
        verifiedFqhn: fqhn,
        hostLabel: label,
        machineSki: machineSki,
        seatId: body['seatId'] as String?,
        payingPartyId:
            (body['payingPartyId'] as String?) ?? payingPartyId,
      );
      await save(reg);
      return reg;
    }

    final body = hostRes.body;
    if (body.contains('device_seat_limit')) {
      throw IdrTargetException.forCode(IdrTargetErrorCode.quotaExceeded);
    }
    if (hostRes.statusCode == 409 ||
        body.contains('CONFLICT') ||
        body.contains('already bound')) {
      throw IdrTargetException(
        code: IdrTargetErrorCode.hostAlreadyRegistered,
        message: 'host register conflict (${hostRes.statusCode}): $body',
      );
    }

    throw StateError(
      'host register failed (${hostRes.statusCode}): $body',
    );
  }

  Future<({String brandId, bool available})> checkBrandAvailable(
    IdrAuthSession session,
    String brand,
  ) async {
    final uri = Uri.parse('$_base/api/v1/registration/brand-available')
        .replace(queryParameters: {'brand': brand});
    final res = await _http.get(uri, headers: _authHeaders(session));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('brand check failed (${res.statusCode}): ${res.body}');
    }
    final body = _unwrapData(jsonDecode(res.body));
    return (
      brandId: body['brandId'] as String? ?? brand,
      available: body['available'] == true,
    );
  }

  Future<({String verifiedFqhn, bool available})> checkHostAvailable({
    required IdrAuthSession session,
    required String entityId,
    required String hostLabel,
    String? zone,
  }) async {
    final uri = Uri.parse('$_base/api/v1/registration/host-available').replace(
      queryParameters: {
        'entityId': entityId,
        'hostLabel': hostLabel,
        if (zone != null) 'zone': zone,
      },
    );
    final res = await _http.get(uri, headers: _authHeaders(session));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('host check failed (${res.statusCode}): ${res.body}');
    }
    final body = _unwrapData(jsonDecode(res.body));
    return (
      verifiedFqhn: body['verifiedFqhn'] as String? ?? '',
      available: body['available'] == true,
    );
  }

  Map<String, dynamic> _unwrapData(dynamic decoded) {
    if (decoded is Map<String, dynamic>) {
      if (decoded['data'] is Map) {
        return Map<String, dynamic>.from(decoded['data'] as Map);
      }
      return decoded;
    }
    return {};
  }

  String _normalizeHostLabel(String label) {
    final t = label.trim().toLowerCase();
    if (t.isEmpty || t.contains('--')) {
      throw ArgumentError('invalid host label');
    }
    return t;
  }
}
