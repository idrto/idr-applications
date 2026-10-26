import 'dart:io';

import 'exposable_services.dart';
import 'scan_hit.dart';

/// Scan local listening TCP ports — only Source-exposable services.
class PortScanner {
  /// Returns labeled hits for Ollama, Postgres, Redis, LM Studio, etc.
  static Future<List<ScanHit>> scanListening({
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final hits = Platform.isWindows
        ? await _scanWindows(timeout)
        : await _scanUnix(timeout);
    // Drop secondary ports from the same app (e.g. Ollama :11434 + ephemeral).
    return _dedupeByService(hits);
  }

  /// Prefer well-known catalog ports per service; keep custom binds only when
  /// no catalog port for that service was found.
  static List<ScanHit> _dedupeByService(List<ScanHit> hits) {
    final groups = <String, List<ScanHit>>{};
    for (final h in hits) {
      groups.putIfAbsent(h.presetName, () => []).add(h);
    }
    final out = <ScanHit>[];
    for (final group in groups.values) {
      final catalog = [
        for (final h in group)
          if (ExposableServices.byPort.containsKey(h.port)) h,
      ];
      if (catalog.isNotEmpty) {
        out.addAll(catalog);
      } else {
        group.sort((a, b) => a.port.compareTo(b.port));
        out.add(group.first);
      }
    }
    out.sort((a, b) => a.port.compareTo(b.port));
    return out;
  }

  static Future<List<ScanHit>> _scanWindows(Duration timeout) async {
    try {
      final netstat = await Process.run(
        'netstat',
        ['-ano', '-p', 'TCP'],
      ).timeout(timeout);
      final listeners = _listenersFromNetstat(netstat.stdout as String);
      if (listeners.isEmpty) return const [];

      final pidNames = await _windowsPidNames(
        listeners.map((l) => l.pid).where((p) => p > 0).toSet(),
        timeout,
      );

      final seen = <String>{};
      final hits = <ScanHit>[];
      for (final l in listeners) {
        final proc = pidNames[l.pid];
        final hit = _buildHit(l.host, l.port, proc);
        if (hit == null) continue;
        final key = '${hit.presetName}:${hit.port}';
        if (!seen.add(key)) continue;
        hits.add(hit);
      }
      hits.sort((a, b) => a.port.compareTo(b.port));
      return hits;
    } catch (_) {
      return const [];
    }
  }

  static Future<Map<int, String>> _windowsPidNames(
    Set<int> pids,
    Duration timeout,
  ) async {
    if (pids.isEmpty) return const {};
    try {
      final r = await Process.run(
        'tasklist',
        ['/FO', 'CSV', '/NH'],
      ).timeout(timeout);
      final map = <int, String>{};
      for (final line in (r.stdout as String).split(RegExp(r'\r?\n'))) {
        // "chrome.exe","1234","..."
        final cols = _parseCsvLine(line.trim());
        if (cols.length < 2) continue;
        final pid = int.tryParse(cols[1]);
        if (pid == null || !pids.contains(pid)) continue;
        var name = cols[0];
        if (name.toLowerCase().endsWith('.exe')) {
          name = name.substring(0, name.length - 4);
        }
        map[pid] = name;
      }
      return map;
    } catch (_) {
      return const {};
    }
  }

  static List<String> _parseCsvLine(String line) {
    if (line.isEmpty) return const [];
    final out = <String>[];
    final re = RegExp(r'"([^"]*)"');
    for (final m in re.allMatches(line)) {
      out.add(m.group(1) ?? '');
    }
    return out;
  }

  static List<({String host, int port, int pid})> _listenersFromNetstat(
    String out,
  ) {
    // TCP    127.0.0.1:11434    0.0.0.0:0    LISTENING    1234
    final re = RegExp(
      r'^\s*TCP\s+(\S+):(\d+)\s+\S+\s+LISTENING\s+(\d+)\s*$',
      multiLine: true,
      caseSensitive: false,
    );
    final listeners = <({String host, int port, int pid})>[];
    for (final m in re.allMatches(out)) {
      var host = m.group(1)!.trim();
      final port = int.tryParse(m.group(2)!);
      final pid = int.tryParse(m.group(3)!) ?? 0;
      if (port == null) continue;
      if (host == '::' ||
          host == '0.0.0.0' ||
          host == '[::]' ||
          host == '[::1]' ||
          host == '::1') {
        host = '127.0.0.1';
      }
      // Only loopback / all-interfaces (normalized to 127.0.0.1).
      if (host != '127.0.0.1') continue;
      listeners.add((host: host, port: port, pid: pid));
    }
    return listeners;
  }

  static Future<List<ScanHit>> _scanUnix(Duration timeout) async {
    try {
      final r = await Process.run('ss', ['-lntp']).timeout(timeout);
      if (r.exitCode == 0) {
        return _hitsFromSs(r.stdout as String);
      }
      final r2 = await Process.run('netstat', ['-lnt']).timeout(timeout);
      final ports = _portsFromNetstat(r2.stdout as String);
      return _hitsFromPorts(ports);
    } catch (_) {
      return const [];
    }
  }

  static List<ScanHit> _hitsFromPorts(Iterable<int> ports) {
    final hits = <ScanHit>[];
    final seen = <String>{};
    for (final port in ports) {
      final hit = _buildHit('127.0.0.1', port, null);
      if (hit == null) continue;
      final key = '${hit.presetName}:${hit.port}';
      if (!seen.add(key)) continue;
      hits.add(hit);
    }
    hits.sort((a, b) => a.port.compareTo(b.port));
    return hits;
  }

  static List<ScanHit> _hitsFromSs(String out) {
    final withProc = RegExp(
      r'(?:127\.0\.0\.1|0\.0\.0\.0|\[::1\]|::):(\d+)\b.*users:\(\("([^"]+)"',
    );
    final seen = <String>{};
    final hits = <ScanHit>[];
    for (final m in withProc.allMatches(out)) {
      final port = int.tryParse(m.group(1)!);
      if (port == null) continue;
      final hit = _buildHit('127.0.0.1', port, m.group(2));
      if (hit == null) continue;
      final key = '${hit.presetName}:${hit.port}';
      if (!seen.add(key)) continue;
      hits.add(hit);
    }
    final portOnly = RegExp(r'(?:127\.0\.0\.1|0\.0\.0\.0|\[::1\]|::):(\d+)\b');
    for (final m in portOnly.allMatches(out)) {
      final port = int.tryParse(m.group(1)!);
      if (port == null) continue;
      if (ExposableServices.hintForPort(port) == null) continue;
      final hit = _buildHit('127.0.0.1', port, null);
      if (hit == null) continue;
      final key = '${hit.presetName}:${hit.port}';
      if (!seen.add(key)) continue;
      hits.add(hit);
    }
    hits.sort((a, b) => a.port.compareTo(b.port));
    return hits;
  }

  static Set<int> _portsFromNetstat(String out) {
    final re = RegExp(r':(\d+)\s');
    final ports = <int>{};
    for (final m in re.allMatches(out)) {
      final p = int.tryParse(m.group(1)!);
      if (p != null) ports.add(p);
    }
    return ports;
  }

  static ScanHit? _buildHit(String host, int port, String? processName) {
    if (!ExposableServices.isExposable(port, processName: processName)) {
      return null;
    }
    final hint = ExposableServices.hintForPort(port) ??
        ExposableServices.hintForProcess(processName);
    if (hint == null) return null;
    final bindHost =
        (host == '0.0.0.0' || host == '::' || host == '::1') ? '127.0.0.1' : host;
    return ScanHit(
      host: bindHost,
      port: port,
      label: hint.label,
      presetName: hint.presetName,
      type: hint.type,
      processName: processName,
      requireUpstreamTls: hint.requireUpstreamTls,
      credentialMode: hint.credentialMode,
    );
  }
}
