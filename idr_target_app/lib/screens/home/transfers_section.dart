import 'dart:async';

import 'package:flutter/material.dart';
import 'package:idr_target/idr_target.dart';

import '../../target/native_dialogs.dart';
import '../../ui/components/buttons/idr_button.dart';
import '../../ui/components/cards/idr_card.dart';
import '../../ui/components/dialogs/idr_dialog.dart';
import '../../ui/components/feedback/idr_feedback.dart';
import '../../ui/components/inputs/idr_fields.dart';
import '../../ui/components/layout/idr_layout.dart';
import '../../ui/theme/idr_theme.dart';

/// `1.2 MB` style sizes.
String formatBytes(int n) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = n.toDouble();
  var i = 0;
  while (v >= 1000 && i < units.length - 1) {
    v /= 1000;
    i++;
  }
  return i == 0 ? '$n B' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}

/// Confirmed direct, relayed, or unknown (never guessed as direct).
String connectionLabel(TargetTransfer t) => switch (t.connection) {
      'relayed' => 'Relayed',
      'direct' => 'Direct',
      _ => 'Unknown',
    };

/// Files from verified Sources: offers waiting for a decision, then all transfers.
/// The agent owns the transfers; this screen only watches and commands them.
class TransfersSection extends StatefulWidget {
  const TransfersSection({super.key, required this.transfers});

  final TargetTransfers transfers;

  @override
  State<TransfersSection> createState() => _TransfersSectionState();
}

class _TransfersSectionState extends State<TransfersSection> {
  StreamSubscription<List<TargetTransfer>>? _sub;
  List<TargetTransfer>? _all;
  /// Agent unavailable (cleared by the next successful refresh).
  String? _error;

  /// Why the last action was refused (cleared when the next action starts).
  String? _notice;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _sub = widget.transfers.watch().listen(_show);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// Newest first.
  void _show(List<TargetTransfer> all) {
    if (!mounted) return;
    setState(() {
      _all = all.reversed.toList();
      _error = null;
    });
  }

  Future<void> _refresh() async {
    try {
      _show(await widget.transfers.list());
    } on TargetTransferException catch (e) {
      if (mounted) {
        setState(() => _error = e.kind == 'agent_not_running'
            ? 'The agent is not running. Start the Target to receive files.'
            : 'Transfers unavailable (${e.kind}).');
      }
    }
  }

  Future<void> _do(String id, Future<void> Function() op) async {
    setState(() {
      _busy.add(id);
      _notice = null;
    });
    try {
      await op();
    } on TargetTransferException catch (e) {
      if (mounted) setState(() => _notice = _explain(e));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
      await _refresh();
    }
  }

  static String _explain(TargetTransferException e) => switch (e.kind) {
        'unauthorized' => 'That folder is not allowed. Choose a folder inside your home folder.',
        'agent_not_running' => 'The agent is not running. Start the Target first.',
        'agent_untrusted' => 'Refused: the agent connection is owned by another Windows user.',
        'invalid_argument' => 'That file or folder no longer exists.',
        final k => 'Refused: $k',
      };

  /// Accept into a folder the user picks (the agent checks it is permitted).
  Future<void> _acceptTo(TargetTransfer t) async {
    final dir = NativeDialogs.pickFolder(title: 'Save "${t.contents}" in…');
    if (dir == null) return;
    await _do(t.id, () => widget.transfers.accept(t.id, outDir: dir));
  }

  /// Send files or a folder to a connected Source.
  Future<void> _send() async {
    final List<TargetPeer> peers;
    try {
      peers = await widget.transfers.peers();
    } on TargetTransferException catch (e) {
      setState(() => _notice = _explain(e));
      return;
    }
    if (!mounted) return;
    if (peers.isEmpty) {
      setState(() => _notice = 'No Source is connected right now. A Source appears here while it has a session with this Target.');
      return;
    }
    var ski = peers.first.ski;
    final what = await showIdrDialog<String>(
      context: context,
      title: 'Send to a Source',
      content: StatefulBuilder(
        builder: (ctx, setLocal) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            IdrField(
              label: 'Source',
              child: IdrSelect<String>(
                value: ski,
                options: [
                  for (final p in peers)
                    IdrOption(value: p.ski, label: '${p.ski} · ${p.connection == 'relayed' ? 'Relayed' : p.connection == 'direct' ? 'Direct' : 'Unknown'}'),
                ],
                onChanged: (v) => setLocal(() => ski = v),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: IdrButton(label: 'Choose files…', onPressed: () => Navigator.of(ctx).pop('files')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: IdrButton(
                    label: 'Choose folder…',
                    variant: IdrButtonVariant.primary,
                    onPressed: () => Navigator.of(ctx).pop('folder'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    if (what == null) return;
    final files = what == 'files' ? NativeDialogs.pickFiles(title: 'Files to send') : null;
    final dir = what == 'folder' ? NativeDialogs.pickFolder(title: 'Folder to send') : null;
    if (files == null && dir == null) return;
    await _do('send', () => widget.transfers.send(ski, files: files ?? const [], dir: dir));
  }

  Widget _offer(TargetTransfer t) {
    final busy = _busy.contains(t.id);
    return IdrCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            t.isSingleFile ? t.contents : 'Folder: ${t.contents}',
            style: IdrText.body(size: 15, weight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '${formatBytes(t.totalBytes ?? 0)} from Source ${t.peer} · ${connectionLabel(t)}',
            style: IdrText.body(size: 12, color: IdrColors.zinc500),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IdrButton(
                label: 'Reject',
                variant: IdrButtonVariant.destructive,
                size: IdrButtonSize.sm,
                onPressed: busy ? null : () => _do(t.id, () => widget.transfers.reject(t.id)),
              ),
              if (NativeDialogs.available) ...[
                const SizedBox(width: 8),
                IdrButton(
                  label: 'Accept to…',
                  size: IdrButtonSize.sm,
                  onPressed: busy ? null : () => _acceptTo(t),
                ),
              ],
              const SizedBox(width: 8),
              IdrButton(
                label: 'Accept',
                variant: IdrButtonVariant.primary,
                size: IdrButtonSize.sm,
                loading: busy,
                onPressed: busy ? null : () => _do(t.id, () => widget.transfers.accept(t.id)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _actions(TargetTransfer t) {
    final busy = _busy.contains(t.id);
    if (t.isDone || t.isPending) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (t.state == 'paused')
          IdrButton(
            label: 'Resume',
            size: IdrButtonSize.xs,
            onPressed: busy ? null : () => _do(t.id, () => widget.transfers.resume(t.id)),
          )
        else
          IdrButton(
            label: 'Pause',
            size: IdrButtonSize.xs,
            onPressed: busy ? null : () => _do(t.id, () => widget.transfers.pause(t.id)),
          ),
        const SizedBox(width: 6),
        IdrButton(
          label: 'Cancel',
          size: IdrButtonSize.xs,
          variant: IdrButtonVariant.destructive,
          onPressed: busy ? null : () => _do(t.id, () => widget.transfers.cancel(t.id)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = _all;
    final offers = all?.where((t) => t.isPending).toList() ?? const [];
    final rest = all?.where((t) => !t.isPending).toList() ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IdrPageHeader(
          title: 'Transfers',
          subtitle: 'Files from verified Sources. Nothing is saved until you accept it.',
          actions: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (NativeDialogs.available) ...[
                IdrButton(
                  label: 'Send…',
                  icon: Icons.upload_outlined,
                  size: IdrButtonSize.sm,
                  onPressed: _busy.contains('send') ? null : _send,
                ),
                const SizedBox(width: 8),
              ],
              IdrButton(
                label: 'Refresh',
                icon: Icons.refresh,
                size: IdrButtonSize.sm,
                onPressed: _refresh,
              ),
            ],
          ),
        ),
        if (_error != null) IdrAlert(tone: IdrTone.warning, title: 'Transfers', message: _error),
        if (_notice != null) IdrAlert(tone: IdrTone.error, title: 'Not done', message: _notice),
        for (final t in offers) ...[_offer(t), const SizedBox(height: 12)],
        if (all != null && all.isEmpty)
          const IdrCard(
            child: IdrEmpty(
              icon: Icons.move_to_inbox_outlined,
              title: 'No transfers yet',
              description: 'A Source sends with: idr transfer send --target <this host> --file <path>',
            ),
          ),
        if (rest.isNotEmpty)
          IdrCard(
            child: IdrTable(
              columns: const ['What', 'Direction', 'State', 'Progress', 'Connection', ''],
              rows: [
                for (final t in rest)
                  IdrTableRow(cells: [
                    Text(t.contents),
                    Text(t.incoming ? 'Received' : 'Sent'),
                    Text(t.state),
                    SizedBox(
                      width: 140,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(value: t.fraction),
                          const SizedBox(height: 2),
                          Text(
                            '${formatBytes(t.bytesDone)} / ${formatBytes(t.bytesTotal)}'
                            '${t.filesFailed > 0 ? ' · ${t.filesFailed} failed' : ''}',
                            style: IdrText.body(size: 11, color: IdrColors.zinc500),
                          ),
                        ],
                      ),
                    ),
                    Text(connectionLabel(t)),
                    Align(alignment: Alignment.centerRight, child: _actions(t)),
                  ]),
              ],
            ),
          ),
      ],
    );
  }
}
