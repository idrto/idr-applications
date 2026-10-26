import 'dart:convert';

import 'package:idr_dp_ffi/idr_dp_ffi.dart';

/// Encode secure-storage machine identity as the Rust agent `identity.dp.json`.
///
/// Shape matches `idr_dp::DeviceIdentityJson` (`ski`, `private_jwk`, `credential`).
Map<String, dynamic>? agentDeviceIdentityMap(Map<String, dynamic> stored) {
  final pem = stored['private_pem'] as String?;
  final publicJwkRaw = stored['public_jwk'];
  if (pem == null || pem.isEmpty || publicJwkRaw is! Map) {
    return null;
  }
  final credential = Map<String, dynamic>.from(
    (stored['credential'] as Map?)?.cast<String, dynamic>() ?? {},
  );
  if (credential.isEmpty) return null;
  final issuer = credential['issuerSki'] ?? credential['issuer_ski'];
  final sig = credential['signature'];
  if (issuer is! String ||
      issuer.isEmpty ||
      sig is! String ||
      sig.isEmpty) {
    return null;
  }

  final publicJwk = Map<String, dynamic>.from(publicJwkRaw);
  final x = publicJwk['x'] as String?;
  if (x == null || x.isEmpty) return null;

  final ski = (stored['ski'] as String?) ?? (credential['ski'] as String?);
  if (ski == null || ski.isEmpty) return null;

  final certPem = stored['cert_pem'] as String? ??
      credential.remove('certPem') as String? ??
      credential.remove('cert_pem') as String?;
  final chainPem = stored['chain_pem'] as String? ??
      credential.remove('chainPem') as String? ??
      credential.remove('chain_pem') as String?;
  credential.remove('platformCertPem');
  credential.remove('platformRootPem');
  credential.remove('platformCertCosign');

  final fqhn = stored['fqhn'] as String? ?? credential['host'] as String?;

  return {
    'ski': ski,
    'private_jwk': ed25519PrivateJwk(privatePem: pem, publicJwk: publicJwk),
    'credential': credential,
    'public_jwk': publicJwk,
    if (fqhn != null && fqhn.isNotEmpty) 'fqhn': fqhn,
    if (certPem != null && certPem.isNotEmpty) 'cert_pem': certPem,
    if (chainPem != null && chainPem.isNotEmpty) 'chain_pem': chainPem,
  };
}

String encodeAgentDeviceIdentity(Map<String, dynamic> stored) {
  final map = agentDeviceIdentityMap(stored);
  if (map == null) {
    throw StateError('incomplete machine identity for identity.dp.json');
  }
  return const JsonEncoder.withIndent('  ').convert(map);
}
