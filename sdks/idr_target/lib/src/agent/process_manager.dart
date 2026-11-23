import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:idr_telemetry/idr_telemetry.dart';

import 'package:path/path.dart' as p;

import '../internal/logging.dart';

/// Spawns and monitors the Rust `target-agent` binary.
///
/// Tracks the child via a PID file next to the TOML so a previous instance
/// (hot restart / crash) can be reaped by PID — not by global image name.
class ProcessManager {
  Process? _process;
  File? _pidFile;
  final _log = StreamController<String>.broadcast();
  final _exit = StreamController<int>.broadcast();

  Stream<String> get logs => _log.stream;

  /// Last stderr lines of the agent (redacted when logged). The agent writes its own
  /// structured logs; this tail only explains an exit that left no record.
  final _stderrTail = <String>[];
  List<String> get stderrTail => List.unmodifiable(_stderrTail);
  Stream<int> get exits => _exit.stream;
  bool get isRunning => _process != null;

  Future<void> start({
    required String binaryPath,
    required String configPath,
    String? workingDirectory,
    Map<String, String>? injectEnv,
  }) async {
    await stop();
    final bin = File(binaryPath);
    if (!bin.existsSync()) {
      throw StateError('target-agent binary not found: $binaryPath');
    }

    final pidFile = File(p.join(p.dirname(configPath), 'target-agent.pid'));
    _pidFile = pidFile;
    await _reapPidFile(pidFile);

    final env = <String, String>{
      ...Platform.environment,
      'IDR_CONFIG': configPath,
    };
    // Agent logs into the same log root and continues this process's trace (docs/observability).
    final root = defaultLogRoot();
    if (root != null && (env["IDR_LOG_DIR"] ?? "").isEmpty) env["IDR_LOG_DIR"] = root;
    final tp = currentTraceparent();
    if (tp != null) env['TRACEPARENT'] = tp;
    if ((env['RUST_LOG'] ?? '').trim().isEmpty) {
      env['RUST_LOG'] = 'info';
    }
    // The agent reads the JWT from `[auth].entitlement_jwt_path` and watches it
    // for refreshes; the env override would pin the first token.
    env.remove('IDR_ENTITLEMENT_JWT');
    for (final e in (injectEnv ?? {}).entries) {
      final k = e.key.trim();
      final v = e.value.trim();
      if (k.isNotEmpty && v.isNotEmpty) env[k] = v;
    }

    final proc = await Process.start(
      binaryPath,
      const [],
      workingDirectory: workingDirectory,
      environment: env,
    );
    _process = proc;
    await pidFile.writeAsString('${proc.pid}\n', flush: true);
    proc.stdout.transform(utf8.decoder).listen((s) => _log.add(s));
    proc.stderr.transform(utf8.decoder).listen((s) {
      _log.add(s);
      for (final l in s.split('\n')) {
        if (l.trim().isEmpty) continue;
        _stderrTail.add(l.trimRight());
        if (_stderrTail.length > 20) _stderrTail.removeAt(0);
      }
    });
    idrEvent('agent.process.started', attrs: {'process.pid': proc.pid});
    unawaited(proc.exitCode.then((code) {
      _log.add('[target-agent exited with code $code]');
      idrEvent('agent.process.exited',
          attrs: {'exit_code': code, if (code != 0) 'stderr_tail': _stderrTail.join('\n')},
          errorType: code == 0 ? null : 'agent_exited');
      _process = null;
      _clearPidFile();
      if (!_exit.isClosed) _exit.add(code);
    }));
  }

  Future<void> stop() async {
    final running = _process;
    if (running != null) {
      running.kill(ProcessSignal.sigterm);
      try {
        await running.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {
        running.kill(ProcessSignal.sigkill);
        try {
          await running.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {}
      }
      _process = null;
    }
    final pidFile = _pidFile;
    if (pidFile != null) {
      await _reapPidFile(pidFile);
    }
    _clearPidFile();
  }

  Future<void> _reapPidFile(File pidFile) async {
    if (!pidFile.existsSync()) return;
    try {
      final raw = (await pidFile.readAsString()).trim();
      final pid = int.tryParse(raw);
      if (pid == null || pid <= 0) {
        await pidFile.delete();
        return;
      }
      if (Platform.isWindows) {
        await Process.run('taskkill', ['/F', '/PID', '$pid']);
      } else {
        Process.killPid(pid, ProcessSignal.sigterm);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        Process.killPid(pid, ProcessSignal.sigkill);
      }
      idrEvent('agent.process.reaped', attrs: {'process.pid': pid});
    } catch (_) {
      // Process already gone.
    }
    try {
      if (pidFile.existsSync()) await pidFile.delete();
    } catch (_) {}
  }

  void _clearPidFile() {
    final f = _pidFile;
    if (f == null) return;
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await stop();
    await _log.close();
    await _exit.close();
  }
}
