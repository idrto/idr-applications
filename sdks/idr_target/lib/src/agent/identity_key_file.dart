import 'dart:convert';
import 'dart:typed_data';

import 'package:idr_dp_ffi/idr_dp_ffi.dart';

export 'package:idr_dp_ffi/idr_dp_ffi.dart'
    show
        ed25519Pkcs8PemFromPrivateJwk,
        ed25519SeedFromPkcs8Pem,
        ed25519PrivateJwk;

/// Encode Flutter target identity as the Rust agent `KeyPair` JSON file.
///
/// Agent `identity_key_path` expects either PKCS#8 PEM or this JSON shape.
String agentIdentityKeyJson({
  required String privatePem,
  required String publicB64url,
}) {
  final seed = ed25519SeedFromPkcs8Pem(privatePem);
  final pub = _b64UrlDecode(publicB64url);
  if (pub.length != 32) {
    throw StateError('target identity public key must be 32 bytes');
  }
  return jsonEncode({
    'signing_key': seed,
    'verifying_key': pub,
  });
}

Uint8List _b64UrlDecode(String s) {
  var t = s.replaceAll('-', '+').replaceAll('_', '/');
  switch (t.length % 4) {
    case 2:
      t += '==';
      break;
    case 3:
      t += '=';
      break;
  }
  return Uint8List.fromList(base64Decode(t));
}
