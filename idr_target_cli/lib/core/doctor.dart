import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';
import 'package:path/path.dart' as p;

import 'billing.dart';
import 'target.dart';

/// The agent's fixed metrics listener (`[telemetry] metrics_listen`).
const agentMetricsPort = 9091;

// ponytail: "running" = something answers on the agent's metrics port; the
// pid file goes stale when the agent is killed. Ask the agent itself if it
// ever grows a status endpoint.
Future<bool> agentRunning() async {
  try {
    final s = await Socket.connect('127.0.0.1', agentMetricsPort,
        timeout: const Duration(seconds: 1));
    s.destroy();
    return true;
  } catch (_) {
    return false;
  }
}

const _agentHint = 'cargo build --release -p target-agent --features webrtc, '
    'then put it next to idrt, on PATH, or set IDR_TARGET_AGENT.';

class DoctorCommand extends Command<int> {
  @override
  String get name => 'doctor';

  @override
  String get description =>
      'Check configuration, connectivity, sign-in, billing, identity, '
      'target-agent and idr_dp.';

  @override
  Future<int> run() => withTarget((target) async {
        final cfg = target.config;
        final plan = currentPlan(target);
        final session = target.session;
        final reg = target.registration;
        final dir = target.configDir.path;
        final agent = resolveAgentBinary();
        final checks = <Check>[
          Check('mode', CheckStatus.ok, cfg.mode.name),
          Check('state dirs', CheckStatus.ok, '${cliDirectory.path}; $dir'),
          portalBaseUrl.isEmpty
              ? const Check('billing portal', CheckStatus.fail,
                  'IDR_BILLING_PORTAL_URL is not set',
                  hint: 'Required in production.', exitCode: CliExit.config)
              : Check('billing portal', CheckStatus.ok, portalBaseUrl),
          await httpCheck('billing API', cfg.controlPlaneBase,
              hint: 'Start billing, or set IDR_CONTROL_PLANE_URL.'),
          await httpCheck(
            'Presence discovery',
            cfg.discoveryUrl,
            hint: 'Start Presence, or set IDR_DISCOVERY_URL.',
            expect: (status, _) => status == 200 ? null : 'HTTP $status',
          ),
          session == null
              ? const Check('sign-in', CheckStatus.fail, 'signed out',
                  hint: 'idrt login', exitCode: CliExit.auth)
              : Check('sign-in', CheckStatus.ok, session.email),
          if (session != null)
            plan == null
                ? const Check('plan', CheckStatus.warn, 'no mode chosen',
                    hint: 'idrt personal setup | idrt enterprise setup --org '
                        '<slug> | idrt provider setup --org <slug>')
                : isCovered(target, plan)
                    ? Check('plan', CheckStatus.ok,
                        '${plan.title} subscription active')
                    : Check('plan', CheckStatus.fail,
                        '${plan.title} subscription missing or expired',
                        hint: 'idrt billing', exitCode: CliExit.billing),
          if (session != null)
            reg == null
                ? const Check('host', CheckStatus.warn, 'not registered',
                    hint: 'idrt <mode> register <host>')
                : target.state.enrollment.awaitingAdmin
                    ? Check('host', CheckStatus.warn,
                        '${reg.verifiedFqhn} awaiting admin approval',
                        hint: 'On the admin machine: idrt <mode> approve <id>')
                    : Check('host', CheckStatus.ok, reg.verifiedFqhn),
          File(p.join(dir, 'identity.dp.json')).existsSync()
              ? const Check('identity', CheckStatus.ok,
                  'approved certificate (identity.dp.json)')
              : const Check('identity', CheckStatus.warn,
                  'no approved certificate yet',
                  hint: 'Written by `idrt start` once the host is approved.'),
          await _agentBinaryCheck(agent),
          dpCheck(
            hint: 'cargo build --release -p idr-dp-ffi, then copy it next to '
                'idrt or set IDR_DP_LIB.',
          ),
          await _agentConfigCheck(agent, File(p.join(dir, 'target.local.toml'))),
          await agentRunning()
              ? const Check('agent process', CheckStatus.ok,
                  'running (metrics port $agentMetricsPort answers)')
              : const Check('agent process', CheckStatus.warn, 'not running',
                  hint: 'idrt start'),
        ];
        return reportChecks(checks);
      });
}

/// Runs `target-agent version`: proves the binary exists and starts.
Future<Check> _agentBinaryCheck(String? path) async {
  const name = 'target-agent';
  if (path == null || !File(path).existsSync()) {
    return Check(name, CheckStatus.fail,
        path == null ? 'not found' : '$path does not exist',
        hint: _agentHint, exitCode: CliExit.config);
  }
  try {
    final r = await Process.run(path, ['version'])
        .timeout(const Duration(seconds: 10));
    final first = '${r.stdout}'.trim().split('\n').first.trim();
    // 0xC0000135 STATUS_DLL_NOT_FOUND: Windows could not load a DLL it needs.
    const dllNotFound = -1073741515;
    return r.exitCode == 0
        ? Check(name, CheckStatus.ok, '$path ($first)')
        : Check(
            name,
            CheckStatus.fail,
            r.exitCode == dllNotFound
                ? '$path cannot start: a DLL it needs is missing'
                : '$path exited ${r.exitCode}',
            hint: r.exitCode == dllNotFound
                ? 'Install the MSVC runtime and put OpenSSL 3 '
                    '(libcrypto/libssl) next to target-agent.'
                : _agentHint,
            exitCode: CliExit.config);
  } catch (e) {
    return Check(name, CheckStatus.fail, 'cannot run $path ($e)',
        hint: _agentHint, exitCode: CliExit.config);
  }
}

/// Runs the agent's own `doctor` against the generated config.
Future<Check> _agentConfigCheck(String? agent, File toml) async {
  const name = 'agent config';
  if (!toml.existsSync()) {
    return const Check(name, CheckStatus.skip,
        'no target.local.toml yet (written by `idrt start`)');
  }
  if (agent == null || !File(agent).existsSync()) {
    return const Check(name, CheckStatus.skip, 'needs target-agent');
  }
  try {
    final r = await Process.run(agent, ['-c', toml.path, 'doctor'])
        .timeout(const Duration(seconds: 15));
    final out = '${r.stdout}';
    if (r.exitCode == 0 && out.contains('config_ok=true')) {
      final fqhn = RegExp(r'^fqhn=(.*)$', multiLine: true)
          .firstMatch(out)?[1]
          ?.trim();
      return Check(name, CheckStatus.ok,
          '${toml.path}${fqhn == null ? '' : ' (fqhn $fqhn)'}');
    }
    final why = '${r.stderr}'.trim().split('\n').first;
    return Check(name, CheckStatus.fail,
        '${toml.path} rejected: ${why.isEmpty ? 'exit ${r.exitCode}' : why}',
        hint: 'Rerun `idrt start` to regenerate it.', exitCode: CliExit.config);
  } catch (e) {
    return Check(name, CheckStatus.fail, 'agent doctor failed ($e)',
        exitCode: CliExit.config);
  }
}
