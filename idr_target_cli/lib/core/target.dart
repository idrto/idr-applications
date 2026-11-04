import 'dart:io';

import 'package:idr_target/idr_target.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:path/path.dart' as p;

import 'zones.dart';

String _env(String key, String fallback) {
  final v = Platform.environment[key]?.trim();
  return v == null || v.isEmpty ? fallback : v;
}

bool get _isDev => _env('IDR_MODE', 'development') != 'production';

/// Billing portal origin (`IDR_BILLING_PORTAL_URL`; dev default Vite port).
String get portalBaseUrl =>
    _env('IDR_BILLING_PORTAL_URL', _isDev ? 'http://localhost:5173' : '');

/// CLI state dir: `%APPDATA%/to.idr/idrt` or `~/.config/to.idr/idrt`.
Directory get cliDirectory {
  final appData = Platform.environment['APPDATA'];
  if (appData != null && appData.isNotEmpty) {
    return Directory(p.join(appData, 'to.idr', 'idrt'));
  }
  return Directory(
    p.join(Platform.environment['HOME'] ?? '.', '.config', 'to.idr', 'idrt'),
  );
}

/// The Target store shared with the Target GUI ([targetStoreFile]).
final cliStore = SessionStore();

String get agentBinaryName =>
    Platform.isWindows ? 'target-agent.exe' : 'target-agent';

/// `target-agent` path: `IDR_TARGET_AGENT` → next to this executable → `PATH`
/// → the repo build (`agents_engine/agent/target/{release,debug}` above the
/// current directory). The SDK needs a real file path, not a bare name.
String? resolveAgentBinary() {
  final fromEnv = Platform.environment['IDR_TARGET_AGENT']?.trim();
  if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
  final dirs = [
    File(Platform.resolvedExecutable).parent.path,
    ...(Platform.environment['PATH'] ?? '')
        .split(Platform.isWindows ? ';' : ':')
        .where((d) => d.isNotEmpty),
  ];
  for (var dir = Directory.current; ; dir = dir.parent) {
    for (final profile in const ['release', 'debug']) {
      dirs.add(p.join(dir.path, 'agents_engine', 'agent', 'target', profile));
    }
    if (dir.parent.path == dir.path) break;
  }
  for (final d in dirs) {
    final f = File(p.join(d, agentBinaryName));
    if (f.existsSync()) return f.path;
  }
  return null;
}

IdrTarget createTarget() {
  return IdrTarget(
    config: IdrTargetConfig(
      controlPlaneUrl: Uri.parse(
        _env('IDR_CONTROL_PLANE_URL', 'http://127.0.0.1:3000'),
      ),
      agentBinaryPath: resolveAgentBinary() ?? agentBinaryName,
      mode: _isDev ? IdrTargetMode.development : IdrTargetMode.production,
      // Agent files in the SDK default dir, shared with the GUI: one Target per
      // machine, and only one app runs its agent at a time.
    ),
    store: cliStore,
  );
}

/// Billing org this machine is bound to (Enterprise); null = personal (`me`).
typedef CliOrg = ({String slug, String name, String role});

const _orgKey = 'idrt.org';

Future<CliOrg?> loadOrg() async {
  final j = await cliStore.readJson(_orgKey);
  if (j == null) return null;
  return (
    slug: j['slug'] as String,
    name: j['name'] as String? ?? '',
    role: j['role'] as String? ?? 'member',
  );
}

/// Binds this machine to [org] and remembers it for [email]'s org picker.
Future<void> saveOrg(CliOrg org, String email) async {
  await cliStore.writeJson(_orgKey, {
    'slug': org.slug,
    'name': org.name,
    'role': org.role,
  });
  rememberOrg(knownOrgsFile, email, org.slug, org.name);
}

/// Organizations this machine bound before (billing doesn't list them).
File get knownOrgsFile => File(p.join(cliDirectory.path, 'orgs.json'));

/// Unbinds the org (and the zone picked in it).
Future<void> clearOrg() async {
  await cliStore.deleteSecret(_orgKey);
  await clearZoneContext();
}

/// Billing slugs are names, domains or emails, never blank or spaced; the
/// personal account has its own mode. Membership is billing's call.
String? orgSlugProblem(String slug) => RegExp(r'\s').hasMatch(slug)
    ? 'An organization slug has no spaces (e.g. acme or acme.com); copy it '
          'from the billing portal.'
    : slug == 'me' || slug == 'personal'
    ? 'That is your personal account: use Personal setup '
          '(`idrt personal setup`).'
    : null;

/// Org `owner` / `admin` can buy and register hosts; `member` cannot.
bool canBill(String role) => role == 'owner' || role == 'admin';

/// Restore state (no agent launch), run [body], always dispose.
Future<T> withTarget<T>(Future<T> Function(IdrTarget target) body) async {
  final target = createTarget();
  try {
    await target.start(launchAgent: false);
    return await body(target);
  } finally {
    await target.dispose();
  }
}

/// Fails with [CliExit.auth] unless signed in.
void requireSession(IdrTarget target) {
  if (target.session == null) {
    throw const CliError(
      CliExit.auth,
      'Not signed in. Run `idrt login` first.',
    );
  }
}

/// Plan this machine runs under (set by `idrt <mode> setup` or billing hydrate).
IdrBusinessPlan? currentPlan(IdrTarget target) =>
    IdrBusinessPlan.fromPlanCode(target.userState.planCode);

void printAttention(IdrTarget target) {
  final a = target.attention;
  if (a == null) return;
  // Signed-out / not-registered prompts are covered by status lines.
  if (a.code == IdrTargetErrorCode.authRequired ||
      a.code == IdrTargetErrorCode.hostNotRegistered) {
    return;
  }
  ui.info('attention: ${a.code.wire} — ${a.message}');
}
