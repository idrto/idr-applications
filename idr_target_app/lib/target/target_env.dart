import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:idr_target/idr_target.dart';
import 'package:path/path.dart' as p;

/// Environment contract shared with `idrt` (same variable names and defaults).
String _env(String key, String fallback) {
  final v = Platform.environment[key]?.trim();
  return v == null || v.isEmpty ? fallback : v;
}

bool get isDevMode =>
    _env('IDR_MODE', kReleaseMode ? 'production' : 'development') !=
    'production';

/// Billing portal origin (`IDR_BILLING_PORTAL_URL`; dev default is the Vite port).
String get portalBaseUrl =>
    _env('IDR_BILLING_PORTAL_URL', isDevMode ? 'http://localhost:5173' : '');

String get agentBinaryName =>
    Platform.isWindows ? 'target-agent.exe' : 'target-agent';

/// `target-agent` path: `IDR_TARGET_AGENT` -> next to this executable -> `PATH`
/// -> the repo build (`agents_engine/agent/target/{release,debug}` above the
/// current directory or the executable). Null when it cannot be found.
String? resolveAgentBinary() {
  final fromEnv = Platform.environment['IDR_TARGET_AGENT']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  final dirs = [
    File(Platform.resolvedExecutable).parent.path,
    ...(Platform.environment['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':')
        .where((d) => d.isNotEmpty),
  ];
  for (final start in [
    Directory.current,
    File(Platform.resolvedExecutable).parent,
  ]) {
    for (var dir = start; ; dir = dir.parent) {
      for (final profile in const ['release', 'debug']) {
        dirs.add(p.join(dir.path, 'agents_engine', 'agent', 'target', profile));
      }
      if (dir.parent.path == dir.path) break;
    }
  }
  for (final d in dirs) {
    final f = File(p.join(d, agentBinaryName));
    if (f.existsSync()) return f.path;
  }
  return null;
}

IdrTargetConfig buildConfig() => IdrTargetConfig(
  controlPlaneUrl: Uri.parse(
    _env('IDR_CONTROL_PLANE_URL', 'http://127.0.0.1:3000'),
  ),
  agentBinaryPath: resolveAgentBinary() ?? agentBinaryName,
  mode: isDevMode ? IdrTargetMode.development : IdrTargetMode.production,
  // "Accept to…" may pick any folder under the user's home (the user chose it
  // in the native dialog); the agent re-checks every choice, links included.
  fileTransfer: IdrFileTransferConfig(permittedDirs: [?_home]),
);

final String? _home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
