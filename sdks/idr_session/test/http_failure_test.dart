import 'package:idr_session/idr_session.dart';
import 'package:test/test.dart';

void main() {
  test('keeps status, code and server message; never the raw body', () {
    const body = '{"error":"host already taken","code":"duplicate_host","token":"eyJ.secret.sig"}';
    final m = httpFailure('host check', 409, body);
    expect(m, 'host check failed (HTTP 409) [duplicate_host]: host already taken');
    expect(m, isNot(contains('secret')));
  });

  test('non-JSON bodies are reduced to the status', () {
    expect(httpFailure('agent/token', 502, '<html>Bearer abc123 upstream</html>'), 'agent/token failed (HTTP 502)');
  });

  test('nested error.message and clipping', () {
    final m = httpFailure('x', 400, '{"error":{"message":"${'a' * 400}"}}');
    expect(m.length, lessThan(340));
    expect(m, endsWith('…'));
  });
}
