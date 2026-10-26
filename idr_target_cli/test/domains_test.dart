import 'package:idr_target/idr_target.dart';
import 'package:idr_target_cli/core/domains.dart';
import 'package:test/test.dart';

const _target = 'ollama-2dbox--syed-2em-2eshah8989-40gmail-2ecom.idr.to';

CustomDomain _domain(String status, {String? errorCode, String? message}) =>
    CustomDomain(
      id: 'id-1',
      domain: 'app.customer.com',
      targetFqhn: 'ollama-box--syed.m.shah8989@gmail.com.idr.to',
      cnameTarget: _target,
      status: status,
      lastError: errorCode == null
          ? null
          : (code: errorCode, message: message!, seen: null),
    );

void main() {
  test('add prints the exact CNAME record, then the check result', () {
    final lines = addReport(_domain('pending',
        errorCode: 'no_cname',
        message: 'app.customer.com has no CNAME record.'));
    expect(lines, contains('  app.customer.com  CNAME  $_target'));
    expect(lines,
        contains('Not verified yet: app.customer.com has no CNAME record.'));
    expect(
        lines.last, 'Then run `idrt provider domain verify app.customer.com`.');
  });

  test('a verified domain says to restart the agent for its certificate', () {
    expect(checkReport(_domain('verified')), [
      'Verified: app.customer.com points to this Target.',
      'Restart `idrt start` so the agent requests its certificate.',
    ]);
  });

  test('certificate line reads the agent status file', () {
    expect(certLine(null), 'certificate: not requested yet');
    expect(
      certLine(AcmeDomainStatus(
        state: 'issued',
        staging: false,
        notAfter: DateTime.utc(2027, 1, 20),
        renewAt: DateTime.utc(2026, 12, 21),
      )),
      'certificate: issued, expires 2027-01-20, renews 2026-12-21',
    );
    expect(
      certLine(const AcmeDomainStatus(
        state: 'failed',
        staging: true,
        lastError: 'ACME authorization invalid',
      )),
      'certificate: failed (staging): ACME authorization invalid',
    );
  });
}
