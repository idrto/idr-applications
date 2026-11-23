import 'dart:convert';
import 'dart:io';

import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_telemetry/idr_telemetry.dart';
import 'package:test/test.dart';

void main() {
  test('window parsing accepts minutes and hours up to 7 days only', () {
    expect(parseWindow('15m'), const Duration(minutes: 15));
    expect(parseWindow('2h'), const Duration(hours: 2));
    expect(parseWindow('24h'), const Duration(hours: 24));
    for (final bad in ['', '0h', '2d', '2', 'h', '999h', '-1h', '2 h']) {
      expect(parseWindow(bad), isNull, reason: bad);
    }
  });

  test('the shared message points at the one support address and never carries the logs', () {
    final id = newId();
    final details = reportDetails(reportId: id, zipName: '$id.zip', zipBytes: 2048, appVersion: 'idrs 0.2.0', flavor: 'cli');
    final body = reportBody(description: 'it broke for a@b.co', details: details, reportId: id);
    expect(reportRecipient, 'dev10@advcomm.ca');
    expect(reportSubject(id), contains(id));
    expect(body, isNot(contains('a@b.co')));
    expect(mailtoLink(reportSubject(id), body), startsWith('mailto:dev10@advcomm.ca?subject='));
  });

  test('diag report builds a ZIP in the log root and sends nothing', () async {
    final root = Directory.systemTemp.createTempSync('idr_diag_cmd_');
    addTearDown(() => root.deleteSync(recursive: true));
    await Telemetry.init(TelemetryConfig(service: 'idrs', serviceVersion: 't', logRoot: root.path));
    addTearDown(Telemetry.shutdown);
    final b = await DiagnosticBundle.collect(window: const Duration(minutes: 30), userNote: 'x');
    expect(b.file.existsSync(), isTrue);
    expect(b.file.path, contains('${Platform.pathSeparator}reports${Platform.pathSeparator}'));
    expect(jsonEncode(b.manifest), contains(b.reportId));
  });
}
