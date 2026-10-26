import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:idr_target/idr_target.dart';
import 'package:test/test.dart';

void main() {
  const api = 'http://127.0.0.1:3000';

  group('IdrTargetErrors', () {
    test('maps Windows connection refused to authUnreachable', () {
      final err = http.ClientException(
        'SocketException: The remote computer refused the network connection '
        '(OS Error: The remote computer refused the network connection, errno = 1225), '
        'address = 127.0.0.1, port = 64497',
        Uri.parse('$api/api/auth/sign-in/social'),
      );
      final a = IdrTargetErrors.attentionFor(
        err,
        apiBase: api,
        fallbackCode: IdrTargetErrorCode.authRequired,
        context: 'sign-in',
      );
      expect(a.code, IdrTargetErrorCode.networkUnavailable);
      expect(a.message, IdrTargetMessages.authUnreachable(api));
      expect(a.message.toLowerCase(), isNot(contains('socketexception')));
      expect(a.message.toLowerCase(), isNot(contains('errno')));
    });

    test('maps SocketException errno 1225', () {
      final err = const SocketException(
        'The remote computer refused the network connection',
        osError: OSError('refused', 1225),
      );
      final a = IdrTargetErrors.attentionFor(err, apiBase: api);
      expect(a.code, IdrTargetErrorCode.networkUnavailable);
      expect(a.message, IdrTargetMessages.authUnreachable(api));
    });

    test('preserves IdrTargetException', () {
      const err = IdrTargetException(
        code: IdrTargetErrorCode.authRequired,
        message: IdrTargetMessages.browserLaunchFailed,
      );
      final a = IdrTargetErrors.attentionFor(err, apiBase: api);
      expect(a.code, err.code);
      expect(a.message, err.message);
    });

    test('maps host conflict without dumping stack', () {
      final a = IdrTargetErrors.attentionFor(
        StateError('hostConflict: label taken'),
        apiBase: api,
        fallbackCode: IdrTargetErrorCode.hostNotRegistered,
      );
      expect(a.code, IdrTargetErrorCode.duplicateHost);
      expect(a.message, IdrTargetMessages.hostConflict);
    });

    test('maps device_seat_limit to quotaExceeded, not deviceRevoked', () {
      final a = IdrTargetErrors.attentionFor(
        StateError('host register failed (400): {"code":"device_seat_limit"}'),
        apiBase: api,
        fallbackCode: IdrTargetErrorCode.hostNotRegistered,
      );
      expect(a.code, IdrTargetErrorCode.quotaExceeded);
      expect(a.message, IdrTargetErrorMessages.quotaExceeded);
    });

    test('exposes stable wire codes and user messages', () {
      expect(IdrTargetErrorCode.authRequired.wire, 'AUTH_REQUIRED');
      expect(IdrTargetErrorCode.hostNotRegistered.wire, 'HOST_NOT_REGISTERED');
      expect(
        IdrTargetErrorMessages.of(IdrTargetErrorCode.billingRequired),
        IdrTargetErrorMessages.billingRequired,
      );
      expect(
        IdrTargetErrorCode.tryParse('ENTITLEMENT_EXPIRED'),
        IdrTargetErrorCode.entitlementExpired,
      );
    });
  });
}
