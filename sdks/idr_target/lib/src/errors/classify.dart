import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:two_key_dart_sdk/two_key_headless.dart';

import 'attention.dart';
import 'codes.dart';
import 'exception.dart';
import 'messages.dart';

/// Maps low-level failures to [IdrTargetAttention] with stable, non-technical copy.
abstract final class IdrTargetErrors {
  /// Classify [error] for UI attention. Never returns [error.toString()] dumps.
  static IdrTargetAttention attentionFor(
    Object error, {
    required String apiBase,
    IdrTargetErrorCode fallbackCode = IdrTargetErrorCode.configInvalid,
    String context = 'this step',
  }) {
    if (error is IdrTargetException) {
      return IdrTargetAttention(code: error.code, message: error.message);
    }

    if (error is BillingAuthException) {
      final code =
          IdrTargetErrorCode.tryParse(error.code ?? '') ?? fallbackCode;
      return IdrTargetAttention(code: code, message: error.message);
    }

    if (_isNetworkFailure(error)) {
      final refused = _isConnectionRefused(error);
      return IdrTargetAttention(
        code: IdrTargetErrorCode.networkUnavailable,
        message: refused
            ? IdrTargetErrorMessages.authUnreachable(apiBase)
            : IdrTargetErrorMessages.networkUnavailable(apiBase),
      );
    }

    if (error is TimeoutException) {
      return IdrTargetAttention(
        code: IdrTargetErrorCode.networkUnavailable,
        message: context == 'sign-in'
            ? IdrTargetErrorMessages.signInTimeout
            : IdrTargetErrorMessages.networkUnavailable(apiBase),
      );
    }

    final text = error.toString().toLowerCase();

    if (text.contains('could not open browser') || text.contains('launchurl')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.authRequired,
        message: IdrTargetErrorMessages.browserLaunchFailed,
      );
    }

    if (text.contains('hostconflict') ||
        text.contains('host conflict') ||
        text.contains('duplicate_host') ||
        text.contains('already taken')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.duplicateHost,
        message: IdrTargetErrorMessages.duplicateHost,
      );
    }

    if (text.contains('host_already_registered') ||
        text.contains('already registered')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.hostAlreadyRegistered,
        message: IdrTargetErrorMessages.hostAlreadyRegistered,
      );
    }

    if (text.contains('auth_expired') || text.contains('session expired')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.authExpired,
        message: IdrTargetErrorMessages.authExpired,
      );
    }

    if (text.contains('auth_revoked') || text.contains('token revoked')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.authRevoked,
        message: IdrTargetErrorMessages.authRevoked,
      );
    }

    if (text.contains('entitlement_missing') ||
        text.contains('entitlement missing')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.entitlementMissing,
        message: IdrTargetErrorMessages.entitlementMissing,
      );
    }

    if (text.contains('entitlement_revoked')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.entitlementRevoked,
        message: IdrTargetErrorMessages.entitlementRevoked,
      );
    }

    if (text.contains('billing_required') || text.contains('payment_required')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.billingRequired,
        message: IdrTargetErrorMessages.billingRequired,
      );
    }

    if (text.contains('billing_unavailable')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.billingUnavailable,
        message: IdrTargetErrorMessages.billingUnavailable,
      );
    }

    if (text.contains('presence_unavailable') ||
        text.contains('presence unavailable')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.presenceUnavailable,
        message: IdrTargetErrorMessages.presenceUnavailable,
      );
    }

    if (text.contains('presence_rejected')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.presenceRejected,
        message: IdrTargetErrorMessages.presenceRejected,
      );
    }

    if (text.contains('device_seat_limit')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.quotaExceeded,
        message: IdrTargetErrorMessages.quotaExceeded,
      );
    }

    if (text.contains('quota') || text.contains('volume_exhausted')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.quotaExceeded,
        message: IdrTargetErrorMessages.quotaExceeded,
      );
    }

    if (text.contains('subscription') ||
        text.contains('entitlement_expired') ||
        text.contains('subscription_expired')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.entitlementExpired,
        message: IdrTargetErrorMessages.entitlementExpired,
      );
    }

    if (text.contains('device_revoked')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.deviceRevoked,
        message: IdrTargetErrorMessages.deviceRevoked,
      );
    }

    if (text.contains('host_revoked')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.hostRevoked,
        message: IdrTargetErrorMessages.hostRevoked,
      );
    }

    if (text.contains('host_disabled')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.hostDisabled,
        message: IdrTargetErrorMessages.hostDisabled,
      );
    }

    if (text.contains('host_rejected') || text.contains('registration denied')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.hostRejected,
        message: IdrTargetErrorMessages.hostRejected,
      );
    }

    if (text.contains('root_certificate_expired') ||
        text.contains('cert expired') ||
        text.contains('certificate expired')) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.rootCertificateExpired,
        message: IdrTargetErrorMessages.rootCertificateExpired,
      );
    }

    if (text.contains('root_certificate_invalid') ||
        (text.contains('certificate') && text.contains('invalid'))) {
      return const IdrTargetAttention(
        code: IdrTargetErrorCode.rootCertificateInvalid,
        message: IdrTargetErrorMessages.rootCertificateInvalid,
      );
    }

    if (text.contains('sign-in/social') || text.contains('missing url')) {
      return IdrTargetAttention(
        code: IdrTargetErrorCode.authRequired,
        message: IdrTargetErrorMessages.httpFailed(_httpStatusFrom(text) ?? 502),
      );
    }

    return IdrTargetAttention(
      code: fallbackCode,
      message: IdrTargetErrorMessages.unexpected(context),
    );
  }

  static bool _isNetworkFailure(Object error) {
    if (error is SocketException) return true;
    if (error is HandshakeException) return true;
    if (error is http.ClientException) {
      return _looksLikeNetwork(error.message) ||
          _looksLikeNetwork(error.toString());
    }
    if (error is HttpException) return _looksLikeNetwork(error.message);
    return _looksLikeNetwork(error.toString());
  }

  static bool _isConnectionRefused(Object error) {
    if (error is SocketException) {
      return error.osError?.errorCode == 1225 || // Windows WSAECONNREFUSED
          error.osError?.errorCode == 111 || // Linux ECONNREFUSED
          error.osError?.errorCode == 61 || // macOS ECONNREFUSED
          _looksLikeRefused(error.message);
    }
    if (error is http.ClientException) {
      return _looksLikeRefused(error.message) ||
          _looksLikeRefused(error.toString());
    }
    return _looksLikeRefused(error.toString());
  }

  static bool _looksLikeNetwork(String s) {
    final t = s.toLowerCase();
    return t.contains('socketexception') ||
        t.contains('clientexception') ||
        t.contains('connection refused') ||
        t.contains('refused the network connection') ||
        t.contains('failed host lookup') ||
        t.contains('network is unreachable') ||
        t.contains('connection reset') ||
        t.contains('connection timed out') ||
        t.contains('timed out') ||
        t.contains('errno = 1225') ||
        t.contains('errno = 111') ||
        t.contains('errno = 61');
  }

  static bool _looksLikeRefused(String s) {
    final t = s.toLowerCase();
    return t.contains('connection refused') ||
        t.contains('refused the network connection') ||
        t.contains('errno = 1225') ||
        t.contains('errno = 111') ||
        t.contains('errno = 61');
  }

  static int? _httpStatusFrom(String lower) {
    final m = RegExp(r'\((\d{3})\)').firstMatch(lower);
    if (m == null) return null;
    return int.tryParse(m.group(1)!);
  }
}
