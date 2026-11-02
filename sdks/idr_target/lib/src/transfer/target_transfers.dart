import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_ipc.dart';

/// File transfer on this Target, owned by the running `target-agent`.
///
/// Calls go to the agent's local, owner-only IPC (the endpoint its own CLI
/// uses) over one persistent connection: a named pipe on Windows, a Unix
/// socket elsewhere. The connection checks the agent runs as this user.
/// Without a [dataDir] (or on other platforms) each call runs
/// `target-agent --config <cfg> transfer --json …` instead. Transfers keep
/// running when the app closes; all authorization and filesystem rules stay in
/// the agent.
class TargetTransfers {
  TargetTransfers({required this.agentBinaryPath, required this.configPath, this.dataDir, this.agent = 'target-agent'})
      : _ipc = dataDir != null && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)
            ? AgentIpc(agent: agent, dataDir: dataDir)
            : null;

  final String agentBinaryPath;

  /// The agent's `target.local.toml`.
  final String configPath;

  /// The agent's `[file_transfer].data_dir` (its IPC endpoint lives there).
  final String? dataDir;

  /// The agent's IPC name.
  final String agent;

  final AgentIpc? _ipc;

  /// Whether calls use the persistent connection (not a process per call).
  bool get direct => _ipc != null;

  /// All transfers and pending offers, newest last.
  Future<List<TargetTransfer>> list() async {
    final v = await _call({'cmd': 'list'}, ['list']) as List? ?? const [];
    return v.map((e) => TargetTransfer.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  Future<TargetTransfer> status(String id) async => TargetTransfer.fromJson(
      Map<String, dynamic>.from(await _call({'cmd': 'status', 'id': id}, ['status', id]) as Map));

  /// Sources with a bound session now: who [send] can reach.
  Future<List<TargetPeer>> peers() async {
    final v = await _call({'cmd': 'peers'}, ['peers']) as List? ?? const [];
    return v.map((e) => TargetPeer.fromJson(Map<String, dynamic>.from(e as Map))).toList();
  }

  /// Send files (one or more) or one folder to a bound Source, named by its
  /// verified device SKI (from [peers]).
  Future<TargetTransfer> send(String sourceSki, {List<String> files = const [], String? dir}) async {
    if (files.isEmpty == (dir == null)) {
      throw ArgumentError('send files or one folder');
    }
    final paths = [...files, if (dir != null) dir];
    final data = await _call(
      {
        'cmd': 'send',
        'target': sourceSki,
        'paths': [for (final p in paths) _absolute(p)],
      },
      [
        'send',
        '--target',
        sourceSki,
        for (final f in files) ...['--file', f],
        if (dir != null) ...['--dir', dir],
      ],
    );
    return TargetTransfer.fromJson(Map<String, dynamic>.from(data as Map));
  }

  /// Accept a pending offer, into [outDir] when given (the agent checks it is
  /// the receive directory or inside a permitted one: `unauthorized` if not).
  Future<void> accept(String id, {String? outDir}) => _call(
        {'cmd': 'accept', 'id': id, 'out': outDir == null ? null : _absolute(outDir)},
        ['accept', id, if (outDir != null) ...['--out', outDir]],
      );
  Future<void> reject(String id) => _call({'cmd': 'reject', 'id': id}, ['reject', id]);
  Future<void> pause(String id) => _call({'cmd': 'pause', 'id': id}, ['pause', id]);
  Future<void> resume(String id) => _call({'cmd': 'resume', 'id': id}, ['resume', id]);
  Future<void> cancel(String id) => _call({'cmd': 'cancel', 'id': id}, ['cancel', id]);
  Future<void> retryFailed(String id) => _call({'cmd': 'retry_failed', 'id': id}, ['retry-failed', id]);

  /// [list] every [every]; errors (agent restarting) are skipped, not fatal.
  Stream<List<TargetTransfer>> watch({Duration every = const Duration(seconds: 2)}) async* {
    while (true) {
      try {
        yield await list();
      } on TargetTransferException {
        // Agent not up yet or restarting: try again next tick.
      }
      await Future<void>.delayed(every);
    }
  }

  /// Close the persistent connection (reopened by the next call).
  Future<void> close() async => _ipc?.close();

  /// Absolute, links resolved, as the agent's CLI sends them; a missing path is refused here.
  static String _absolute(String path) {
    try {
      return FileSystemEntity.isDirectorySync(path)
          ? Directory(path).resolveSymbolicLinksSync()
          : File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      throw TargetTransferException('invalid_argument', 'not found: $path');
    }
  }

  Future<Object?> _call(Map<String, Object?> request, List<String> cli) async {
    final ipc = _ipc;
    final Map<String, dynamic> resp;
    if (ipc != null) {
      try {
        resp = await ipc.call(request);
      } on AgentIpcException catch (e) {
        throw TargetTransferException(e.kind, 'target-agent: ${e.kind}');
      }
    } else {
      resp = await _runProcess(cli);
    }
    if (resp['ok'] != true) {
      final kind = resp['error'] as String? ?? 'unknown';
      throw TargetTransferException(kind, 'target-agent refused: $kind');
    }
    return resp['data'];
  }

  Future<Map<String, dynamic>> _runProcess(List<String> args) async {
    final ProcessResult r;
    try {
      r = await Process.run(agentBinaryPath, ['--config', configPath, 'transfer', '--json', ...args]);
    } on ProcessException {
      throw const TargetTransferException('agent_missing', 'target-agent binary not found');
    }
    if ('${r.stderr}'.contains('is not running')) {
      throw const TargetTransferException('agent_not_running', 'target-agent is not running');
    }
    try {
      return Map<String, dynamic>.from(jsonDecode('${r.stdout}') as Map);
    } on FormatException {
      throw TargetTransferException('agent_failed', '${r.stderr}'.trim());
    }
  }
}

/// A Source with a bound session to this Target.
class TargetPeer {
  TargetPeer.fromJson(Map<String, dynamic> j)
      : ski = j['peer'] as String,
        path = j['path'] as String?,
        connection = j['connection'] as String? ?? 'unknown';

  /// The Source's verified device SKI.
  final String ski;
  final String? path;

  /// `direct`, `relayed` or `unknown`.
  final String connection;
}

/// [kind] is a stable transfer error name (`unauthorized`, `rejected`, …) or
/// `agent_missing` / `agent_not_running` / `agent_untrusted` / `agent_failed`
/// / `invalid_argument`.
class TargetTransferException implements Exception {
  const TargetTransferException(this.kind, this.message);

  final String kind;
  final String message;

  @override
  String toString() => 'TargetTransferException($kind): $message';
}

class TargetTransfer {
  TargetTransfer.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        incoming = j['direction'] == 'incoming',
        peer = j['peer'] as String,
        state = j['state'] as String,
        path = j['path'] as String?,
        relayed = j['relayed'] as bool?,
        connection = j['connection'] as String? ?? 'unknown',
        files = (j['summary'] as Map?)?['files'] as int?,
        dirs = (j['summary'] as Map?)?['dirs'] as int?,
        totalBytes = (j['summary'] as Map?)?['total_bytes'] as int?,
        topLevel = ((j['summary'] as Map?)?['top_level'] as List?)?.cast<String>() ?? const [],
        bytesDone = (j['progress'] as Map)['bytes_done'] as int,
        bytesTotal = (j['progress'] as Map)['bytes_total'] as int,
        filesDone = (j['progress'] as Map)['files_done'] as int,
        filesTotal = (j['progress'] as Map)['files_total'] as int,
        filesFailed = (j['progress'] as Map)['files_failed'] as int,
        bytesPerSec = (j['progress'] as Map)['bytes_per_sec'] as int? ?? 0;

  final String id;
  final bool incoming;

  /// The verified peer: a Source's device SKI.
  final String peer;

  /// `queued`, `running`, `paused`, `pending`, `waiting:<error>`, `completed`, or an error name.
  final String state;

  /// `host` / `stun` (direct) or `turn` (relayed); null when unknown.
  final String? path;
  final bool? relayed;

  /// `direct`, `relayed` or `unknown`: unknown is never shown as direct.
  final String connection;
  final int? files;
  final int? dirs;
  final int? totalBytes;
  final List<String> topLevel;
  final int bytesDone;
  final int bytesTotal;
  final int filesDone;
  final int filesTotal;
  final int filesFailed;
  final int bytesPerSec;

  bool get isPending => state == 'pending';
  bool get isDone =>
      !(state == 'queued' || state == 'running' || state == 'paused' || state == 'pending' || state.startsWith('waiting'));
  bool get isSingleFile => files == 1 && (dirs ?? 0) == 0;
  double get fraction => bytesTotal == 0 ? 0 : bytesDone / bytesTotal;

  /// What the offer contains, for an approval prompt.
  String get contents => isSingleFile
      ? topLevel.isEmpty
          ? '1 file'
          : topLevel.first
      : '${files ?? 0} files in ${topLevel.isEmpty ? '${dirs ?? 0} folders' : topLevel.join(', ')}';
}
