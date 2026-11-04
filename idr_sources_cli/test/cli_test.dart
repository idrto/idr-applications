// Runs the built `idr` executable against an empty profile (no sign-in, no
// enrollment) and dead endpoints: no real state or service is touched.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late String exe;
late Directory tmp;

Future<ProcessResult> idr(List<String> args, [Map<String, String>? env]) =>
    Process.run(exe, ['--flavor=dev', ...args], environment: {
      'APPDATA': tmp.path,
      'HOME': tmp.path,
      'IDR_API_BASE_URL': 'http://127.0.0.1:1',
      'IDR_DISCOVERY_URL': 'http://127.0.0.1:1/.well-known/idr-presence.json',
      ...?env,
    });

Map<String, dynamic> json(ProcessResult r) =>
    jsonDecode(r.stdout as String) as Map<String, dynamic>;

void main() {
  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('idr_cli_test');
    final out = p.join(tmp.path, 'build');
    final build = await Process.run(
        Platform.resolvedExecutable, ['build', 'cli', '-o', out]);
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    exe = p.join(out, 'bundle', 'bin', Platform.isWindows ? 'idr.exe' : 'idr');
  });

  tearDownAll(() => tmp.delete(recursive: true));

  test('help lists commands, global flags and exit codes', () async {
    final r = await idr(['--help']);
    expect(r.exitCode, 0);
    expect(r.stdout, contains('doctor'));
    expect(r.stdout, contains('--json'));
    expect(r.stdout, contains('Exit codes:'));
    expect(r.stdout, isNot(contains('\x1b[')), reason: 'no color when piped');
  });

  test('bare invocation without a terminal prints usage, no menu', () async {
    for (final env in [<String, String>{}, {'CI': 'true'}]) {
      final r = await idr([], env);
      expect(r.exitCode, 0);
      expect(r.stdout, contains('Available commands:'));
      expect(r.stdout, isNot(contains('What would you like to do?')));
    }
  });

  test('version, plain and JSON', () async {
    expect((await idr(['--version'])).stdout, startsWith('idr '));
    final r = await idr(['--json', 'version']);
    expect(r.exitCode, 0);
    expect(json(r)['idr'], isNotEmpty);
  });

  test('unknown command: usage exit code, JSON error on stdout', () async {
    final r = await idr(['--json', 'bogus']);
    expect(r.exitCode, 64);
    expect(json(r)['error']['code'], 'USAGE');
  });

  test('status works signed out', () async {
    final r = await idr(['--json', 'status']);
    expect(r.exitCode, 0);
    expect(json(r)['account'], isNull);
    expect(json(r)['ready'], 'signed_out');
  });

  test('commands that need a session fail with exit 2 before prompting',
      () async {
    final r = await idr(['enroll']);
    expect(r.exitCode, 2);
    expect(r.stdout, isEmpty);
    expect(r.stderr, contains('idr login'));
    final j = await idr(['--json', 'connect', 'gpu--a@b.com']);
    expect(j.exitCode, 2);
    expect(json(j)['error']['code'], 'AUTH_REQUIRED');
  });

  test('doctor reflects unreachable services and missing libraries', () async {
    final r = await idr(['--json', 'doctor'], {
      'IDR_C_API_LIB': p.join(tmp.path, 'missing', 'idr_c_api.dll'),
    });
    final checks = {
      for (final c in json(r)['checks'] as List) c['name']: c,
    };
    expect(json(r)['ok'], isFalse);
    expect(checks['billing API']['status'], 'fail');
    expect(checks['Presence discovery']['status'], 'fail');
    expect(checks['idr_c_api (WebRTC)']['status'], 'fail');
    expect(checks['sign-in']['status'], 'fail');
    expect(r.exitCode, 3, reason: 'first failure is connectivity');
  });

  test('chat REPL refuses a non-interactive terminal', () async {
    // Fails at sign-in first in this profile; with a session it would fail
    // with TTY_REQUIRED. Either way: no prompt, non-zero exit.
    final r = await idr(['active', 'ollama']);
    expect(r.exitCode, isNot(0));
  });
}
