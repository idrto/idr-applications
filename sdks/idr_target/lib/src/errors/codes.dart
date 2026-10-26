/// Stable Target SDK error codes (wire string + app switch).
///
/// Prefer switching on [IdrTargetErrorCode] / [wire]; display
/// [IdrTargetErrorMessages.of] (or a thrown [IdrTargetException.message]) as-is.
enum IdrTargetErrorCode {
  authRequired('AUTH_REQUIRED'),
  authInvalid('AUTH_INVALID'),
  authExpired('AUTH_EXPIRED'),
  authRevoked('AUTH_REVOKED'),
  authSignatureInvalid('AUTH_SIGNATURE_INVALID'),
  rootNotSigned('ROOT_NOT_SIGNED'),
  rootSignatureInvalid('ROOT_SIGNATURE_INVALID'),
  rootCertificateInvalid('ROOT_CERTIFICATE_INVALID'),
  rootCertificateExpired('ROOT_CERTIFICATE_EXPIRED'),
  hostNotRegistered('HOST_NOT_REGISTERED'),
  hostAlreadyRegistered('HOST_ALREADY_REGISTERED'),
  hostRejected('HOST_REJECTED'),
  hostDisabled('HOST_DISABLED'),
  hostRevoked('HOST_REVOKED'),
  entitlementMissing('ENTITLEMENT_MISSING'),
  entitlementExpired('ENTITLEMENT_EXPIRED'),
  entitlementRevoked('ENTITLEMENT_REVOKED'),
  quotaExceeded('QUOTA_EXCEEDED'),
  billingRequired('BILLING_REQUIRED'),
  billingUnavailable('BILLING_UNAVAILABLE'),
  presenceUnavailable('PRESENCE_UNAVAILABLE'),
  presenceRejected('PRESENCE_REJECTED'),
  regionUnavailable('REGION_UNAVAILABLE'),
  configInvalid('CONFIG_INVALID'),
  configMissing('CONFIG_MISSING'),
  duplicateHost('DUPLICATE_HOST'),
  deviceRevoked('DEVICE_REVOKED'),
  deviceNotAuthorized('DEVICE_NOT_AUTHORIZED'),
  networkUnavailable('NETWORK_UNAVAILABLE'),
  entityRequired('ENTITY_REQUIRED'),
  enrollmentRequired('ENROLLMENT_REQUIRED'),
  fqhnUnverified('FQHN_UNVERIFIED'),
  agentBinaryMissing('AGENT_BINARY_MISSING'),
  agentCrashBudgetExceeded('AGENT_CRASH_BUDGET_EXCEEDED'),
  tlsKeyMissing('TLS_KEY_MISSING'),
  certIssueFailed('CERT_ISSUE_FAILED'),
  terminatorReloadFailed('TERMINATOR_RELOAD_FAILED'),
  cryptoUnavailable('CRYPTO_UNAVAILABLE'),
  notImplemented('NOT_IMPLEMENTED'),
  unavailable('UNAVAILABLE');

  const IdrTargetErrorCode(this.wire);

  /// Stable wire / log form (e.g. `AUTH_REQUIRED`).
  final String wire;

  static IdrTargetErrorCode? tryParse(String raw) {
    final key = raw.trim().toUpperCase();
    for (final c in values) {
      if (c.wire == key || c.name.toUpperCase() == key) return c;
    }
    return null;
  }
}

/// Backward-compatible alias — prefer [IdrTargetErrorCode].
typedef IdrTargetAttentionCode = IdrTargetErrorCode;
