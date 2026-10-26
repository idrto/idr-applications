/// Shared terminal layer for the `idr` (Source) and `idrt` (Target) CLIs:
/// global flags, output modes (human / JSON), progress, prompts, error
/// rendering, exit codes, secret masking and diagnostic checks.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:cli_completion/cli_completion.dart';
import 'package:idr_dp_ffi/idr_dp_ffi.dart';
import 'package:mason_logger/mason_logger.dart';
// ponytail: not exported; drop if mason_logger restores the cursor itself.
// ignore: implementation_imports
import 'package:mason_logger/src/terminal_overrides.dart';

/// Exit codes shared by both CLIs.
abstract final class CliExit {
  static const ok = 0;

  /// The operation ran but did not succeed (e.g. a domain is not verified yet).
  static const failure = 1;

  /// Not signed in, or the session was rejected.
  static const auth = 2;

  /// Billing, Presence or the Target is unreachable or refused the session;
  /// or the device is not approved yet.
  static const connect = 3;

  /// Subscription missing or expired, or out of seats (`idrt`).
  static const billing = 4;

  /// Bad configuration or a missing native dependency.
  static const config = 5;

  /// Bad command line, or a required value is missing in a non-interactive run.
  static const usage = 64;

  /// Unexpected error (a bug). Rerun with `--verbose` for the stack trace.
  static const internal = 70;

  static const footer =
      'Exit codes: 0 ok, 1 failed, 2 sign-in, '
      '3 connection/approval, 4 billing, 5 config/native, 64 usage, '
      '70 unexpected.';
}

/// Stops a command with a human message, an exit code and an optional hint.
class CliError implements Exception {
  const CliError(this.exitCode, this.message, {this.hint, this.code});

  final int exitCode;
  final String message;
  final String? hint;

  /// Stable machine code for JSON output (e.g. `AUTH_REQUIRED`).
  final String? code;

  @override
  String toString() => message;
}

final _redactions = <(RegExp, String Function(Match))>[
  (
    RegExp(
      r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
    ),
    (_) => '[REDACTED PRIVATE KEY]',
  ),
  (RegExp(r'\beyJ[\w-]+\.[\w-]+\.[\w-]*'), (_) => '[REDACTED JWT]'),
  (
    RegExp(r'(Bearer\s+)[\w.~+/=-]+', caseSensitive: false),
    (m) => '${m[1]}[REDACTED]',
  ),
  (
    RegExp(
      r'([?&](?:token|ott|code|access_token|refresh_token|key|secret|signature|password)=)[^&\s"]+',
      caseSensitive: false,
    ),
    (m) => '${m[1]}[REDACTED]',
  ),
  (
    // JSON secrets, including a JWK's private scalar "d".
    RegExp(
      r'("(?:token|accessToken|access_token|refreshToken|refresh_token|sessionCookie|cookie|privateKey|private_key|secret|password|d)"\s*:\s*")[^"]*"',
    ),
    (m) => '${m[1]}[REDACTED]"',
  ),
  (
    RegExp(r'((?:set-)?cookie:\s*)[^\r\n]+', caseSensitive: false),
    (m) => '${m[1]}[REDACTED]',
  ),
];

/// Masks tokens, JWTs, private keys and cookies in [text].
String redact(String text) {
  var out = text;
  for (final (pattern, replace) in _redactions) {
    out = out.replaceAllMapped(pattern, replace);
  }
  return out;
}

/// The active terminal. Set by [CliRunner.execute]; defaults suit tests.
Ui ui = Ui(interactive: false, color: false);

class Ui {
  Ui({this.json = false, this.verbose = false, bool? color, bool? interactive})
    : color =
          color ??
          (stdout.hasTerminal &&
              stdout.supportsAnsiEscapes &&
              (Platform.environment['NO_COLOR'] ?? '').isEmpty),
      interactive =
          !json &&
          (interactive ??
              (stdin.hasTerminal &&
                  stdout.hasTerminal &&
                  (Platform.environment['CI'] ?? '').isEmpty));

  final bool json;
  final bool verbose;
  final bool color;

  /// Prompts and spinners are allowed.
  final bool interactive;

  final _logger = Logger();
  bool _emitted = false;

  /// Human text goes to stderr in JSON mode so stdout stays one JSON document.
  IOSink get _out => json ? stderr : stdout;

  void info(String message) => _out.writeln(message);

  void success(String message) =>
      _out.writeln('${lightGreen.wrap('✓')} $message');

  void warn(String message) =>
      stderr.writeln('${yellow.wrap('warning:')} $message');

  /// A follow-up command or fix, e.g. `Next: idr connect`.
  void hint(String message) => _out.writeln(darkGray.wrap(message));

  void debug(String message) {
    if (verbose) stderr.writeln(darkGray.wrap(redact(message)));
  }

  /// JSON mode: print [data]. Otherwise run [human].
  void result(Object? data, {required void Function() human}) {
    if (json) {
      emit(data);
    } else {
      human();
    }
  }

  void emit(Object? data) {
    _emitted = true;
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(data));
  }

  /// Aligned `key: value` lines; null values print as `-`.
  void fields(Map<String, Object?> values) {
    final width = values.keys.fold(0, (w, k) => k.length > w ? k.length : w);
    values.forEach((k, v) => info('${'$k:'.padRight(width + 2)}${v ?? '-'}'));
  }

  void table(List<String> headers, List<List<Object?>> rows) {
    final cells = [
      for (final r in rows) [for (final c in r) '${c ?? '-'}'],
    ];
    final widths = [
      for (var i = 0; i < headers.length; i++)
        cells.fold(
          headers[i].length,
          (w, r) => r[i].length > w ? r[i].length : w,
        ),
    ];
    String line(List<String> r) => [
      for (var i = 0; i < r.length; i++)
        i == r.length - 1 ? r[i] : r[i].padRight(widths[i]),
    ].join('  ');
    info(styleBold.wrap(line(headers))!);
    for (final r in cells) {
      info(line(r));
    }
  }

  /// Runs [body] behind a spinner (interactive) or a single stderr line;
  /// [done] is the success line.
  Future<T> task<T>(
    String label,
    Future<T> Function() body, {
    String Function(T value)? done,
  }) async {
    if (!interactive) {
      if (!json) stderr.writeln('$label…');
      final value = await body();
      // Progress stays on stderr so piped stdout holds only results.
      if (!json && done != null) {
        stderr.writeln('${lightGreen.wrap('✓')} ${done(value)}');
      }
      return value;
    }
    final progress = _logger.progress(label);
    try {
      final value = await body();
      progress.complete(done?.call(value) ?? label);
      return value;
    } catch (_) {
      progress.fail(label);
      rethrow;
    }
  }

  /// [value] if given, else a prompt (interactive), else a usage error that
  /// names [flag]. [validate] returns a problem to show, or null; a bad
  /// prompt answer is asked again, a bad [value] is a usage error.
  String ask(
    String label, {
    String? value,
    required String flag,
    String? Function(String value)? validate,
  }) {
    final given = value?.trim();
    if (given != null && given.isNotEmpty) {
      final problem = validate?.call(given);
      if (problem == null) return given;
      throw CliError(CliExit.usage, problem, code: 'INVALID_ARGUMENT');
    }
    if (!interactive) {
      throw CliError(
        CliExit.usage,
        'Missing $flag.',
        hint: 'Pass $flag, or run in an interactive terminal to be asked.',
        code: 'MISSING_ARGUMENT',
      );
    }
    while (true) {
      final answer = _logger.prompt('$label:').trim();
      if (answer.isEmpty) throw CliError(CliExit.usage, '$label is required.');
      final problem = validate?.call(answer);
      if (problem == null) return answer;
      warn(problem);
    }
  }

  /// Yes/no question; [defaultValue] when prompts are off.
  bool confirm(String question, {bool defaultValue = false}) => interactive
      ? _logger.confirm(question, defaultValue: defaultValue)
      : defaultValue;

  /// Picks one of [options] interactively; a usage error naming [flag] otherwise.
  T choose<T extends Object>(
    String label,
    List<T> options, {
    required String flag,
    String Function(T)? display,
  }) {
    if (!interactive || options.isEmpty) {
      throw CliError(
        CliExit.usage,
        'Missing $flag.',
        hint: options.isEmpty
            ? null
            : 'Choose one of: ${options.map(display ?? (o) => '$o').join(', ')}',
        code: 'MISSING_ARGUMENT',
      );
    }
    // Ctrl+C in the menu exits (130); show the cursor the menu hid first.
    return TerminalOverrides.runZoned(
      () => _logger.chooseOne(label, choices: options, display: display),
      exit: (code) {
        stdout.write('\x1B[?25h');
        exit(code);
      },
    );
  }

  void _error(CliError e, [StackTrace? stack]) {
    final message = redact(e.message);
    final hint = e.hint == null ? null : redact(e.hint!);
    if (json) {
      emit({
        'ok': false,
        'error': {
          'code': e.code,
          'message': message,
          'hint': hint,
          'exitCode': e.exitCode,
        },
      });
    } else {
      stderr.writeln('${red.wrap('error:')} $message');
      if (hint != null) stderr.writeln('${darkGray.wrap('hint:')} $hint');
    }
    if (verbose && stack != null) stderr.writeln(redact('$stack'));
  }
}

/// A menu entry and what choosing it does. The action returns one of:
/// - a command line (`List<String>`), run through the same runner; empty
///   means nothing to run (cancelled, or the entry only explained something);
/// - a [Submenu] to open;
/// - null: go back (Exit at the top).
/// The action may prompt for arguments.
typedef MenuItem = (String label, Object? Function() action);

/// Loads a menu for the current state (re-run after every action).
typedef Submenu = Future<Menu> Function();

/// [title] is this level's breadcrumb; [header] is context (may be empty).
typedef Menu = ({String title, String header, List<MenuItem> items});

const MenuItem exitItem = ('Exit', _leave);
const MenuItem backItem = ('Back', _leave);
Object? _leave() => null;

MenuItem submenu(String label, Submenu open) => (label, () => open);

/// An entry that explains why something can't be done here, and how to.
MenuItem explain(String label, String why) => (
  label,
  () {
    ui.info(why);
    return const <String>[];
  },
);

/// Organizations this machine has bound for [email], newest first. Billing
/// does not list memberships, so this is the only list there is.
List<({String slug, String name})> knownOrgs(File file, String email) {
  try {
    return [
      for (final o in jsonDecode(file.readAsStringSync()) as List)
        if (o['email'] == email)
          (slug: o['slug'] as String, name: o['name'] as String),
    ];
  } catch (_) {
    return const [];
  }
}

/// An organization [email] bound on this machine before, or a typed slug.
String pickOrg(File file, String email, {String? Function(String)? validate}) {
  String ask() => ui.ask(
    'Organization slug (from the billing portal)',
    flag: '--org <slug>',
    validate: validate,
  );
  final known = knownOrgs(file, email);
  if (known.isEmpty) return ask();
  const other = '';
  ui.hint(
    'Organizations used on this machine (billing does not list '
    'memberships):',
  );
  final slug = ui.choose(
    'Which organization?',
    [...known.map((o) => o.slug), other],
    flag: '--org <slug>',
    display: (s) => s == other
        ? 'Another organization (enter its slug)'
        : '${known.firstWhere((o) => o.slug == s).name} ($s)',
  );
  return slug == other ? ask() : slug;
}

/// Records a successful bind (from billing's reply) for [knownOrgs].
void rememberOrg(File file, String email, String slug, String name) {
  final others = [
    for (final o in knownOrgsAll(file))
      if (!(o['email'] == email && o['slug'] == slug)) o,
  ];
  file
    ..createSync(recursive: true)
    ..writeAsStringSync(
      jsonEncode([
        {'email': email, 'slug': slug, 'name': name},
        ...others.take(19),
      ]),
    );
}

List<Map<String, dynamic>> knownOrgsAll(File file) {
  try {
    return [
      for (final o in jsonDecode(file.readAsStringSync()) as List)
        Map<String, dynamic>.from(o as Map),
    ];
  } catch (_) {
    return [];
  }
}

/// [CommandRunner] with the shared global flags, completion commands and
/// centralized error handling. Run it with [execute].
///
/// With [home], a bare invocation in a terminal opens an interactive menu,
/// and so does a successful command listed in [homeAfter] (e.g. `login`).
/// Menu entries run the existing commands; scripts never see the menu.
class CliRunner extends CompletionCommandRunner<int> {
  CliRunner(
    super.executableName,
    super.description, {
    required this.version,
    this.home,
    this.homeAfter = const {},
  }) {
    argParser
      ..addFlag(
        'json',
        negatable: false,
        help: 'Print one JSON document on stdout. Implies --no-input.',
      )
      ..addFlag(
        'color',
        defaultsTo: true,
        help:
            'Color output. Also off when NO_COLOR is set or stdout is not '
            'a terminal.',
      )
      ..addFlag(
        'input',
        defaultsTo: true,
        help:
            'Allow prompts. Also off when stdin is not a terminal or CI is '
            'set.',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Show debug logs and stack traces (secrets stay masked).',
      )
      ..addFlag('version', negatable: false, help: 'Print the version.');
  }

  final String version;
  final Future<Menu> Function()? home;

  /// Command paths (e.g. `personal setup`) that continue to the menu.
  final Set<String> homeAfter;

  CliError? Function(Object error)? _translate;
  bool _inMenu = false;

  /// Completion is installed on request (`install-completion-files`), never
  /// by editing shell profiles behind the user's back.
  @override
  bool get enableAutoInstall => false;

  @override
  String get usageFooter => '\n${CliExit.footer}';

  /// Parses [args], runs the command and returns the exit code. [translate]
  /// turns SDK exceptions into [CliError]s.
  Future<int> execute(
    List<String> args, {
    CliError? Function(Object error)? translate,
  }) async {
    translate ??= _translate;
    _translate = translate;
    final ArgResults top;
    try {
      top = parse(args);
    } on UsageException catch (e) {
      ui = Ui(json: args.contains('--json'));
      return _usage(e);
    }
    ui = Ui(
      json: top['json'] as bool,
      verbose: top['verbose'] as bool,
      color: (top['color'] as bool) ? null : false,
      interactive: (top['input'] as bool) ? null : false,
    );
    if (top['version'] as bool) {
      ui.result({
        'name': executableName,
        'version': version,
      }, human: () => ui.info('$executableName $version'));
      return CliExit.ok;
    }
    final helpFlag = args.contains('--help') || args.contains('-h');
    final help = helpFlag || top.command == null || top.command!.name == 'help';
    final menu = home != null && ui.interactive && !_inMenu;
    try {
      if (menu && top.command == null && !helpFlag) return await runMenu();
      final code =
          await overrideAnsiOutput(
            ui.color,
            () => runZoned(() => runCommand(top), zoneSpecification: _sdkLogs),
          ) ??
          CliExit.ok;
      if (ui.json && !ui._emitted && !help) {
        ui.emit({'ok': code == CliExit.ok, 'exitCode': code});
      }
      if (menu && code == CliExit.ok && homeAfter.contains(_path(top))) {
        return await runMenu();
      }
      return code;
    } on UsageException catch (e) {
      return _usage(e);
    } catch (e, stack) {
      return _fail(e, stack);
    }
  }

  int _fail(Object e, StackTrace stack) {
    final error =
        (e is CliError ? e : null) ??
        _translate?.call(e) ??
        translateCommon(e) ??
        CliError(
          CliExit.internal,
          'Unexpected error: $e',
          hint: 'Rerun with --verbose for details.',
          code: 'INTERNAL',
        );
    ui._error(error, stack);
    return error.exitCode;
  }

  /// The home menu: pick an entry, run it as a normal command line, come back.
  /// A failed command prints its error and returns to the menu.
  Future<int> runMenu() => overrideAnsiOutput(ui.color, _menuLoop);

  Future<int> _menuLoop() async {
    final outer = ui;
    final flags = [if (!outer.color) '--no-color', if (outer.verbose) '-v'];
    _inMenu = true;
    try {
      outer.info('\n${styleBold.wrap('Welcome to IDR!')}');
      await _browse(home!, const [], outer, flags);
      return CliExit.ok;
    } finally {
      ui = outer;
      _inMenu = false;
    }
  }

  /// One menu level: show it, act, reload, until Back. A level that can't
  /// load says why and goes back up (the top level fails the command).
  Future<void> _browse(
    Submenu load,
    List<String> trail,
    Ui outer,
    List<String> flags,
  ) async {
    while (true) {
      ui = outer;
      final Menu menu;
      try {
        menu = await runZoned(load, zoneSpecification: _sdkLogs);
      } catch (e, stack) {
        if (trail.isEmpty) rethrow;
        _fail(e, stack);
        return;
      }
      final crumbs = [...trail, menu.title];
      ui.info('\n${styleBold.wrap(crumbs.join(' › '))}');
      if (menu.header.isNotEmpty) ui.info(menu.header);
      ui.hint('Use ↑/↓ to navigate and Enter to select.');
      final pick = ui.choose(
        'What would you like to do?',
        menu.items,
        flag: 'a menu choice',
        display: (i) => i.$1,
      );
      final Object? action;
      try {
        action = pick.$2();
      } on CliError catch (e) {
        ui._error(e);
        continue;
      }
      switch (action) {
        case null:
          return;
        case Submenu open:
          await _browse(open, crumbs, outer, flags);
        case List<String> args when args.isNotEmpty:
          ui.info('');
          await execute([...flags, ...args]);
      }
    }
  }

  /// SDK loggers print `[idr_…]` lines: debug output, not results.
  static final _sdkLogs = ZoneSpecification(
    print: (self, parent, zone, line) =>
        line.startsWith('[idr_') ? ui.debug(line) : parent.print(zone, line),
  );

  static String _path(ArgResults top) => [
    for (ArgResults? c = top.command; c != null; c = c.command) c.name,
  ].join(' ');

  int _usage(UsageException e) {
    ui._error(CliError(CliExit.usage, e.message, code: 'USAGE'));
    if (!ui.json) stderr.writeln('\n${e.usage}');
    return CliExit.usage;
  }
}

/// Network and file errors any command can hit.
CliError? translateCommon(Object e) => switch (e) {
  SocketException() || TimeoutException() || HandshakeException() => CliError(
    CliExit.connect,
    'Network error: ${e is SocketException ? e.message : e}',
    hint:
        'Check the server is running and the URL is right '
        '(run `doctor`).',
    code: 'NETWORK',
  ),
  FileSystemException(:final message, :final path) => CliError(
    CliExit.config,
    '$message${path == null ? '' : ': $path'}',
    code: 'FILESYSTEM',
  ),
  _ => null,
};

enum CheckStatus { ok, warn, fail, skip }

/// One diagnostic result. A failing check's [exitCode] becomes the exit code.
class Check {
  const Check(
    this.name,
    this.status,
    this.detail, {
    this.hint,
    this.exitCode = CliExit.failure,
  });

  final String name;
  final CheckStatus status;
  final String detail;
  final String? hint;
  final int exitCode;

  Map<String, Object?> toJson() => {
    'name': name,
    'status': status.name,
    'detail': redact(detail),
    'hint': hint,
  };
}

/// Prints [checks] and returns the first failure's exit code (or 0).
int reportChecks(List<Check> checks) {
  final failed = checks.where((c) => c.status == CheckStatus.fail).toList();
  ui.result(
    {
      'ok': failed.isEmpty,
      'checks': [for (final c in checks) c.toJson()],
    },
    human: () {
      final width = checks.fold(
        0,
        (w, c) => c.name.length > w ? c.name.length : w,
      );
      for (final c in checks) {
        final mark = switch (c.status) {
          CheckStatus.ok => lightGreen.wrap('✓ ok  '),
          CheckStatus.warn => yellow.wrap('! warn'),
          CheckStatus.fail => red.wrap('✗ fail'),
          CheckStatus.skip => darkGray.wrap('- skip'),
        };
        ui.info('$mark  ${c.name.padRight(width)}  ${redact(c.detail)}');
        if (c.hint != null && c.status != CheckStatus.ok) {
          ui.info('${''.padRight(width + 10)}${darkGray.wrap('→ ${c.hint}')}');
        }
      }
      final warns = checks.where((c) => c.status == CheckStatus.warn).length;
      ui.info('');
      ui.info(
        failed.isEmpty
            ? 'All checks passed${warns == 0 ? '' : ' ($warns warning(s))'}.'
            : '${failed.length} check(s) failed.',
      );
    },
  );
  return failed.isEmpty ? CliExit.ok : failed.first.exitCode;
}

/// GETs [url] (3 s connect timeout). Any HTTP answer counts as reachable
/// unless [expect] returns a problem for the status/body.
Future<Check> httpCheck(
  String name,
  String url, {
  String? hint,
  String? Function(int status, String body)? expect,
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
    return Check(
      name,
      CheckStatus.fail,
      'invalid URL: $url',
      hint: hint,
      exitCode: CliExit.config,
    );
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final response = await (await client.getUrl(
      uri,
    )).close().timeout(const Duration(seconds: 5));
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 5));
    final problem = expect?.call(response.statusCode, body);
    return problem == null
        ? Check(name, CheckStatus.ok, '$url (HTTP ${response.statusCode})')
        : Check(
            name,
            CheckStatus.fail,
            '$url: $problem',
            hint: hint,
            exitCode: CliExit.connect,
          );
  } catch (e) {
    final why = e is SocketException ? e.osError?.message ?? e.message : '$e';
    return Check(
      name,
      CheckStatus.fail,
      '$url unreachable ($why)',
      hint: hint,
      exitCode: CliExit.connect,
    );
  } finally {
    client.close(force: true);
  }
}

/// Loads the native library at [path] to prove it (and its own DLL
/// dependencies) can be loaded, not just that a file exists.
Check libraryCheck(String name, String? path, {required String hint}) {
  if (path == null || path.isEmpty) {
    return Check(
      name,
      CheckStatus.fail,
      'not found',
      hint: hint,
      exitCode: CliExit.config,
    );
  }
  try {
    DynamicLibrary.open(path);
    return Check(name, CheckStatus.ok, path);
  } catch (e) {
    // The file is there but the loader refused it: one of its own DLLs
    // (e.g. OpenSSL or the MSVC runtime) is missing, or it is the wrong arch.
    final why = File(path).existsSync()
        ? 'a library it depends on is missing, or wrong architecture'
        : 'file not found';
    return Check(
      name,
      CheckStatus.fail,
      'cannot load $path: $why ($e)',
      hint: hint,
      exitCode: CliExit.config,
    );
  }
}

/// Opens `idr_dp` the way the SDK does (explicit → `IDR_DP_LIB` → next to the
/// executable → repo build → OS search path) and checks its symbols.
Check dpCheck({required String hint}) {
  const name = 'idr_dp (certificates)';
  final path = IdrDpCrypto.resolveLibraryPath(null);
  final fromOs = path == IdrDpCrypto.defaultLibraryName;
  // The SDK skips a missing IDR_DP_LIB silently; say so.
  final env = (Platform.environment['IDR_DP_LIB'] ?? '').trim();
  final envIgnored = env.isNotEmpty && !File(env).existsSync();
  try {
    IdrDpCrypto.open(libraryPath: path);
    final where = fromOs ? '$path (from the system library path)' : path;
    return envIgnored
        ? Check(
            name,
            CheckStatus.warn,
            'IDR_DP_LIB=$env does not exist; using $where',
            hint: 'Fix or unset IDR_DP_LIB.',
          )
        : Check(name, CheckStatus.ok, where);
  } catch (e) {
    return Check(
      name,
      CheckStatus.fail,
      fromOs ? 'not found' : 'cannot load $path ($e)',
      hint: hint,
      exitCode: CliExit.config,
    );
  }
}
