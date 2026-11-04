// Runs the built `idrt` executable against an empty profile and dead
// endpoints: no real state, agent or service is touched.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late String exe;
late Directory tmp;

Future<ProcessResult> idrt(List<String> args, [Map<String, String>? env]) =>
    Process.run(exe, ['--flavor=dev', ...args], environment: {
      'APPDATA': tmp.path,
      'HOME': tmp.path,
      'IDR_CONTROL_PLANE_URL': 'http://127.0.0.1:1',
      'IDR_DISCOVERY_URL': 'http://127.0.0.1:1/.well-known/idr-presence.json',
      ...?env,
    });

Map<String, dynamic> json(ProcessResult r) =>
    jsonDecode(r.stdout as String) as Map<String, dynamic>;

void main() {
  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('idrt_cli_test');
    final out = p.join(tmp.path, 'build');
    final build = await Process.run(
        Platform.resolvedExecutable, ['build', 'cli', '-o', out]);
    expect(build.exitCode, 0, reason: '${build.stdout}${build.stderr}');
    exe =
        p.join(out, 'bundle', 'bin', Platform.isWindows ? 'idrt.exe' : 'idrt');
  });

  tearDownAll(() => tmp.delete(recursive: true));

  test('help and version', () async {
    final r = await idrt(['--help']);
    expect(r.exitCode, 0);
    expect(r.stdout, contains('doctor'));
    expect(r.stdout, contains('Exit codes:'));
    expect((await idrt(['--version'])).stdout, startsWith('idrt '));
  });

  test('bare invocation without a terminal prints usage, no menu', () async {
    final r = await idrt([]);
    expect(r.exitCode, 0);
    expect(r.stdout, contains('Available commands:'));
    expect(r.stdout, isNot(contains('What would you like to do?')));
  });

  test('approve and register need a session before asking anything',
      () async {
    expect((await idrt(['personal', 'approve'])).exitCode, 2);
    expect((await idrt(['--json', 'provider', 'register'])).exitCode, 2);
  });

  test('new enterprise commands need a session and never prompt in scripts',
      () async {
    for (final args in [
      ['enterprise', 'zone', 'list'],
      ['enterprise', 'zone', 'show'],
      ['enterprise', 'zone', 'add'],
      ['enterprise', 'devices'],
      ['enterprise', 'members'],
    ]) {
      final r = await idrt(['--json', ...args]);
      expect(r.exitCode, 2, reason: args.join(' '));
      expect(json(r)['ok'], isFalse);
    }
  });

  test('status JSON is valid and free of SDK log lines', () async {
    final r = await idrt(['--json', 'status']);
    expect(r.exitCode, 0);
    expect(r.stdout, isNot(contains('[idr_target]')));
    expect(json(r)['account'], isNull);
  });

  test('start needs a session (exit 2)', () async {
    final r = await idrt(['start']);
    expect(r.exitCode, 2);
    expect(r.stderr, contains('idrt login'));
  });

  test('missing arguments fail fast when not interactive', () async {
    final r = await idrt(['--json', 'services', 'add']);
    expect(r.exitCode, 64);
    expect(json(r)['error']['code'], 'MISSING_ARGUMENT');
  });

  test('doctor reports a missing target-agent and dead endpoints', () async {
    final r = await idrt(['--json', 'doctor'], {
      'IDR_TARGET_AGENT': p.join(tmp.path, 'missing', 'target-agent.exe'),
    });
    final checks = {
      for (final c in json(r)['checks'] as List) c['name']: c,
    };
    expect(checks['billing API']['status'], 'fail');
    expect(checks['target-agent']['status'], 'fail');
    expect(checks['target-agent']['detail'], contains('does not exist'));
    expect(checks['sign-in']['status'], 'fail');
    expect(r.exitCode, isNot(0));
  });
}
