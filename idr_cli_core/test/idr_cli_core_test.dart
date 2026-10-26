import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:test/test.dart';

class _Cmd extends Command<int> {
  _Cmd(this.name, this.body);
  @override
  final String name;
  final Future<int> Function() body;
  @override
  String get description => name;
  @override
  Future<int> run() => body();
}

CliRunner _runner() => CliRunner('t', 'test', version: '9.9.9')
  ..addCommand(_Cmd('ok', () async => CliExit.ok))
  ..addCommand(_Cmd('auth', () async => throw const CliError(CliExit.auth, 'no')))
  ..addCommand(_Cmd('boom', () async => throw StateError('bug')))
  ..addCommand(_Cmd('net', () async => throw const SocketException('down')))
  ..addCommand(_Cmd('sdk', () async => throw FormatException('X_CODE')))
  ..addCommand(_Cmd('ask', () async {
    ui.ask('Name', flag: '--name');
    return CliExit.ok;
  }));

/// Answers menu picks from a script instead of the keyboard.
class _ScriptedUi extends Ui {
  _ScriptedUi(this.picks) : super(interactive: true, color: false);
  final List<String> picks;

  @override
  T choose<T extends Object>(String label, List<T> options,
      {required String flag, String Function(T)? display}) {
    final want = picks.removeAt(0);
    return options.firstWhere((o) => (display ?? (x) => '$x')(o) == want);
  }
}

void main() {
  group('redact', () {
    test('masks JWTs, bearer tokens, query tokens, JSON secrets, keys', () {
      const jwt = 'eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiJ4In0.c2lnbmF0dXJl';
      final out = redact('''
token $jwt
Authorization: Bearer abc.DEF-123
http://p/auth/handoff?slug=acme&token=s3cr3t&x=1
{"accessToken":"tok","d":"privscalar","kty":"OKP","x":"pub"}
Cookie: session=abc
-----BEGIN PRIVATE KEY-----
MC4CAQAwBQYDK2VwBCIEIA
-----END PRIVATE KEY-----
''');
      for (final secret in [jwt, 'abc.DEF-123', 's3cr3t', 'tok"', 'privscalar', 'session=abc', 'MC4CAQ']) {
        expect(out, isNot(contains(secret)), reason: secret);
      }
      // Non-secrets survive.
      expect(out, contains('slug=acme'));
      expect(out, contains('"x":"pub"'));
    });

    test('leaves plain text alone', () {
      const s = 'Connected to gpu-box--a@b.com.idr.to (HTTP 200)';
      expect(redact(s), s);
    });
  });

  group('CliRunner.execute', () {
    test('maps outcomes to exit codes', () async {
      expect(await _runner().execute(['ok']), CliExit.ok);
      expect(await _runner().execute(['auth']), CliExit.auth);
      expect(await _runner().execute(['boom']), CliExit.internal);
      expect(await _runner().execute(['net']), CliExit.connect);
      expect(await _runner().execute(['nope']), CliExit.usage);
      expect(await _runner().execute(['--bad-flag']), CliExit.usage);
      expect(await _runner().execute(['--version']), CliExit.ok);
    });

    test('translate hook turns SDK errors into CliErrors', () async {
      final code = await _runner().execute(
        ['sdk'],
        translate: (e) => e is FormatException
            ? CliError(CliExit.config, e.message, code: e.message)
            : null,
      );
      expect(code, CliExit.config);
    });

    test('--json and --no-input disable prompts', () async {
      expect(await _runner().execute(['--no-input', 'ask']), CliExit.usage);
      expect(ui.interactive, isFalse);
      expect(await _runner().execute(['--json', 'ask']), CliExit.usage);
      expect(ui.json, isTrue);
      expect(ui.interactive, isFalse);
    });

    test('--no-color turns color off', () async {
      await _runner().execute(['--no-color', 'ok']);
      expect(ui.color, isFalse);
    });
  });

  test('reportChecks returns the first failure\'s exit code', () {
    ui = Ui(interactive: false, color: false);
    expect(
      reportChecks(const [
        Check('a', CheckStatus.ok, 'fine'),
        Check('b', CheckStatus.warn, 'meh'),
      ]),
      CliExit.ok,
    );
    expect(
      reportChecks(const [
        Check('a', CheckStatus.fail, 'x', exitCode: CliExit.config),
        Check('b', CheckStatus.fail, 'y', exitCode: CliExit.auth),
      ]),
      CliExit.config,
    );
  });

  test('libraryCheck reports missing and unloadable libraries', () {
    expect(libraryCheck('lib', null, hint: 'h').status, CheckStatus.fail);
    final bad = libraryCheck('lib', 'definitely-missing-lib.dll', hint: 'h');
    expect(bad.status, CheckStatus.fail);
    expect(bad.exitCode, CliExit.config);
  });

  test('httpCheck reports an invalid URL as config, a dead port as connect',
      () async {
    expect((await httpCheck('x', 'not a url')).exitCode, CliExit.config);
    final dead = await httpCheck('x', 'http://127.0.0.1:1');
    expect(dead.status, CheckStatus.fail);
    expect(dead.exitCode, CliExit.connect);
  });

  group('menu', () {
    test('runs picked commands, survives failures, returns on Exit', () async {
      var runs = 0;
      var builds = 0;
      late CliRunner runner;
      runner = CliRunner(
        't',
        'test',
        version: '1',
        home: () async {
          builds++;
          return (
            title: 'Home',
            header: 'state $runs',
            items: <MenuItem>[
              ('Count', () => ['count']),
              ('Fail', () => ['auth']),
              ('Cancel', () => const []),
              ('Bad input', () => throw const CliError(CliExit.usage, 'bad')),
              ('Login', () => ['login']),
              exitItem,
            ],
          );
        },
        homeAfter: const {'login'},
      )
        ..addCommand(_Cmd('count', () async => ++runs > 0 ? 0 : 0))
        ..addCommand(_Cmd('auth', () async => throw const CliError(CliExit.auth, 'no')))
        ..addCommand(_Cmd('login', () async => CliExit.ok));
      ui = _ScriptedUi(
          ['Count', 'Fail', 'Cancel', 'Bad input', 'Login', 'Count', 'Exit']);
      final outer = ui;
      expect(await runner.runMenu(), CliExit.ok);
      expect(runs, 2);
      // One build per pick: the menu is re-read after every action, and
      // `login` inside the menu does not open a second menu.
      expect(builds, 7);
      expect(identical(ui, outer), isTrue);
    });

    test('scripts never get the menu', () async {
      var built = false;
      final runner = CliRunner('t', 'test', version: '1', home: () async {
        built = true;
        return (title: 'Home', header: '', items: <MenuItem>[exitItem]);
      }, homeAfter: const {'login'})
        ..addCommand(_Cmd('login', () async => CliExit.ok));
      // Not a terminal under `dart test`: plain behavior.
      expect(await runner.execute(['login']), CliExit.ok);
      expect(await runner.execute([]), CliExit.ok);
      expect(await runner.execute(['--no-input']), CliExit.ok);
      expect(built, isFalse);
    });

    test('ask validates given values and refuses to prompt when off', () {
      ui = Ui(interactive: false, color: false);
      String? noSpaces(String v) => v.contains(' ') ? 'no spaces' : null;
      expect(ui.ask('Org', value: 'acme', flag: '--org', validate: noSpaces),
          'acme');
      expect(
        () => ui.ask('Org', value: 'a b', flag: '--org', validate: noSpaces),
        throwsA(isA<CliError>().having((e) => e.code, 'code', 'INVALID_ARGUMENT')),
      );
      expect(() => ui.ask('Org', flag: '--org'),
          throwsA(isA<CliError>().having((e) => e.exitCode, 'exit', CliExit.usage)));
      expect(ui.confirm('Sure?'), isFalse);
    });
  });

  test('submenus nest, Back returns a level, a broken level goes back up',
      () async {
    final opened = <String>[];
    Submenu level(String name, List<MenuItem> items) => () async {
          opened.add(name);
          if (name == 'broken') throw const CliError(CliExit.connect, 'gone');
          return (title: name, header: '', items: items);
        };
    final runner = CliRunner('t', 'test', version: '1',
        home: level('home', [
          submenu('Zones', level('zones', [
            submenu('fin', level('fin', [backItem])),
            backItem,
          ])),
          submenu('Broken', level('broken', const [])),
          exitItem,
        ]));
    ui = _ScriptedUi(['Zones', 'fin', 'Back', 'Back', 'Broken', 'Exit']);
    expect(await runner.runMenu(), CliExit.ok);
    expect(opened,
        ['home', 'zones', 'fin', 'zones', 'home', 'broken', 'home']);
  });

  test('known orgs: per account, newest first, no duplicates', () {
    final f = File('${Directory.systemTemp.createTempSync('orgs').path}/orgs.json');
    expect(knownOrgs(f, 'a@x.com'), isEmpty);
    rememberOrg(f, 'a@x.com', 'acme', 'Acme');
    rememberOrg(f, 'b@x.com', 'other', 'Other');
    rememberOrg(f, 'a@x.com', 'beta', 'Beta');
    rememberOrg(f, 'a@x.com', 'acme', 'Acme Corp');
    expect([for (final o in knownOrgs(f, 'a@x.com')) o.slug], ['acme', 'beta']);
    expect(knownOrgs(f, 'a@x.com').first.name, 'Acme Corp');
    expect([for (final o in knownOrgs(f, 'b@x.com')) o.slug], ['other']);
  });
}
