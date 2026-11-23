import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idr_target_app/diagnostics/issue_report.dart';
import 'package:idr_target_app/screens/home/report_issue_card.dart';
import 'package:idr_telemetry/idr_telemetry.dart';

const id = '01a20908-3a1d-706f-9566-176d8947efbf';

void main() {
  test('link: fixed recipient, subject with report id, under the length cap', () {
    final details = reportDetails(reportId: id, zipName: '$id.zip', zipBytes: 4096, appVersion: '1.0.0+1', flavor: 'dev');
    final body = reportBody(description: 'x' * 6000, details: details, reportId: id);
    final link = mailtoLink(reportSubject(id), body);
    expect(link, startsWith('mailto:dev10@advcomm.ca?subject=IDR%20issue%20report%20$id&body='));
    expect(link.length, lessThanOrEqualTo(maxLinkChars));
    expect(body, contains('truncated; full text in the ZIP'));
    expect(body, contains('Please attach the ZIP file'));
  });

  test('body is redacted and carries only the fixed details', () {
    final details = reportDetails(reportId: id, zipName: '$id.zip', zipBytes: 1, appVersion: '1.0.0+1', flavor: 'dev');
    final body = reportBody(description: r'fails for alice@example.com at C:\Users\alice\x', details: details, reportId: id);
    expect(body, isNot(contains('alice@example.com')));
    expect(body, isNot(contains(r'\alice\')));
    expect(details, isNot(contains('fqhn')));
  });

  testWidgets('no mail program: shows the fallback, sends nothing', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final dir = Directory.systemTemp.createTempSync('idr_report_');
    addTearDown(() => dir.deleteSync(recursive: true));
    await tester.runAsync(() => Telemetry.init(TelemetryConfig(service: 'idr_target_app', serviceVersion: 't', logRoot: dir.path)));
    addTearDown(() => Telemetry.shutdown());
    var launched = 0;
    final bundle = (await tester.runAsync(() => DiagnosticBundle.collect()))!;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ReportIssueCard(
            build: (d, w) async => ReportResult(bundle, w),
            launch: (u) async {
              launched++;
              expect(u.scheme, 'mailto');
              return false;
            },
            reveal: (d) async {},
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Create report'));
    await tester.pump();
    expect(find.byKey(const Key('report_status')), findsOneWidget, reason: 'an empty description is refused');
    await tester.enterText(find.byKey(const Key('report_description')), 'it broke');
    await tester.tap(find.text('Create report'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Report ${bundle.reportId}'), findsOneWidget);
    expect(launched, 0, reason: 'building a report never opens mail by itself');
    await tester.tap(find.text('Open email'));
    await tester.pumpAndSettle();
    expect(launched, 1);
    expect(find.textContaining('No email program was found'), findsOneWidget);
    expect(find.text('Copy message'), findsOneWidget);
    expect(bundle.file.existsSync(), isTrue, reason: 'the ZIP stays for the user to attach');
  });
}
