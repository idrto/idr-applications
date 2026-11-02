import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';

import 'target.dart';

/// `idrt transfer …`: file transfer owned by the running `target-agent`.
///
/// Every subcommand asks the agent over its local, owner-only IPC; a transfer
/// keeps going when this command exits. Offers wait for `accept` / `reject`
/// (interactive is the default for this app).
class TransferCommand extends Command<int> {
  TransferCommand() {
    addSubcommand(_Send());
    addSubcommand(_Plain('list', 'Transfers and pending offers.', takesId: false));
    addSubcommand(_Plain('peers', 'Sources connected now (who `send --source` can reach).', takesId: false));
    addSubcommand(_Plain('status', 'One transfer: state, contents, path and progress.'));
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
      'Receive files from Sources and send to them (needs the agent running: `idrt start`).';
}

/// The running agent's transfers, from this machine's Target config.
Future<T> withTransfers<T>(Future<T> Function(TargetTransfers t) body) async {
  final target = createTarget();
  try {
    return await body(target.transfers);
  } on TargetTransferException catch (e) {
    throw switch (e.kind) {
      'agent_not_running' => const CliError(CliExit.connect, 'target-agent is not running.',
          hint: 'Start it with: idrt start', code: 'AGENT_NOT_RUNNING'),
      'agent_missing' => const CliError(CliExit.config, 'target-agent was not found.',
          hint: 'Build it, or set IDR_TARGET_AGENT.', code: 'AGENT_MISSING'),
      final kind => CliError(CliExit.failure, 'target-agent refused: $kind', code: kind.toUpperCase()),
    };
  } finally {
    await target.dispose();
  }
}

Map<String, Object?> transferJson(TargetTransfer t) => {
      'id': t.id,
      'direction': t.incoming ? 'incoming' : 'outgoing',
      'peer': t.peer,
      'state': t.state,
      'path': t.path,
      'relayed': t.relayed,
      'connection': t.connection,
      'contents': t.contents,
      'bytes_done': t.bytesDone,
      'bytes_total': t.bytesTotal,
      'files_done': t.filesDone,
      'files_total': t.filesTotal,
      'files_failed': t.filesFailed,
    };

String _via(TargetTransfer t) => t.connection;

void _showOne(TargetTransfer t) => ui.result(transferJson(t), human: () {
      ui.fields({
        'id': t.id,
        'direction': t.incoming ? 'incoming' : 'outgoing',
        'peer': t.peer,
        'state': t.state,
        'contents': t.contents,
        'connection': _via(t),
        'progress': '${t.bytesDone}/${t.bytesTotal} bytes, ${t.filesDone}/${t.filesTotal} files'
            '${t.filesFailed > 0 ? ', ${t.filesFailed} failed' : ''}',
      });
      if (t.isPending) ui.hint('Decide with: idrt transfer accept ${t.id}  (or reject)');
    });

class _Plain extends Command<int> {
  _Plain(this.name, this.description, {this.takesId = true});

  @override
  final String name;

  @override
  final String description;

  final bool takesId;

  @override
  String get invocation => takesId ? 'idrt transfer $name <id>' : 'idrt transfer $name';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (takesId && rest.length != 1) usageException('Give one transfer id.');
    await withTransfers((t) async {
      switch (name) {
        case 'list':
          final all = await t.list();
          ui.result(all.map(transferJson).toList(), human: () {
            if (all.isEmpty) return ui.info('No transfers.');
            ui.table(['id', 'direction', 'state', 'peer', 'via', 'progress'], [
              for (final x in all)
                [x.id, x.incoming ? 'in' : 'out', x.state, x.peer, _via(x), '${(x.fraction * 100).floor()}%'],
            ]);
          });
        case 'peers':
          final peers = await t.peers();
          ui.result([for (final x in peers) {'source': x.ski, 'connection': x.connection}], human: () {
            if (peers.isEmpty) return ui.info('No Source is connected.');
            ui.table(['source', 'connection'], [for (final x in peers) [x.ski, x.connection]]);
          });
        case 'status':
          _showOne(await t.status(rest.single));
        default:
          final id = rest.single;
          await switch (name) {
            'reject' => t.reject(id),
            'pause' => t.pause(id),
            'resume' => t.resume(id),
            'cancel' => t.cancel(id),
            _ => t.retryFailed(id),
          };
          ui.result({'ok': true}, human: () => ui.success('Done.'));
      }
    });
    return CliExit.ok;
  }
}

class _Send extends Command<int> {
  _Send() {
    argParser
      ..addOption('source', abbr: 's', help: 'The Source device SKI (see `idrt transfer peers`).', mandatory: true)
      ..addMultiOption('file', abbr: 'f', help: 'A file to send (repeat for more).')
      ..addOption('dir', abbr: 'd', help: 'A folder to send.');
  }

  @override
  String get name => 'send';

  @override
  String get description => 'Send files or a folder to a connected Source.';

  @override
  Future<int> run() async {
    final files = argResults!['file'] as List<String>;
    final dir = argResults!['dir'] as String?;
    if (files.isEmpty == (dir == null)) usageException('Send one or more --file, or one --dir.');
    await withTransfers((t) async {
      final sent = await t.send(argResults!['source'] as String, files: files, dir: dir);
      ui.result(transferJson(sent), human: () {
        ui.success('Queued ${sent.id}.');
        ui.hint('Follow it with: idrt transfer status ${sent.id}');
      });
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
  String get invocation => 'idrt transfer accept <id> [--out <dir>]';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    if (rest.length != 1) usageException('Give one transfer id.');
    await withTransfers((t) => t.accept(rest.single, outDir: argResults!['out'] as String?));
    ui.result({'ok': true}, human: () => ui.success('Accepted.'));
    return CliExit.ok;
  }
}
