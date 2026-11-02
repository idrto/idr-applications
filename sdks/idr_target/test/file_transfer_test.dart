import 'dart:io';

import 'package:idr_target/src/agent/toml_writer.dart';
import 'package:idr_target/src/transfer/target_transfers.dart';
import 'package:test/test.dart';

TomlWriter _writer({String? dp, bool enabled = true}) => TomlWriter(
      fqhn: 'laptop.alice-acme-com.idr.to',
      agentRegion: 'eu-central',
      usingParty: 'alice@acme.com',
      discoveryUrl: 'https://public.idr.to/.well-known/idr-presence.json',
      discoveryKey: 'key',
      services: const [],
      dpIdentityPath: dp,
      fileTransferEnabled: enabled,
      fileTransferReceiveDir: r'C:\Users\alice\Downloads\IDR',
      fileTransferDataDir: r'C:\cfg\transfers',
      fileTransferPermittedDirs: const [r'D:\Shared'],
    );

/// `agents_engine/agent/target/debug/target-agent(.exe)` from this package, if built.
File? _agentBinary() {
  final exe = Platform.isWindows ? 'target-agent.exe' : 'target-agent';
  final f = File('${Directory.current.path}/../../../../agents_engine/agent/target/debug/$exe');
  return f.existsSync() ? f : null;
}

void main() {
  directIpcTests();
  group('[file_transfer] in target.local.toml', () {
    test('written with a DP identity, interactive by default', () {
      final toml = _writer(dp: r'C:\cfg\dp.json').toToml();
      expect(toml, contains('[file_transfer]'));
      expect(toml, contains('enabled = true'));
      expect(toml, contains('interactive = true'));
      expect(toml, contains(r'receive_dir = "C:\\Users\\alice\\Downloads\\IDR"'));
      expect(toml, contains(r'permitted_dirs = ["D:\\Shared"]'));
    });

    test('left out without a DP identity (binding needs it) or when disabled', () {
      expect(_writer().toToml(), isNot(contains('[file_transfer]')));
      expect(_writer(dp: 'dp.json', enabled: false).toToml(), isNot(contains('[file_transfer]')));
    });

    test('the Rust agent parses it', () async {
      final bin = _agentBinary();
      if (bin == null) {
        markTestSkipped('target-agent not built');
        return;
      }
      final dir = await Directory.systemTemp.createTemp('idrt-ft');
      addTearDown(() => dir.delete(recursive: true));
      final cfg = await _writer(dp: '${dir.path}/dp.json').writeTo(dir);
      final r = await Process.run(bin.path, ['--config', cfg.path, 'doctor']);
      expect('${r.stderr}${r.stdout}', isNot(contains('unknown field')));
      expect('${r.stderr}', isNot(contains('load configuration')), reason: '${r.stderr}');
    });
  });

  group('TargetTransfers', () {
    test('agent not running is reported, not thrown as a crash', () async {
      final bin = _agentBinary();
      if (bin == null) {
        markTestSkipped('target-agent not built');
        return;
      }
      final dir = await Directory.systemTemp.createTemp('idrt-ft');
      addTearDown(() => dir.delete(recursive: true));
      final cfg = await _writer(dp: '${dir.path}/dp.json').writeTo(dir);
      final t = TargetTransfers(agentBinaryPath: bin.path, configPath: cfg.path);
      expect(() => t.list(),
          throwsA(isA<TargetTransferException>().having((e) => e.kind, 'kind', 'agent_not_running')));
    });

    test('missing binary', () {
      final t = TargetTransfers(agentBinaryPath: 'no-such-target-agent', configPath: 'x.toml');
      expect(() => t.list(), throwsA(isA<TargetTransferException>().having((e) => e.kind, 'kind', 'agent_missing')));
    });

    test('model from the agent JSON', () {
      final t = TargetTransfer.fromJson({
        'id': 'ab' * 16,
        'direction': 'incoming',
        'peer': 'src-ski',
        'state': 'pending',
        'path': 'turn',
        'relayed': true,
        'connection': 'relayed',
        'summary': {'files': 3, 'dirs': 1, 'total_bytes': 10, 'top_level': ['Project'], 'more_top_level': 0},
        'progress': {'bytes_done': 5, 'bytes_total': 10, 'files_done': 1, 'files_total': 3, 'files_failed': 0, 'bytes_per_sec': 0},
      });
      expect((t.isPending, t.relayed, t.isDone, t.fraction), (true, true, false, 0.5));
      expect(t.contents, '3 files in Project');
      expect(t.connection, 'relayed');
      final unknown = TargetTransfer.fromJson({
        'id': 'cd' * 16, 'direction': 'outgoing', 'peer': 's', 'state': 'running',
        'progress': {'bytes_done': 0, 'bytes_total': 0, 'files_done': 0, 'files_total': 0, 'files_failed': 0},
      });
      expect((unknown.connection, unknown.relayed), ('unknown', null), reason: 'missing path is unknown, not direct');
    });
  });
}

/// The Rust IPC stub (`cargo build -p idr-transfer --features native --example ipc_stub`).
File? _stubBinary() {
  final exe = Platform.isWindows ? 'ipc_stub.exe' : 'ipc_stub';
  final f = File('${Directory.current.path}/../../../../agents_engine/agent/target/debug/examples/$exe');
  return f.existsSync() ? f : null;
}

Future<Process> _startStub(File bin, String agent, String dir) async {
  final p = await Process.start(bin.path, [agent, dir]);
  await p.stdout.transform(const SystemEncoding().decoder).firstWhere((l) => l.contains('listening'));
  return p;
}

void directIpcTests() {
  group('TargetTransfers over the agent IPC (real Rust server)', () {
    late Directory dir;
    late String agent;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('idrt-ipc');
      agent = 'idrt-test-$pid-${DateTime.now().microsecondsSinceEpoch}';
    });
    tearDown(() => dir.delete(recursive: true));

    TargetTransfers client() =>
        TargetTransfers(agentBinaryPath: 'unused', configPath: 'unused', dataDir: dir.path, agent: agent);

    test('nobody listening → agent_not_running, no process spawned', () async {
      final t = client();
      expect(t.direct, isTrue);
      await expectLater(t.list(), throwsA(isA<TargetTransferException>().having((e) => e.kind, 'kind', 'agent_not_running')));
      await t.close();
    });

    test('one connection serves many requests; reconnects after an agent restart', () async {
      final bin = _stubBinary();
      if (bin == null) return markTestSkipped('ipc_stub not built');
      var stub = await _startStub(bin, agent, dir.path);
      final t = client();
      try {
        final all = await t.list();
        expect((all.single.isPending, all.single.connection), (true, 'direct'));
        final peers = await t.peers();
        expect((peers.single.ski, peers.single.connection), ('src-ski', 'relayed'));

        // 300 calls on the persistent connection (a process per call is ~65 ms each).
        final sw = Stopwatch()..start();
        for (var i = 0; i < 300; i++) {
          await t.list();
        }
        sw.stop();
        // ignore: avoid_print
        print('300 list calls over the persistent connection: ${sw.elapsedMilliseconds} ms');
        expect(sw.elapsedMilliseconds, lessThan(3000));

        // accept carries an absolute path; reject's refusal keeps its stable name.
        await t.accept('00' * 16, outDir: dir.path);
        await expectLater(t.reject('00' * 16), throwsA(isA<TargetTransferException>().having((e) => e.kind, 'kind', 'rejected')));
        await expectLater(t.send('src-ski', files: ['${dir.path}/missing.bin']),
            throwsA(isA<TargetTransferException>().having((e) => e.kind, 'kind', 'invalid_argument')));
        final f = File('${dir.path}/send.txt')..writeAsStringSync('x');
        final sent = await t.send('src-ski', files: [f.path]);
        expect(sent.peer, 'src-ski');

        // The agent restarts: the next call reconnects on its own.
        stub.kill();
        await stub.exitCode;
        stub = await _startStub(bin, agent, dir.path);
        expect((await t.list()).single.peer, 'src-ski');
      } finally {
        await t.close();
        stub.kill();
        await stub.exitCode;
      }
    });
  });
}
