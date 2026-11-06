import 'dart:convert';
import 'dart:io';

/// Which backend a run talks to, and where it keeps local state.
///
/// Every app has one entrypoint that calls [init] with its arguments:
/// `--flavor dev` (or `--flavor=dev`) picks `config/dev.json`; no flag means
/// [defaultName]. Env vars (`IDR_CONTROL_PLANE_URL`, `IDR_API_BASE_URL`,
/// `IDR_DISCOVERY_URL`, `IDR_BILLING_PORTAL_URL`) still override the file's
/// URLs for one run.
class IdrFlavor {
  const IdrFlavor({
    required this.name,
    this.controlPlane,
    this.discovery,
    this.billingPortal,
    this.isDev = false,
  });

  /// `prod`, `dev`, `staging`, … (the config file's name).
  final String name;
  final String? controlPlane;
  final String? discovery;
  final String? billingPortal;

  /// Local stack: development mode, insecure Presence, Let's Encrypt staging.
  final bool isDev;

  /// The flavor this process runs. Set by [init]; before that (tests) a prod
  /// flavor with no URLs, so anything needing one fails loudly.
  static IdrFlavor current = const IdrFlavor(name: 'prod');

  /// Appended to state folder names (`idr.to-t-dev`, `idr.to-s-dev`) so flavors on
  /// one machine never share a sign-in or a Target identity.
  String get stateSuffix => name == 'prod' ? '' : '-$name';

  /// The flavor without `--flavor`: `prod` in a compiled release build
  /// (`dart build cli`, `flutter build --release`), `dev` when run from source
  /// (`dart run`, `flutter run`), so local runs never touch prod state.
  static const defaultName =
      bool.fromEnvironment('dart.vm.product') ? 'prod' : 'dev';

  /// Takes `--flavor <name>` out of [args], loads `config/<name>.json` into
  /// [current] and returns the other arguments.
  static List<String> init(List<String> args) {
    var name = defaultName;
    final rest = <String>[];
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a.startsWith('--flavor=')) {
        name = a.substring('--flavor='.length);
      } else if (a == '--flavor' && i + 1 < args.length) {
        name = args[++i];
      } else {
        rest.add(a);
      }
    }
    current = load(name);
    return rest;
  }

  /// `config/<name>.json` next to the executable, else the first one found
  /// walking up from the working directory or the executable (repo checkout:
  /// `applications/apps/config/`).
  static IdrFlavor load(String name) {
    if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(name)) {
      throw ArgumentError('Unknown flavor "$name".');
    }
    final exeDir = File(Platform.resolvedExecutable).parent;
    final tried = <String>[];
    for (final start in [exeDir, Directory.current]) {
      for (var dir = start.absolute; ; dir = dir.parent) {
        final f = File([dir.path, 'config', '$name.json'].join(Platform.pathSeparator));
        tried.add(f.path);
        if (f.existsSync()) return fromJson(name, jsonDecode(f.readAsStringSync()) as Map);
        if (dir.parent.path == dir.path) break;
      }
    }
    throw StateError('No config for flavor "$name" (looked for ${tried.first} and above).');
  }

  static IdrFlavor fromJson(String name, Map j) => IdrFlavor(
        name: name,
        controlPlane: j['controlPlane'] as String?,
        discovery: j['discovery'] as String?,
        billingPortal: j['billingPortal'] as String?,
        isDev: j['dev'] == true,
      );

  /// Billing / control plane API base (env: `IDR_CONTROL_PLANE_URL`, or
  /// `IDR_API_BASE_URL` for the Source).
  String controlPlaneUrl([String env = 'IDR_CONTROL_PLANE_URL']) =>
      _url(env, controlPlane);

  /// Presence discovery document (env: `IDR_DISCOVERY_URL`).
  String get discoveryUrl => _url('IDR_DISCOVERY_URL', discovery);

  /// Billing web portal origin (env: `IDR_BILLING_PORTAL_URL`); empty when this
  /// flavor has none, which callers already report as "not configured".
  String get billingPortalUrl =>
      _env('IDR_BILLING_PORTAL_URL') ?? billingPortal ?? '';

  String _url(String env, String? value) {
    final v = _env(env) ?? value;
    if (v == null) {
      throw StateError('$env is not set and config/$name.json has no default.');
    }
    return v;
  }

  static String? _env(String key) {
    final v = Platform.environment[key]?.trim();
    return v == null || v.isEmpty ? null : v;
  }
}

/// The `idr` (Source) state folder for [IdrFlavor.current]:
/// `%APPDATA%/idr.to-s` or `~/.config/idr.to-s` (`idr.to-s-dev`, …).
Directory get idrSourceDirectory =>
    idrStateDirectory('idr.to-s', legacy: [_join([idrStateBase, 'idr'])]);

/// Where state folders live: `%APPDATA%` on Windows, else `~/.config`.
String get idrStateBase {
  final appData = Platform.environment['APPDATA'];
  if (appData != null && appData.isNotEmpty) return appData;
  return _join([Platform.environment['HOME'] ?? '.', '.config']);
}

final _stateDirs = <String, Directory>{};

/// `<idrStateBase>/<name><flavor suffix>`. On first use, if it doesn't exist
/// yet, moves the first existing [legacy] folder (older name, same suffix
/// appended) there so an upgrade keeps its sign-in and identity. If the move
/// fails (files open by a running agent) this run keeps using the old folder
/// and the next run retries.
Directory idrStateDirectory(String name, {List<String> legacy = const []}) {
  final sfx = IdrFlavor.current.stateSuffix;
  return _stateDirs.putIfAbsent('$name$sfx', () {
    final dir = Directory(_join([idrStateBase, '$name$sfx']));
    if (dir.existsSync()) return dir;
    for (final path in legacy) {
      final old = Directory('$path$sfx');
      if (!old.existsSync()) continue;
      try {
        dir.parent.createSync(recursive: true);
        return old.renameSync(dir.path);
      } on FileSystemException {
        return old;
      }
    }
    return dir;
  });
}

String _join(List<String> parts) => parts.join(Platform.pathSeparator);
