import 'dart:convert';
import 'dart:io';

import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:test/test.dart';

List<Map<String, Object?>> records(Directory root, String service) => [
      for (final f in Directory('${root.path}${Platform.pathSeparator}$service')
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jsonl')))
        for (final l in const LineSplitter().convert(f.readAsStringSync())) jsonDecode(l) as Map<String, Object?>,
    ];

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('idr_cli_tel_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('records the command, exit code and duration, and ends with app.stopping', () async {
    final code = await runCliWithTelemetry(
      service: 'idrs',
      version: '0.2.0',
      args: ['--json', 'connect', 'gpu--acme.idr.to', '--token', 'secret-value'],
      logRoot: root.path,
      body: () async => 4,
    );
    expect(code, 4);
    final all = records(root, 'idrs');
    final invoked = all.singleWhere((r) => r['event'] == 'ui.command.invoked');
    final done = all.singleWhere((r) => r['event'] == 'ui.command.completed');
    expect((invoked['attrs'] as Map)['command'], 'connect', reason: 'first non-flag word only');
    expect((done['attrs'] as Map)['exit_code'], 4);
    expect(done['attrs'], contains('duration_ms'));
    expect(all.last['event'], 'app.stopping');
    expect(jsonEncode(all), isNot(contains('secret-value')), reason: 'argument values never logged');
    expect(jsonEncode(all), isNot(contains('gpu--acme')), reason: 'nor the target name');
  });

  test('an exception in the command is a crash record, exit 70, and still a clean stop', () async {
    final code = await runCliWithTelemetry(
      service: 'idr',
      version: '0.2.0',
      args: ['start'],
      logRoot: root.path,
      body: () async => throw StateError('boom'),
    );
    expect(code, 70);
    expect(Directory('${root.path}${Platform.pathSeparator}crash').listSync(), hasLength(1));
    expect(records(root, 'idr').last['event'], 'app.stopping');
  });

  test('telemetry that cannot start never stops the command', () async {
    final blocker = File('${root.path}${Platform.pathSeparator}notadir')..writeAsStringSync('x');
    final code = await runCliWithTelemetry(
      service: 'idrs',
      version: '0.2.0',
      args: ['x'],
      logRoot: '${blocker.path}${Platform.pathSeparator}sub', // a path under a file: cannot be created
      body: () async => 0,
    );
    expect(code, 0);
  });
}
