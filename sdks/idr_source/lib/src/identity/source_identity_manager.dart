import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:idr_dp_ffi/idr_dp_ffi.dart';
import 'package:two_key_dart_sdk/two_key_headless.dart';

import '../errors.dart';

/// Source machine identity (`machine_source` DP enroll) → `idr_dp::DeviceIdentityJson`.
///
/// Stored as the exact JSON the Rust engine consumes
/// (`ski`, `private_jwk`, `credential`, `cert_pem`, `chain_pem`), plus `fqhn`
/// and `pull_token` while an enroll is pending.
class SourceIdentityManager {
  SourceIdentityManager({
    required BillingAuthStorage storage,
    required DelegatePermissionsClient enroll,
    IdrCrypto Function()? crypto,
  })  : _storage = storage,
        _enroll = enroll,
        _crypto = crypto ?? IdrDpCrypto.open;

  static const _key = 'idr.source.identity';

  final BillingAuthStorage _storage;
  final DelegatePermissionsClient _enroll;
  final IdrCrypto Function() _crypto;

  /// Approved identity JSON for `idr_engine_set_dp_identity`, else null.
  Future<String?> approvedIdentityJson() async {
    final j = await _load();
    if (j == null ||
        j['credential'] is! Map ||
        (j['credential'] as Map).isEmpty) {
      return null;
    }
    return jsonEncode(j..remove('pull_token'));
  }

  /// `label--entity` this identity was enrolled for (approved or pending).
  Future<String?> enrolledHost() async => (await _load())?['fqhn'] as String?;

  /// Enroll this machine as a Source for the Target at [targetFqhn]
  /// (`label--entity[.zone]`); [sourceLabel] defaults to the OS hostname.
  ///
  /// Idempotent: a pending enroll for the same entity is polled, an approved one
  /// is returned. Throws `ENROLLMENT_PENDING` if the Admin has not approved yet.
  Future<String> enroll({
    required String targetFqhn,
    String? sourceLabel,
    Duration pullTimeout = const Duration(seconds: 10),
  }) async {
    final entityId = entityIdFromFqhn(targetFqhn);
    final label = _hostLabel(sourceLabel ?? Platform.localHostname);
    final host = '$label--$entityId';

    var stored = await _load();
    if (stored != null && stored['fqhn'] != host) stored = null;

    if (stored == null) {
      IdrCrypto crypto;
      try {
        crypto = _crypto();
      } catch (e) {
        throw IdrSourceException(
          code: 'CRYPTO_UNAVAILABLE',
          message: 'Native idr_dp crypto not available: $e',
          cause: e,
        );
      }
      final keys = crypto.generateEd25519();
      final csr = crypto.buildCsr(privatePem: keys.privatePem, fqhn: host);
      final EnrollCreateResult created;
      try {
        created = await _enroll.enrollCreate(
          entityId: entityId,
          host: host,
          kind: 'machine_source',
          csrPem: csr,
          publicJwk: keys.publicJwk,
          subjectSki: keys.ski,
        );
      } on MachineAuthnException catch (e) {
        throw IdrSourceException(
          code: e.statusCode == 404 ? 'ENTITY_NOT_FOUND' : 'ENROLL_FAILED',
          message: 'Source enroll failed (${e.statusCode}): ${e.body}',
          cause: e,
        );
      }
      stored = {
        'ski': keys.ski,
        'private_jwk': ed25519PrivateJwk(
          privatePem: keys.privatePem,
          publicJwk: keys.publicJwk,
        ),
        'public_jwk': keys.publicJwk,
        'credential': <String, dynamic>{},
        'fqhn': host,
        'pull_token': created.pullToken,
      };
      await _save(stored);
    }

    if ((stored['credential'] as Map).isNotEmpty) return host;

    final EnrollPullApproved approved;
    try {
      approved = await pullEnrollUntilApproved(
        pull: (token) => _enroll.enrollPull(pullToken: token),
        pullToken: stored['pull_token'] as String,
        pullInterval: const Duration(seconds: 2),
        pullTimeout: pullTimeout,
      );
    } on StateError {
      await _storage.removeItem(_key);
      throw const IdrSourceException(
        code: 'ENROLLMENT_REJECTED',
        message: 'The Target Admin rejected this Source device.',
      );
    } on TimeoutException {
      throw IdrSourceException(
        code: 'ENROLLMENT_PENDING',
        message: 'Source device $host is waiting for Target Admin approval. '
            'Run enroll again after approval.',
      );
    }

    // Cert material rides beside the credential; dp_rust's
    // CapabilityCredential only wants the signed claims.
    final cred = Map<String, dynamic>.from(approved.credential?.toJson() ?? {})
      ..removeWhere((k, _) => const {
            'certPem',
            'chainPem',
            'cert_pem',
            'chain_pem',
            'platformCertPem',
            'platformRootPem',
            'platformCertCosign',
          }.contains(k));
    stored
      ..['credential'] = cred
      ..['ski'] = approved.ski ?? stored['ski']
      ..remove('pull_token');
    if (approved.certPem != null) stored['cert_pem'] = approved.certPem;
    if (approved.chainPem != null) stored['chain_pem'] = approved.chainPem;
    await _save(stored);
    return host;
  }

  Future<void> clear() => _storage.removeItem(_key);

  Future<Map<String, dynamic>?> _load() async {
    final raw = await _storage.getItem(_key);
    if (raw == null || raw.isEmpty) return null;
    final j = jsonDecode(raw);
    return j is Map ? Map<String, dynamic>.from(j) : null;
  }

  Future<void> _save(Map<String, dynamic> j) =>
      _storage.setItem(_key, jsonEncode(j));

  /// `label--entity[.zone...]` → `entity`. Throws on a bare DNS name.
  static String entityIdFromFqhn(String fqhn) {
    final s = fqhn.trim().toLowerCase();
    final sep = s.indexOf('--');
    if (sep < 0) {
      throw IdrSourceException(
        code: 'ENROLL_FAILED',
        message: 'Cannot derive entity from "$fqhn" (expected label--entity).',
      );
    }
    final rest = s.substring(sep + 2);
    final dot = rest.indexOf('.');
    // Personal entities are emails (`user@example.com` may contain dots) — only
    // strip a known Presence zone suffix.
    if (dot > 0 && rest.endsWith('.idr.to')) {
      return rest.substring(0, rest.length - '.idr.to'.length);
    }
    return rest;
  }

  static String _hostLabel(String raw) {
    final t = raw.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]+'), '-');
    final label = t.replaceAll('--', '-').replaceAll(RegExp(r'^-+|-+$'), '');
    return label.isEmpty ? 'source' : label;
  }
}
