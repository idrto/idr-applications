import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_source/idr_source.dart' show idrSourceDirectory;


/// `idr transfer …`: file transfer owned by the running `source-agent`.
///
/// Each subcommand asks the agent over its local, owner-only IPC by running
/// `source-agent transfer --json …` (the same contract its own CLI uses), so a
/// transfer keeps going when this command exits. The agent binary comes from
/// `IDR_SOURCE_AGENT` or `PATH`; its config from `IDR_SOURCE_CONFIG`.
class TransferCommand extends Command<int> {
  TransferCommand() {
    addSubcommand(_Send());
    addSubcommand(_Plain('list', 'Transfers and pending offers.', takesId: false));
    addSubcommand(_Plain('status', 'One transfer: state, summary and progress.'));
    addSubcommand(_Accept());
    addSubcommand(_Plain('reject', 'Reject a pending incoming offer.'));
    addSubcommand(_Plain('pause', 'Pause a transfer.'));
    addSubcommand(_Plain('resume', 'Resume a paused transfer.'));
    addSubcommand(_Plain('cancel', 'Cancel a transfer; partial data is removed.'));
    addSubcommand(_Plain('retry-failed', 'Re-send the entries that failed.'));
  }

  @override
  String get name => 'transfer';

  @override
  String get description =>
      'Send files or folders to a Target and manage transfers (needs `source-agent run`).';
}

String _join(List<String> parts) => parts.join(Platform.pathSeparator);

/// `source-agent`: `IDR_SOURCE_AGENT` → next to this executable → the repo
/// build (`agents_engine/agent/target/{release,debug}` above the current
/// directory) → `PATH`.
String sourceAgentExecutable() {
  final env = Platform.environment['IDR_SOURCE_AGENT']?.trim();
  if (env != null && env.isNotEmpty) return env;
  final name = Platform.isWindows ? 'source-agent.exe' : 'source-agent';
  final dirs = [File(Platform.resolvedExecutable).parent.path];
  for (var d = Directory.current; ; d = d.parent) {
    for (final profile in const ['release', 'debug']) {
      dirs.add(_join([d.path, 'agents_engine', 'agent', 'target', profile]));
    }
    if (d.parent.path == d.path) break;
  }
  for (final dir in dirs) {
    if (File(_join([dir, name])).existsSync()) return _join([dir, name]);
  }
  return 'source-agent';
}

/// The agent's config: `IDR_SOURCE_CONFIG`, else `%APPDATA%/idr/source.toml`
/// (`~/.config/idr/source.toml`; per flavor) when it exists.
String? sourceAgentConfig() {
  final env = Platform.environment['IDR_SOURCE_CONFIG']?.trim();
  if (env != null && env.isNotEmpty) return env;
  final f = _join([idrSourceDirectory.path, 'source.toml']);
  return File(f).existsSync() ? f : null;
}

/// Runs `source-agent transfer --json <args>` and returns its `data`.
Future<Object?> agentTransfer(List<String> args, {String? executable}) async {
  final exe = executable ?? sourceAgentExecutable();
  final config = executable == null ? sourceAgentConfig() : null;
  final ProcessResult r;
  try {
    r = await Process.run(exe, [if (config != null) ...['--config', config], 'transfer', '--json', ...args]);
  } on ProcessException {
    throw CliError(CliExit.config, 'source-agent was not found.',
        hint: 'Build it (cargo build --release -p source-agent), or set IDR_SOURCE_AGENT to its path.',
        code: 'AGENT_MISSING');
  }
  final err = '${r.stderr}';
  if (err.contains('is not running')) {
    throw const CliError(CliExit.connect, 'source-agent is not running.',
        hint: 'Start it with: source-agent run (add --config <your source.toml>)', code: 'AGENT_NOT_RUNNING');
  }
  if (config == null && err.contains('load ') && err.contains('source.example.toml')) {
    throw const CliError(CliExit.config, 'No Source agent config found.',
        hint: 'Create %APPDATA%/idr/source.toml (see the README, File transfer), or set IDR_SOURCE_CONFIG.',
        code: 'AGENT_CONFIG_MISSING');
  }
  final Map<String, dynamic> resp;
  try {
    resp = Map<String, dynamic>.from(jsonDecode('${r.stdout}') as Map);
  } on FormatException {
    throw CliError(CliExit.failure, err.trim().isEmpty ? 'source-agent failed.' : err.trim(),
        code: 'AGENT_FAILED');
  }
  if (resp['ok'] != true) {
    final kind = resp['error'] as String? ?? 'unknown';
    throw CliError(CliExit.failure, 'source-agent refused: $kind', code: kind.toUpperCase());
  }
  return resp['data'];
}

void _show(Object? data) {
  ui.result(data, human: () {
    switch (data) {
      case null:
        ui.success('Done.');
      case final List<dynamic> list when list.isEmpty:
        ui.info('No transfers.');
      case final List<dynamic> list:
        ui.table(
          ['id', 'direction', 'state', 'peer', 'progress'],
          [for (final t in list.cast<Map<dynamic, dynamic>>()) _row(t)],
        );
      case final Map<dynamic, dynamic> t:
        final p = t['progress'] as Map;
        final s = t['summary'] as Map?;
        ui.fields({
          'id': t['id'],
          'direction': t['direction'],
          'peer': t['peer'],
          'state': t['state'],
          'contents': s == null ? null : '${s['files']} files, ${s['dirs']} folders, ${s['total_bytes']} bytes',
          'progress': '${p['bytes_done']}/${p['bytes_total']} bytes, ${p['files_done']}/${p['files_total']} files'
              '${(p['files_failed'] as int? ?? 0) > 0 ? ', ${p['files_failed']} failed' : ''}',
        });
    }
  });
}

List<Object?> _row(Map<dynamic, dynamic> t) {
  final p = t['progress'] as Map;
  final total = p['bytes_total'] as int? ?? 0;
  final pct = total == 0 ? '-' : '${(100 * (p['bytes_done'] as int) / total).floor()}%';
  return [t['id'], t['direction'], t['state'], t['peer'], pct];
}

class _Plain extends Command<int> {
  _Plain(this.name, this.description, {this.takesId = true});

  @override
  final String name;

  @override
  final String description;

  final bool takesId;

  @override
  String get invocation => takesId ? 'idr transfer $name <id>' : 'idr transfer $name';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (takesId && rest.length != 1) usageException('Give one transfer id.');
    _show(await agentTransfer([name, ...rest]));
    return CliExit.ok;
  }
}

class _Send extends Command<int> {
  _Send() {
    argParser
      ..addOption('target', abbr: 't', help: 'Target FQHN.', mandatory: true)
      ..addMultiOption('file', abbr: 'f', help: 'A file to send (repeat for more).')
      ..addMultiOption('dir', abbr: 'd', help: 'A folder to send.');
  }

  @override
  String get name => 'send';

  @override
  String get description => 'Queue files or a folder; the agent sends them and resumes after drops.';

  @override
  Future<int> run() async {
    final files = argResults!['file'] as List<String>;
    final dirs = argResults!['dir'] as List<String>;
    if (files.isEmpty == dirs.isEmpty || dirs.length > 1) {
      usageException('Send one or more --file, or one --dir.');
    }
    final data = await agentTransfer([
      'send',
      '--target',
      argResults!['target'] as String,
      for (final f in files) ...['--file', f],
      for (final d in dirs) ...['--dir', d],
    ]);
    ui.result(data, human: () {
      ui.success('Queued ${(data as Map)['id']}.');
      ui.hint('Follow it with: idr transfer status ${data['id']}');
    });
    return CliExit.ok;
  }
}

class _Accept extends Command<int> {
  _Accept() {
    argParser.addOption('out', abbr: 'o', help: 'A permitted directory to store it in.');
  }

  @override
  String get name => 'accept';

  @override
  String get description => 'Accept a pending incoming offer.';

  @override
  String get invocation => 'idr transfer accept <id> [--out <dir>]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) usageException('Give one transfer id.');
    final out = argResults!['out'] as String?;
    _show(await agentTransfer(['accept', rest.single, if (out != null) ...['--out', out]]));
    return CliExit.ok;
  }
}
