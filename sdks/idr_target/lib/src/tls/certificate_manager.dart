import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../auth/auth.dart';

import '../crypto/idr_crypto.dart';
import '../errors/errors.dart';
import '../internal/logging.dart';
import '../registration/registration.dart';
import 'terminator.dart';
import 'tls_status.dart';

/// Orchestrates TLS leaf lifecycle. No terminator-specific cert logic.
class CertificateManager {
  CertificateManager({
    required this.crypto,
    required this.terminator,
    required this.certDir,
    required this.apiBaseUrl,
    http.Client? httpClient,
  }) : _http = httpClient ?? http.Client();

  final IdrCrypto crypto;
  final IdrTlsTerminator terminator;
  final String certDir;
  final String apiBaseUrl;
  final http.Client _http;

  IdrTlsStatus status = IdrTlsStatus.pending;

  bool isNativeIdrFqhn(String fqhn) =>
      fqhn.toLowerCase().endsWith('.idr.to');

  /// Phase 1: native `*.idr.to` â†’ Relay terminates; no Target leaf.
  Future<IdrTlsStatus> ensurePhase1Native(String verifiedFqhn) async {
    if (isNativeIdrFqhn(verifiedFqhn)) {
      status = IdrTlsStatus.relayTerminated;
      idrLog('TLS Phase 1: Relay terminates $verifiedFqhn (no Target leaf)');
      return status;
    }
    status = IdrTlsStatus.notRequired;
    return status;
  }

  /// Phase 2: Entity-CA leaf for personal/enterprise.
  Future<IdrTlsStatus> ensureEntityCaLeaf({
    required IdrAuthSession session,
    required IdrTargetRegistration registration,
    required String privatePem,
  }) async {
    status = IdrTlsStatus.issuing;
    final fqhn = registration.verifiedFqhn;
    try {
      final csr = crypto.buildCsr(privatePem: privatePem, fqhn: fqhn);
      final leaf = await _requestEntityCaLeaf(
        session: session,
        csrPem: csr,
        fqhn: fqhn,
        entityId: registration.entityId,
      );
      await materialize(
        fullchainPem: leaf,
        privatePem: privatePem,
        fqhn: fqhn,
      );
      await terminator.reload();
      status = IdrTlsStatus.ready;
      return status;
    } catch (e) {
      status = IdrTlsStatus.needsAttention;
      rethrow;
    }
  }

  Future<String> _requestEntityCaLeaf({
    required IdrAuthSession session,
    required String csrPem,
    required String fqhn,
    required String entityId,
  }) async {
    final base = apiBaseUrl.replaceAll(RegExp(r'/$'), '');
    final res = await _http.post(
      Uri.parse('$base/api/v1/certificates/issue'),
      headers: BaHeaders.forSession(session, jsonBody: true),
      body: jsonEncode({
        'entityId': entityId,
        'fqhn': fqhn,
        'csrPem': csrPem,
      }),
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw StateError(
        'Entity-CA issue failed (${res.statusCode}): ${res.body}',
      );
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final data = (body['data'] as Map<String, dynamic>?) ?? body;
    final pem = (data['fullchainPem'] as String?) ??
        (data['certificatePem'] as String?);
    if (pem == null || pem.isEmpty) {
      throw StateError('Entity-CA response missing certificate PEM');
    }
    return pem;
  }

  Future<void> materialize({
    required String fullchainPem,
    required String privatePem,
    required String fqhn,
  }) async {
    final dir = Directory(p.join(certDir, fqhn));
    await dir.create(recursive: true);
    final chain = File(p.join(dir.path, 'fullchain.pem'));
    final key = File(p.join(dir.path, 'privkey.pem'));
    await chain.writeAsString(fullchainPem);
    await key.writeAsString(privatePem);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', key.path]);
    }
  }

  IdrTargetAttention attentionForError(Object e) {
    if (e.toString().toLowerCase().contains('reload')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.terminatorReloadFailed,
        message: IdrTargetErrorMessages.terminatorReloadFailed,
      );
    }
    return const IdrTargetAttention(
      code: IdrTargetErrorCode.certIssueFailed,
      message: IdrTargetErrorMessages.certIssueFailed,
    );
  }
}
