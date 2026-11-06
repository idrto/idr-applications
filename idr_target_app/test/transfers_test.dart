import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:idr_target/idr_target.dart';
import 'package:idr_target_app/screens/home/transfers_section.dart';
import 'package:idr_target_app/target/native_dialogs.dart';
import 'package:win32/win32.dart';

/// The agent, as the Transfers page sees it.
class _FakeTransfers extends TargetTransfers {
  _FakeTransfers({this.peerList = const [], this.refuseAccept})
      : super(agentBinaryPath: 'unused', configPath: 'unused');

  final List<TargetPeer> peerList;
  final String? refuseAccept;
  final accepted = <String?>[];

  static final offer = TargetTransfer.fromJson({
    'id': 'ab' * 16,
    'direction': 'incoming',
    'peer': 'src-ski',
    'state': 'pending',
    'connection': 'relayed',
    'summary': {'files': 1, 'dirs': 0, 'total_bytes': 2048, 'top_level': ['report.pdf'], 'more_top_level': 0},
    'progress': {'bytes_done': 0, 'bytes_total': 2048, 'files_done': 0, 'files_total': 1, 'files_failed': 0},
  });

  @override
  Future<List<TargetTransfer>> list() async => [offer];

  @override
  Stream<List<TargetTransfer>> watch({Duration every = const Duration(seconds: 2)}) => const Stream.empty();

  @override
  Future<List<TargetPeer>> peers() async => peerList;

  @override
  Future<void> accept(String id, {String? outDir}) async {
    if (refuseAccept != null) throw TargetTransferException(refuseAccept!, 'refused');
    accepted.add(outDir);
  }
}

Future<void> _pump(WidgetTester t, TargetTransfers transfers) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: TransfersSection(transfers: transfers)))));
  await t.pumpAndSettle();
}

void main() {

  testWidgets('a pending single-file offer: name, size, sender, relayed; Accept / Accept to… / Reject', (t) async {
    final fake = _FakeTransfers();
    await _pump(t, fake);
    expect(find.text('report.pdf'), findsOneWidget, reason: 'single file: just its name, no folder UI');
    expect(find.textContaining('from Source src-ski · Relayed'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    expect(find.text('Accept to…'), Platform.isWindows ? findsOneWidget : findsNothing);
    await t.tap(find.text('Accept'));
    await t.pumpAndSettle();
    expect(fake.accepted, [null], reason: 'plain Accept stores in the receive directory');
  });

  testWidgets('a refused destination gets a plain explanation', (t) async {
    await _pump(t, _FakeTransfers(refuseAccept: 'unauthorized'));
    await t.tap(find.text('Accept'));
    await t.pumpAndSettle();
    expect(find.textContaining('That folder is not allowed'), findsOneWidget);
  });

  testWidgets('Send… with no connected Source explains instead of opening a picker', (t) async {
    if (!Platform.isWindows) return;
    await _pump(t, _FakeTransfers());
    await t.tap(find.text('Send…'));
    await t.pumpAndSettle();
    expect(find.textContaining('No Source is connected'), findsOneWidget);
  });

  testWidgets('Send… lists connected Sources with their connection', (t) async {
    if (!Platform.isWindows) return;
    await _pump(t, _FakeTransfers(peerList: [TargetPeer.fromJson({'peer': 'src-ski', 'connection': 'direct'})]));
    await t.tap(find.text('Send…'));
    await t.pumpAndSettle();
    expect(find.text('Send to a Source'), findsOneWidget);
    expect(find.textContaining('src-ski · Direct'), findsWidgets);
    expect(find.text('Choose files…'), findsOneWidget);
    expect(find.text('Choose folder…'), findsOneWidget);
  });

  test('the native folder / file dialogs are created and configured (COM), not shown', () {
    if (!Platform.isWindows) return;
    final folder = NativeDialogs.configuredOptions(FOS_PICKFOLDERS);
    expect(folder & FOS_PICKFOLDERS, isNonZero);
    expect(folder & FOS_FORCEFILESYSTEM, isNonZero);
    final files = NativeDialogs.configuredOptions(FOS_ALLOWMULTISELECT);
    expect(files & FOS_ALLOWMULTISELECT, isNonZero);
    expect(files & FOS_PICKFOLDERS, isZero);
  });
}
