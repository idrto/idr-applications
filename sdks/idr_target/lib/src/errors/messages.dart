import 'codes.dart';

/// Canonical user-facing copy for Target SDK errors.
///
/// Apps should display these (or [IdrTargetException.message]) as-is — do not
/// stringify raw network/HTTP exceptions in the UI.
abstract final class IdrTargetErrorMessages {
  static const authRequired = 'Sign in to continue.';
  static const authInvalid =
      'Your sign-in credentials are invalid. Sign in again.';
  static const authExpired = 'Your session expired. Sign in again.';
  static const authRevoked =
      'Your sign-in was revoked. Sign in again or contact your admin.';
  static const authSignatureInvalid =
      'Signed authentication data could not be verified. Sign in again.';

  static const rootNotSigned =
      'Host registration is not properly signed. Complete enrollment first.';
  static const rootSignatureInvalid =
      'The host registration signature is invalid. Re-register this host.';
  static const rootCertificateInvalid =
      'The host certificate could not be verified. Re-enroll this machine.';
  static const rootCertificateExpired =
      'The host certificate has expired. Re-enroll this machine.';

  static const hostNotRegistered = 'Register a host label (e.g. laptop).';
  static const hostAlreadyRegistered =
      'This host is already registered. Choose a different label or use the existing host.';
  static const hostRejected =
      'Host registration was rejected. Contact your admin.';
  static const hostDisabled =
      'This host has been disabled. Contact your admin.';
  static const hostRevoked =
      'This host has been revoked. Re-register the host.';

  static const entitlementMissing =
      'A required product entitlement is missing. Check your plan.';
  static const entitlementExpired =
      'Your entitlement has expired. Check billing, then try again.';
  static const entitlementRevoked =
      'Your entitlement was revoked. Contact your admin.';
  static const quotaExceeded =
      'This plan has no remaining device seats. Buy another bundle, then register this host again.';

  static const billingRequired =
      'A valid billing entitlement is required to continue.';
  static const billingUnavailable =
      'Billing service is unreachable. Try again in a moment.';

  static const presenceUnavailable =
      'Presence server is unreachable. Check your connection and try again.';
  static const presenceRejected =
      'Presence server rejected this Target. Check registration and try again.';
  static const regionUnavailable =
      'The requested region is unavailable. Choose another region.';

  static const configInvalid =
      'Target configuration is invalid. Check settings and try again.';
  static const configMissing =
      'Required configuration is missing. Complete setup and try again.';
  static const enrollmentCertificatesRequired =
      'Signed leaf and chain certificates are required to approve enrollment.';

  static const duplicateHost =
      'That host label is already taken. Choose a different label.';
  static const deviceRevoked =
      'This machine seat was revoked. Re-register the host.';
  static const deviceNotAuthorized =
      'This device is not authorized for this account.';

  static const entityRequired = 'Create or select an entity to continue.';
  static const enrollmentRequired =
      'Machine credential missing — re-register host.';
  static const signedOut = 'Signed out.';
  static const browserLaunchFailed =
      'Could not open a browser for Google sign-in.';
  static const signInTimeout =
      'Sign-in timed out. Try again and complete Google sign-in in the browser.';
  static const agentCrashBudgetExceeded =
      'target-agent crashed too many times.';
  static const noLoginProviders =
      'No sign-in methods are configured on Auth. '
      'Add SSO credentials on the server and try again.';
  static const loginOptionsInvalid =
      'Auth returned an invalid login-options response. Try again in a moment.';
  static const noSdkSupportedProviders =
      'Auth has sign-in methods configured, but this app build cannot use them yet. '
      'Ask your admin to enable Google SSO, or update the app.';
  static const cryptoUnavailable =
      'Desktop crypto unavailable. Build idr-dp-ffi (idr_dp native lib) or inject IdrCrypto.';
  static const tlsKeyMissing =
      'TLS private key is missing. Re-issue certificates for this host.';
  static const certIssueFailed =
      'Could not issue TLS certificates. Check Auth and try again.';
  static const terminatorReloadFailed =
      'TLS terminator reload failed. Check local TLS configuration.';
  static const notImplemented =
      'This capability is not implemented yet.';
  static const unavailable =
      'This capability is currently unavailable.';

  // Backward-compatible aliases for older call sites.
  static const signInRequired = authRequired;
  static const sessionExpired = authExpired;
  static const hostRegistrationRequired = hostNotRegistered;
  static const hostConflict = duplicateHost;
  static const subscriptionInactive = entitlementExpired;
  static const seatRevoked = deviceRevoked;

  /// Auth/Billing unreachable (connection refused, DNS, etc.).
  static String authUnreachable(String apiBase) =>
      'Cannot reach Auth at $apiBase. '
      'Start the Auth/Billing server and try again.';

  /// Transient network / timeout while talking to Auth/Billing.
  static String networkUnavailable(String apiBase) =>
      'Network error reaching Auth at $apiBase. '
      'Check your connection and try again.';

  static String httpFailed(int statusCode) =>
      'Auth request failed (HTTP $statusCode). Try again in a moment.';

  static String agentBinaryMissing(String path) =>
      'target-agent binary not found at $path. Build it and update the path.';

  static String fqhnUnverified(String jwtFqhn, String registeredFqhn) =>
      'Entitlement FQHN ($jwtFqhn) does not match registered host ($registeredFqhn).';

  static String unexpected(String context) =>
      'Something went wrong during $context. Try again.';

  /// Default message for [code] when no contextual override applies.
  static String of(IdrTargetErrorCode code) {
    switch (code) {
      case IdrTargetErrorCode.authRequired:
        return authRequired;
      case IdrTargetErrorCode.authInvalid:
        return authInvalid;
      case IdrTargetErrorCode.authExpired:
        return authExpired;
      case IdrTargetErrorCode.authRevoked:
        return authRevoked;
      case IdrTargetErrorCode.authSignatureInvalid:
        return authSignatureInvalid;
      case IdrTargetErrorCode.rootNotSigned:
        return rootNotSigned;
      case IdrTargetErrorCode.rootSignatureInvalid:
        return rootSignatureInvalid;
      case IdrTargetErrorCode.rootCertificateInvalid:
        return rootCertificateInvalid;
      case IdrTargetErrorCode.rootCertificateExpired:
        return rootCertificateExpired;
      case IdrTargetErrorCode.hostNotRegistered:
        return hostNotRegistered;
      case IdrTargetErrorCode.hostAlreadyRegistered:
        return hostAlreadyRegistered;
      case IdrTargetErrorCode.hostRejected:
        return hostRejected;
      case IdrTargetErrorCode.hostDisabled:
        return hostDisabled;
      case IdrTargetErrorCode.hostRevoked:
        return hostRevoked;
      case IdrTargetErrorCode.entitlementMissing:
        return entitlementMissing;
      case IdrTargetErrorCode.entitlementExpired:
        return entitlementExpired;
      case IdrTargetErrorCode.entitlementRevoked:
        return entitlementRevoked;
      case IdrTargetErrorCode.quotaExceeded:
        return quotaExceeded;
      case IdrTargetErrorCode.billingRequired:
        return billingRequired;
      case IdrTargetErrorCode.billingUnavailable:
        return billingUnavailable;
      case IdrTargetErrorCode.presenceUnavailable:
        return presenceUnavailable;
      case IdrTargetErrorCode.presenceRejected:
        return presenceRejected;
      case IdrTargetErrorCode.regionUnavailable:
        return regionUnavailable;
      case IdrTargetErrorCode.configInvalid:
        return configInvalid;
      case IdrTargetErrorCode.configMissing:
        return configMissing;
      case IdrTargetErrorCode.duplicateHost:
        return duplicateHost;
      case IdrTargetErrorCode.deviceRevoked:
        return deviceRevoked;
      case IdrTargetErrorCode.deviceNotAuthorized:
        return deviceNotAuthorized;
      case IdrTargetErrorCode.networkUnavailable:
        return 'Network unavailable. Check your connection and try again.';
      case IdrTargetErrorCode.entityRequired:
        return entityRequired;
      case IdrTargetErrorCode.enrollmentRequired:
        return enrollmentRequired;
      case IdrTargetErrorCode.fqhnUnverified:
        return 'Entitlement FQHN does not match the registered host.';
      case IdrTargetErrorCode.agentBinaryMissing:
        return 'target-agent binary not found. Build it and update the path.';
      case IdrTargetErrorCode.agentCrashBudgetExceeded:
        return agentCrashBudgetExceeded;
      case IdrTargetErrorCode.tlsKeyMissing:
        return tlsKeyMissing;
      case IdrTargetErrorCode.certIssueFailed:
        return certIssueFailed;
      case IdrTargetErrorCode.terminatorReloadFailed:
        return terminatorReloadFailed;
      case IdrTargetErrorCode.cryptoUnavailable:
        return cryptoUnavailable;
      case IdrTargetErrorCode.notImplemented:
        return notImplemented;
      case IdrTargetErrorCode.unavailable:
        return unavailable;
    }
  }
}

/// Backward-compatible alias for existing imports.
typedef IdrTargetMessages = IdrTargetErrorMessages;
