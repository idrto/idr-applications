import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth.dart';

/// Better Auth DP enroll CSR inbox on the control plane.
class EnrollClient {
  EnrollClient({
    required this.controlPlaneUrl,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String controlPlaneUrl;
  final http.Client _http;

  String get _base => controlPlaneUrl.replaceAll(RegExp(r'/$'), '');

  Map<String, String> _headers(IdrAuthSession session, {bool jsonBody = false}) =>
      BaHeaders.forSession(session, jsonBody: jsonBody);

  /// Ensure DP entity root exists (server keygen in non-production).
  /// Returns rootAdmin ski + privateJwk when newly created / returned.
  Future<Map<String, dynamic>> kickstartEntity({
    required IdrAuthSession session,
    required String entityId,
    String package = 'personal',
    Map<String, dynamic>? rootPublicJwk,
    Map<String, dynamic>? adminPublicJwk,
    Map<String, dynamic>? rootCredential,
    Map<String, dynamic>? adminCredential,
    String? caCertPem,
  }) async {
    final res = await _http.post(
      Uri.parse('$_base/api/auth/delegate-permissions/kickstart-entity'),
      headers: _headers(session, jsonBody: true),
      body: jsonEncode({
        'entityId': entityId,
        'package': package,
        if (rootPublicJwk != null) 'rootPublicJwk': rootPublicJwk,
        if (adminPublicJwk != null) 'adminPublicJwk': adminPublicJwk,
        if (rootCredential != null) 'rootCredential': rootCredential,
        if (adminCredential != null) 'adminCredential': adminCredential,
        if (caCertPem != null) 'caCertPem': caCertPem,
      }),
    );
    if (res.statusCode == 409) {
      return {'entityId': entityId, 'exists': true};
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'kickstart-entity failed (${res.statusCode}): ${res.body}',
      );
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Whether the DP Entity CA exists (Admin kickstart). Not a Billing email row.
  Future<bool> entityExists({
    required IdrAuthSession session,
    required String entityId,
  }) async {
    final id = entityId.trim().toLowerCase();
    if (id.isEmpty) {
      throw StateError('entityId required');
    }
    final uri = Uri.parse(
      '$_base/api/auth/delegate-permissions/entity',
    ).replace(queryParameters: {'entityId': id});
    final res = await _http.get(uri, headers: _headers(session));
    if (res.statusCode == 200) {
      final decoded = jsonDecode(res.body);
      if (decoded is Map && decoded['exists'] is bool) {
        return decoded['exists'] as bool;
      }
      return decoded is Map && decoded['entityId'] != null;
    }
    if (res.statusCode == 404) {
      return false;
    }
    throw StateError(
      'entity lookup failed (${res.statusCode}): ${res.body}',
    );
  }

  /// Create pending CSR enroll. Returns enrollId + pullToken.
  Future<Map<String, dynamic>> create({
    required IdrAuthSession session,
    required String entityId,
    required String host,
    required String csrPem,
    required Map<String, dynamic> publicJwk,
    String kind = 'machine_target',
    String? subjectSki,
  }) async {
    final res = await _http.post(
      Uri.parse('$_base/api/auth/delegate-permissions/enroll-create'),
      headers: _headers(session, jsonBody: true),
      body: jsonEncode({
        'entityId': entityId,
        'host': host,
        'kind': kind,
        'csrPem': csrPem,
        'publicJwk': publicJwk,
        if (subjectSki != null) 'subjectSki': subjectSki,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('enroll-create failed (${res.statusCode}): ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<List<Map<String, dynamic>>> listPending({
    required IdrAuthSession session,
    required String entityId,
  }) async {
    final uri = Uri.parse(
      '$_base/api/auth/delegate-permissions/enroll-list',
    ).replace(queryParameters: {
      'entityId': entityId,
      'status': 'pending',
    });
    final res = await _http.get(uri, headers: _headers(session));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('enroll-list failed (${res.statusCode}): ${res.body}');
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final list = body['enrollments'] as List? ?? const [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<Map<String, dynamic>> approve({
    required IdrAuthSession session,
    required String enrollId,
    required String leafPem,
    required String chainPem,
    Map<String, dynamic>? credential,
    String? issuerSki,
    Map<String, dynamic>? issuerPrivateJwk,
    String? payingPartyId,
  }) async {
    final res = await _http.post(
      Uri.parse('$_base/api/auth/delegate-permissions/enroll-approve'),
      headers: _headers(session, jsonBody: true),
      body: jsonEncode({
        'enrollId': enrollId,
        'leafPem': leafPem,
        'chainPem': chainPem,
        if (credential != null) 'credential': credential,
        if (issuerSki != null) 'issuerSki': issuerSki,
        if (issuerPrivateJwk != null) 'issuerPrivateJwk': issuerPrivateJwk,
        if (payingPartyId != null) 'payingPartyId': payingPartyId,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('enroll-approve failed (${res.statusCode}): ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> reject({
    required IdrAuthSession session,
    required String enrollId,
  }) async {
    final res = await _http.post(
      Uri.parse('$_base/api/auth/delegate-permissions/enroll-reject'),
      headers: _headers(session, jsonBody: true),
      body: jsonEncode({'enrollId': enrollId}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('enroll-reject failed (${res.statusCode}): ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Register a root-signed zone authority (credential + zone CA cert).
  ///
  /// Org and member come from [session] server-side; the credential is sent
  /// as signed, since the signature covers its exact fields.
  Future<Map<String, dynamic>> issueDelegate({
    required IdrAuthSession session,
    required String issuerSki,
    required Map<String, dynamic> credential,
    required String zone,
    required String zoneCertPem,
  }) async {
    final res = await _http.post(
      Uri.parse('$_base/api/auth/delegate-permissions/issue-delegate'),
      headers: _headers(session, jsonBody: true),
      body: jsonEncode({
        'kind': 'zone_authority',
        'issuerSki': issuerSki,
        'credential': credential,
        'zone': zone,
        'zoneCertPem': zoneCertPem,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'issue-delegate failed (${res.statusCode}): ${_serverMessage(res)}',
      );
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Replace a zone's policy with a root-signed zone credential. Returns
  /// `allowedServices` + `policyVersion` as billing stored them.
  Future<Map<String, dynamic>> setZonePolicy({
    required IdrAuthSession session,
    required Map<String, dynamic> credential,
  }) async {
    final res = await _http.post(
      Uri.parse('$_base/api/auth/delegate-permissions/zone-policy'),
      headers: _headers(session, jsonBody: true),
      body: jsonEncode({'credential': credential}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'zone-policy failed (${res.statusCode}): ${_serverMessage(res)}',
      );
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// Active zone authorities of the session's org.
  Future<List<Map<String, dynamic>>> listDelegates({
    required IdrAuthSession session,
  }) async {
    final res = await _http.get(
      Uri.parse('$_base/api/auth/delegate-permissions/delegates'),
      headers: _headers(session),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'delegates failed (${res.statusCode}): ${_serverMessage(res)}',
      );
    }
    final zones = (jsonDecode(res.body) as Map)['zones'] as List? ?? const [];
    return [for (final z in zones) Map<String, dynamic>.from(z as Map)];
  }

  /// Revoke a credential (member, Target or zone authority) by SKI; org
  /// owner only. Returns `ski`, `status`, `reason`.
  Future<Map<String, dynamic>> revokeCredential({
    required IdrAuthSession session,
    required String ski,
    String? reason,
  }) async {
    final res = await _http.post(
      Uri.parse('$_base/api/v1/machine-authn/credential-revoke'),
      headers: _headers(session, jsonBody: true),
      body: jsonEncode({'ski': ski, if (reason != null) 'reason': reason}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'credential-revoke failed (${res.statusCode}): ${_serverMessage(res)}',
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    return Map<String, dynamic>.from(body['data'] as Map? ?? body);
  }

  /// The org's issued credentials (members, Targets, zone authorities) as
  /// billing records them; org owner only. Each has `ski`, `host`, `kind`,
  /// `status`, `seatId`.
  Future<List<Map<String, dynamic>>> listCredentials({
    required IdrAuthSession session,
  }) async {
    final res = await _http.get(
      Uri.parse('$_base/api/v1/machine-authn/credential-list'),
      headers: _headers(session),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'credential-list failed (${res.statusCode}): ${_serverMessage(res)}',
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = body['data'] as Map? ?? body;
    final list = data['credentials'] as List? ?? const [];
    return [for (final c in list) Map<String, dynamic>.from(c as Map)];
  }

  /// `error` (+ `code`) from a billing error body, else the raw body.
  static String _serverMessage(http.Response res) {
    try {
      final j = jsonDecode(res.body) as Map;
      final code = j['code'];
      return '${j['error'] ?? res.body}${code is String ? ' [$code]' : ''}';
    } catch (_) {
      return res.body;
    }
  }

  /// Pull approved enrollment by pullToken (no session required).
  Future<Map<String, dynamic>> pull({required String pullToken}) async {
    final res = await _http.post(
      Uri.parse('$_base/api/auth/delegate-permissions/enroll-pull'),
      headers: {
        'content-type': 'application/json',
        'accept': 'application/json',
        'flutter-origin': BaHeaders.flutterOrigin,
      },
      body: jsonEncode({'pullToken': pullToken}),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError('enroll-pull failed (${res.statusCode}): ${res.body}');
    }
    return jsonDecode(res.body) as Map<String, dynamic>;
  }
}
