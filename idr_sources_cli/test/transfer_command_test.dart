import 'dart:io';

import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_sources_cli/commands/transfer.dart';
import 'package:idr_sources_cli/menu.dart';
import 'package:test/test.dart';

/// A stand-in `source-agent` that records its arguments and prints [stdout].
Future<String> _fakeAgent(Directory dir, String stdout, {String stderr = '', int exit = 0}) async {
  final args = '${dir.path}${Platform.pathSeparator}args.txt';
  if (Platform.isWindows) {
    final out = File('${dir.path}\\out.txt')..writeAsStringSync(stdout);
    final err = File('${dir.path}\\err.txt')..writeAsStringSync(stderr);
    final f = File('${dir.path}\\agent.cmd')
      ..writeAsStringSync('@echo off\r\necho %* > "$args"\r\ntype "${out.path}"\r\n'
          'type "${err.path}" 1>&2\r\nexit /b $exit\r\n');
    return f.path;
  }
  final f = File('${dir.path}/agent.sh')
    ..writeAsStringSync("#!/bin/sh\necho \"\$@\" > '$args'\nprintf '%s' '$stdout'\nprintf '%s' '$stderr' >&2\nexit $exit\n");
  await Process.run('chmod', ['+x', f.path]);
  return f.path;
}

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('idr-transfer-cli'));
  tearDown(() => dir.delete(recursive: true));

  String recorded() => File('${dir.path}${Platform.pathSeparator}args.txt').readAsStringSync().trim();

  test('passes the subcommand through with --json and returns data', () async {
    final exe = await _fakeAgent(dir, '{"ok": true, "data": [{"id": "ab"}]}');
    final data = await agentTransfer(['list'], executable: exe);
    expect(data, [
      {'id': 'ab'}
    ]);
    expect(recorded(), 'transfer --json list');
  });

  test('a refusal carries the stable error name', () async {
    final exe = await _fakeAgent(dir, '{"ok": false, "error": "unauthorized"}', exit: 1);
    expect(
        () => agentTransfer(['accept', 'ab', '--out', 'x'], executable: exe),
        throwsA(isA<CliError>()
            .having((e) => e.exitCode, 'exitCode', CliExit.failure)
            .having((e) => e.message, 'message', contains('unauthorized'))));
  });

  test('agent not running → connect exit code with a start hint', () async {
    final exe = await _fakeAgent(dir, '',
        stderr: 'Error: source-agent is not running (start it with `source-agent run`)', exit: 1);
    expect(
        () => agentTransfer(['list'], executable: exe),
        throwsA(isA<CliError>()
            .having((e) => e.exitCode, 'exitCode', CliExit.connect)
            .having((e) => e.hint, 'hint', contains('source-agent run'))));
  });

  test('transfers menu offers accept/reject only for pending incoming offers', () async {
    final exe = await _fakeAgent(
        dir,
        '{"ok": true, "data": ['
        '{"id": "p1", "direction": "incoming", "state": "pending", "peer": "lenovo--a@b.idr.to",'
        ' "summary": {"top_level": ["photo.png"], "more_top_level": 0, "total_bytes": 41790}},'
        '{"id": "d1", "direction": "outgoing", "state": "completed", "peer": "lenovo--a@b.idr.to",'
        ' "summary": {"top_level": ["big.bin"], "more_top_level": 0, "total_bytes": 67108864}}]}');
    final menu = await transfersMenu(executable: exe);
    expect(menu.header, '2 transfer(s); 1 waiting for you.');
    expect(menu.items.map((i) => i.$1), [
      'Accept photo.png (41 KB) from lenovo--a@b.idr.to',
      'Accept photo.png (41 KB) into a folder…',
      'Reject photo.png (41 KB)',
      'Show all transfers',
      'Back',
    ]);
    expect(menu.items.first.$2(), ['transfer', 'accept', 'p1']);
    expect(menu.items[2].$2(), ['transfer', 'reject', 'p1']);
  });

  test('missing agent binary → config exit code', () async {
    expect(
        () => agentTransfer(['list'], executable: '${dir.path}/no-such-agent'),
        throwsA(isA<CliError>().having((e) => e.exitCode, 'exitCode', CliExit.config)));
  });
}
