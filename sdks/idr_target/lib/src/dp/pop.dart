import 'dart:convert';

import '../crypto/idr_crypto.dart';

/// Build EdDSA proof-of-possession for agent token mint.
class PopBuilder {
  PopBuilder(this.crypto);

  final IdrCrypto crypto;

  static String _b64url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  /// Proof payload `{ski,ts}` as a compact JWS (`header.payload.signature`),
  /// matching Billing `compactVerify` / jose `CompactSign`.
  Map<String, dynamic> buildProof({
    required String privatePem,
    required String ski,
    int? timestampSeconds,
  }) {
    final ts =
        timestampSeconds ?? DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final headerB64 = _b64url(utf8.encode('{"alg":"EdDSA"}'));
    final payloadB64 =
        _b64url(utf8.encode(jsonEncode({'ski': ski, 'ts': ts})));
    final signingInput = '$headerB64.$payloadB64';
    final sigB64 = crypto.sign(
      privatePem: privatePem,
      message: utf8.encode(signingInput),
    );
    return {
      'ts': ts,
      'signature': '$signingInput.$sigB64',
    };
  }
}
