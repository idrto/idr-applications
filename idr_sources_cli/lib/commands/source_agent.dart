import 'dart:convert';
import 'dart:io';

import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_source/idr_source.dart'
    show FileAuthStorage, IdrFlavor, canonicalPresenceFqhn, idrSourceDirectory;

import '../prefs/cli_prefs.dart';

/// `idr` sets up and runs the Source agent itself, so `idr transfer …` works
/// right after `idr enroll`:
///
/// - `<state>/source.toml`: this flavor's Presence, the Targets to keep a
///   session with (each one you send to, plus your current Target), and
///   receiving into `~/Downloads/IDR`, asking first.
/// - `source-agent run` in the background when it isn't answering, restarted
///   when the Targets change. It logs to `<state>/source-agent/agent.log`.
/// - This device's identity (private key) reaches the agent through a file
///   that exists only until the agent has started; it isn't kept in plain text.
///
/// `IDR_SOURCE_CONFIG` opts out: that config is used as is and you run the agent.

/// Presence discovery signing key (as the Target SDK pins); dev accepts unsigned.
const _discoveryKey = 'ri-IXqT0A69yuxaS6wppxnX8gUsdDC_Nl6aUtglQUK8';

String _join(List<String> parts) => parts.join(Platform.pathSeparator);

Directory get _agentDir => Directory(_join([idrSourceDirectory.path, 'source-agent']));
File get _pidFile => File(_join([_agentDir.path, 'agent.pid']));
String get agentLogPath => _join([_agentDir.path, 'agent.log']);

/// The Targets in a config [sourceConfigToml] wrote.
List<String> configTargets(String toml) {
  final line = RegExp(r'^targets = \[(.*)\]\r?$', multiLine: true).firstMatch(toml);
  if (line == null) return [];
  return [for (final m in RegExp(r'"([^"]+)"').allMatches(line[1]!)) m[1]!];
}

String sourceConfigToml({
  required List<String> targets,
  required String dataDir,
  required String receiveDir,
  required String sourceId,
}) {
  // JSON string escapes are valid TOML basic-string escapes.
  String q(String s) => jsonEncode(s);
  final f = IdrFlavor.current;
  return '''
# Written by idr: rewritten when you send to another Target.
# To use your own config instead, set IDR_SOURCE_CONFIG and run source-agent yourself.
[source]
source_id = ${q(sourceId)}

[presence]
discovery_url = ${q(f.discoveryUrl)}
discovery_key = ${q(f.isDev ? '' : _discoveryKey)}

[daemon]
data_dir = ${q(dataDir)}
targets = [${targets.map(q).join(', ')}]

[file_transfer]
enabled = true
receive_dir = ${q(receiveDir)}
interactive = true
''';
}

/// The config `idr transfer` passes the agent; makes sure the agent runs with
/// [target] (and the current Target) in its list. See the top of this file.
Future<String> ensureSourceAgent(String exe, {String? target}) async {
  final env = Platform.environment['IDR_SOURCE_CONFIG']?.trim();
  if (env != null && env.isNotEmpty) return env;

  final cfg = File(_join([idrSourceDirectory.path, 'source.toml']));
  final old = cfg.existsSync() ? cfg.readAsStringSync() : '';
  final targets = configTargets(old);
  for (final t in [?target, ?await createCliPrefs().lastFqhn]) {
    final c = canonicalPresenceFqhn(t);
    if (!targets.contains(c)) targets.add(c);
  }
  if (targets.isEmpty) {
    throw const CliError(CliExit.config, 'No Target to transfer with yet.',
        hint: 'Connect to your Target first: idr connect <target-fqhn>', code: 'NO_TARGET');
  }
  final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
  final toml = sourceConfigToml(
    targets: targets,
    dataDir: _agentDir.path,
    receiveDir: _join([home, 'Downloads', 'IDR']),
    sourceId: Platform.localHostname,
  );
  final changed = toml != old;
  if (changed) {
    cfg.parent.createSync(recursive: true);
    cfg.writeAsStringSync(toml);
  }

  final running = await _running(exe, cfg.path);
  if (running && !changed) return cfg.path;
  if (running) await _stop(exe, cfg.path);
  await _start(exe, cfg.path);
  return cfg.path;
}

Future<bool> _running(String exe, String cfg) async {
  try {
    final r = await Process.run(exe, ['--config', cfg, 'transfer', '--json', 'peers']);
    return !'${r.stderr}'.contains('is not running');
  } on ProcessException {
    throw agentMissing;
  }
}

const agentMissing = CliError(CliExit.config, 'source-agent was not found.',
    hint: 'Reinstall the Source app with IDR Setup (it puts source-agent next to idr), '
        'or set IDR_SOURCE_AGENT to its path.',
    code: 'AGENT_MISSING');

/// Stops the agent idr started (its pid file), so it restarts with new Targets.
Future<void> _stop(String exe, String cfg) async {
  final pid = _pidFile.existsSync() ? int.tryParse(_pidFile.readAsStringSync().trim()) : null;
  if (pid != null) Process.killPid(pid);
  for (var i = 0; i < 20; i++) {
    if (!await _running(exe, cfg)) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw const CliError(CliExit.connect, 'A source-agent is already running with other Targets.',
      hint: 'Stop it (close its window, or end source-agent in Task Manager), then try again.',
      code: 'AGENT_BUSY');
}

/// This device's approved identity, as `idr enroll` stored it.
Future<String> _identityJson() async {
  final raw = await FileAuthStorage().getItem('idr.source.identity');
  final j = raw == null ? null : jsonDecode(raw);
  if (j is! Map || j['credential'] is! Map || (j['credential'] as Map).isEmpty) {
    throw const CliError(CliExit.auth, 'This machine is not an approved Source yet.',
        hint: 'Run `idr enroll`, and ask the Target admin to approve it.', code: 'NOT_ENROLLED');
  }
  return jsonEncode(Map.of(j)..remove('pull_token'));
}

Future<void> _start(String exe, String cfg) async {
  final identity = await _identityJson();
  _agentDir.createSync(recursive: true);
  final idFile = File(_join([_agentDir.path, 'identity.tmp.json']))..writeAsStringSync('');
  if (!Platform.isWindows) await Process.run('chmod', ['600', idFile.path]);
  idFile.writeAsStringSync(identity);

  try {
    final Process proc;
    try {
      // Detached, no pipes: it outlives idr and its terminal; logs go to IDR_LOG_FILE.
      proc = await Process.start(exe, ['--config', cfg, '--identity', idFile.path, 'run'],
          mode: ProcessStartMode.detached, environment: {'IDR_LOG_FILE': agentLogPath});
    } on ProcessException {
      throw agentMissing;
    }
    _pidFile.writeAsStringSync('${proc.pid}');
    // Its control socket answers once the daemon runs (the identity is loaded by then).
    for (var i = 0; i < 60; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (await _running(exe, cfg)) return;
    }
    final log = File(agentLogPath);
    final tail = log.existsSync() ? log.readAsLinesSync().reversed.take(6).toList().reversed : const <String>[];
    throw CliError(CliExit.connect, 'source-agent did not start.',
        hint: [...tail, 'Full log: $agentLogPath'].join('\n'), code: 'AGENT_START_FAILED');
  } finally {
    if (idFile.existsSync()) idFile.deleteSync();
  }
}
