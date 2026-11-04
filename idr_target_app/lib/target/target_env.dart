import 'dart:io';

import 'package:idr_target/idr_target.dart';
import 'package:path/path.dart' as p;

/// Billing portal origin for this build's flavor (`IDR_BILLING_PORTAL_URL`).
/// Same flavor table and env overrides as `idrt` ([IdrFlavor]).
String get portalBaseUrl => IdrFlavor.current.billingPortalUrl;

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
  controlPlaneUrl: Uri.parse(IdrFlavor.current.controlPlaneUrl()),
  discoveryUrl: IdrFlavor.current.discoveryUrl,
  agentBinaryPath: resolveAgentBinary() ?? agentBinaryName,
  mode: IdrFlavor.current.isDev
      ? IdrTargetMode.development
      : IdrTargetMode.production,
  // "Accept to…" may pick any folder under the user's home (the user chose it
  // in the native dialog); the agent re-checks every choice, links included.
  fileTransfer: IdrFileTransferConfig(permittedDirs: [?_home]),
);

final String? _home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
