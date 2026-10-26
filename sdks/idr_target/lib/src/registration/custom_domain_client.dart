import 'dart:convert';

import 'package:http/http.dart' as http;

import '../auth/auth.dart';

/// A customer hostname CNAME'd to a Target, as billing records it.
class CustomDomain {
  const CustomDomain({
    required this.id,
    required this.domain,
    required this.targetFqhn,
    required this.cnameTarget,
    required this.status,
    this.lastCheckAt,
    this.verifiedAt,
    this.lastError,
  });

  factory CustomDomain.fromJson(Map<String, dynamic> j) {
    final err = j['lastError'];
    return CustomDomain(
      id: j['id'] as String,
      domain: j['domain'] as String,
      targetFqhn: j['targetFqhn'] as String,
      cnameTarget: j['cnameTarget'] as String,
      status: j['status'] as String,
      lastCheckAt: DateTime.tryParse('${j['lastCheckAt'] ?? ''}'),
      verifiedAt: DateTime.tryParse('${j['verifiedAt'] ?? ''}'),
      lastError: err is Map
          ? (
              code: '${err['code']}',
              message: '${err['message']}',
              seen: err['seen'] as String?,
            )
          : null,
    );
  }

  final String id;
  final String domain;
  final String targetFqhn;

  /// What the customer's CNAME must point at.
  final String cnameTarget;

  /// `pending` | `verified` | `failed` | `removed`.
  final String status;
  final DateTime? lastCheckAt;
  final DateTime? verifiedAt;

  /// Last failed check: billing's code (`no_cname`, `cname_mismatch`, …), a
  /// sentence to show the user, and the CNAME DNS returned.
  final ({String code, String message, String? seen})? lastError;

  bool get verified => status == 'verified';
}

/// Billing refused a custom-domain request (`code` is billing's, e.g.
/// `DOMAIN_INVALID`, `DOMAIN_EXISTS`, `TARGET_NOT_FOUND`).
class CustomDomainException implements Exception {
  const CustomDomainException(this.statusCode, this.code, this.message);

  final int statusCode;
  final String code;
  final String message;

  /// A request the caller can fix (bad name, duplicate, limit, not found).
  bool get isClientError => statusCode >= 400 && statusCode < 500;

  @override
  String toString() => message;
}

/// The agent's per-domain `acme-status.json` (Let's Encrypt certificate).
class AcmeDomainStatus {
  const AcmeDomainStatus({
    required this.state,
    required this.staging,
    this.lastAttemptAt,
    this.lastError,
    this.notAfter,
    this.renewAt,
  });

  factory AcmeDomainStatus.fromJson(Map<String, dynamic> j) => AcmeDomainStatus(
        state: '${j['state']}',
        staging: j['staging'] == true,
        lastAttemptAt: DateTime.tryParse('${j['lastAttemptAt'] ?? ''}'),
        lastError: j['lastError'] as String?,
        notAfter: DateTime.tryParse('${j['notAfter'] ?? ''}'),
        renewAt: DateTime.tryParse('${j['renewAt'] ?? ''}'),
      );

  /// `issuing` | `issued` | `valid` (not due for renewal) | `failed`.
  final String state;
  final bool staging;
  final DateTime? lastAttemptAt;
  final String? lastError;
  final DateTime? notAfter;
  final DateTime? renewAt;
}

/// Billing custom domains (`/api/v1/custom-domains`): customer hostnames
/// CNAME'd to a Target. Owners / admins of the bound org only.
class CustomDomainClient {
  CustomDomainClient({
    required this.controlPlaneUrl,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final String controlPlaneUrl;
  final http.Client _http;

  String get _base =>
      '${controlPlaneUrl.replaceAll(RegExp(r'/$'), '')}/api/v1/custom-domains';

  /// Add [domain] to [targetFqhn]; billing runs the first CNAME check.
  Future<CustomDomain> add({
    required IdrAuthSession session,
    required String targetFqhn,
    required String domain,
  }) async =>
      _one(await _http.post(
        Uri.parse(_base),
        headers: BaHeaders.forSession(session, jsonBody: true),
        body: jsonEncode({'targetFqhn': targetFqhn, 'domain': domain}),
      ));

  Future<List<CustomDomain>> list({
    required IdrAuthSession session,
    String? targetFqhn,
  }) async {
    final res = await _http.get(
      Uri.parse(_base).replace(
        queryParameters: targetFqhn == null ? null : {'targetFqhn': targetFqhn},
      ),
      headers: BaHeaders.forSession(session),
    );
    final rows = _data(res) as List? ?? const [];
    return [
      for (final r in rows.cast<Map>())
        CustomDomain.fromJson(Map<String, dynamic>.from(r)),
    ];
  }

  /// Check the CNAME now (billing returns the stored result within 10 s).
  Future<CustomDomain> verify({
    required IdrAuthSession session,
    required String id,
  }) async =>
      _one(await _http.post(
        Uri.parse('$_base/$id/verify'),
        headers: BaHeaders.forSession(session),
      ));

  Future<CustomDomain> remove({
    required IdrAuthSession session,
    required String id,
  }) async =>
      _one(await _http.delete(
        Uri.parse('$_base/$id'),
        headers: BaHeaders.forSession(session),
      ));

  /// Domains billing has verified for [targetFqhn] (what `[acme].domains` gets).
  Future<List<String>> verifiedDomains({
    required IdrAuthSession session,
    required String targetFqhn,
  }) async =>
      [
        for (final d in await list(session: session, targetFqhn: targetFqhn))
          if (d.verified) d.domain,
      ];

  static CustomDomain _one(http.Response res) =>
      CustomDomain.fromJson(Map<String, dynamic>.from(_data(res) as Map));

  /// Billing's `{ success, data }` body, or a [CustomDomainException].
  static Object? _data(http.Response res) {
    Object? body;
    try {
      body = jsonDecode(res.body);
    } catch (_) {
      body = null;
    }
    if (res.statusCode < 200 || res.statusCode >= 300) {
      final j = body is Map ? body : const {};
      throw CustomDomainException(
        res.statusCode,
        '${j['code'] ?? 'HTTP_${res.statusCode}'}',
        '${j['error'] ?? j['message'] ?? 'custom-domains failed (${res.statusCode})'}',
      );
    }
    return body is Map ? body['data'] : null;
  }
}
