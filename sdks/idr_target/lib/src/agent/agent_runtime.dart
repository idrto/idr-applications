import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../entitlement/agent_token_client.dart';
import '../errors.dart';
import '../internal/backoff.dart';
import '../internal/logging.dart';
import '../services/service_entry.dart';
import '../state/agent_runtime_status.dart';
import 'health_monitor.dart';
import 'identity_key_file.dart';
import 'process_manager.dart';
import 'toml_writer.dart';

/// Where the agent keeps Let's Encrypt certificates (and each domain's
/// `acme-status.json`) under the SDK config dir.
String acmeCertDir(Directory configDir) =>
    p.join(configDir.path, 'acme', 'certs');

/// Writes TOML, starts/stops `target-agent`, and runs the health monitor.
class AgentRuntime {
  AgentRuntime({
    required this.config,
    required this.configDir,
    this.requireSourcePolicy,
    this.customDomains,
    this.onStatus,
    this.onAttention,
    ProcessManager? processManager,
  }) : _process = processManager;

  final IdrTargetConfig config;
  final Directory Function() configDir;

  /// Written as `[webrtc.policy].require_source_policy`: refuse Sources
  /// without a Presence-verified policy. Read at each config write.
  final bool Function()? requireSourcePolicy;

  /// Verified custom domains for this Target (billing), written as
  /// `[acme].domains` so the agent gets Let's Encrypt certificates for them.
  /// Read at each config write; an empty list leaves ACME off.
  final Future<List<String>> Function(String verifiedFqhn)? customDomains;
  final void Function(AgentRuntimeStatus status)? onStatus;
  final void Function(IdrTargetAttention attention)? onAttention;

  final Map<String, String> injectEnv = {};

  ProcessManager? _process;
  StreamSubscription<String>? _logSub;
  HealthMonitor? _health;
  AgentRuntimeStatus status = AgentRuntimeStatus.stopped;
  String? _configPath;
  String? _jwtPath;

  Future<EntitlementToken?> Function()? _ensureFreshEntitlement;
  _AgentStartArgs? _lastStart;

  void _setStatus(AgentRuntimeStatus s) {
    status = s;
    onStatus?.call(s);
  }

  /// Start agent with current services + entitlement JWT.
  ///
  /// [targetIdentityPem] / [targetIdentityPublicB64url] must be the same
  /// Ed25519 key bound into [entitlement] (`target_identity` claim).
  ///
  /// [dpIdentityJson] is optional `identity.dp.json` for Presence PEP mTLS.
  Future<void> start({
    required String verifiedFqhn,
    required String usingParty,
    required EntitlementToken entitlement,
    required List<IdrServiceEntry> services,
    required String targetIdentityPem,
    required String targetIdentityPublicB64url,
    String? dpIdentityJson,
    Future<EntitlementToken?> Function()? ensureFreshEntitlement,
  }) async {
    _ensureFreshEntitlement = ensureFreshEntitlement;
    _lastStart = _AgentStartArgs(
      verifiedFqhn: verifiedFqhn,
      usingParty: usingParty,
      services: services,
      targetIdentityPem: targetIdentityPem,
      targetIdentityPublicB64url: targetIdentityPublicB64url,
      dpIdentityJson: dpIdentityJson,
    );

    if (!File(config.agentBinaryPath).existsSync()) {
      idrLog('agent: binary missing at ${config.agentBinaryPath}');
      onAttention?.call(IdrTargetAttention(
        code: IdrTargetErrorCode.agentBinaryMissing,
        message: IdrTargetMessages.agentBinaryMissing(config.agentBinaryPath),
      ));
      return;
    }

    _setStatus(AgentRuntimeStatus.starting);
    final dir = configDir();
    final jwtPath = p.join(dir.path, 'entitlement.jwt');
    _jwtPath = jwtPath;
    await File(jwtPath).writeAsString(entitlement.token);
    // Agent KeyPair JSON (works with current release binary). Same public key
    // as entitlement JWT `target_identity`.
    final identityPath = p.join(dir.path, 'target.identity.key');
    await File(identityPath).writeAsString(
      agentIdentityKeyJson(
        privatePem: targetIdentityPem,
        publicB64url: targetIdentityPublicB64url,
      ),
    );
    // Remove failed PEM attempt from earlier wiring (if present).
    final stalePem = File(p.join(dir.path, 'target.identity.pem'));
    if (stalePem.existsSync()) {
      try {
        await stalePem.delete();
      } catch (_) {}
    }

    String? dpIdentityPath;
    if (dpIdentityJson != null && dpIdentityJson.trim().isNotEmpty) {
      dpIdentityPath = p.join(dir.path, 'identity.dp.json');
      await File(dpIdentityPath).writeAsString(dpIdentityJson);
    }

    final acmeDomains =
        await customDomains?.call(verifiedFqhn) ?? const <String>[];
    final writer = TomlWriter(
      fqhn: verifiedFqhn,
      agentRegion: config.agentRegion,
      usingParty: usingParty,
      discoveryUrl: config.discoveryUrl,
      discoveryKey: config.discoveryKey,
      services: services,
      httpUpstream: config.httpUpstream,
      tlsUpstream: config.tlsUpstream,
      insecureDev:
          config.insecureDev || config.mode == IdrTargetMode.development,
      entitlementJwtPath: jwtPath,
      identityKeyPath: identityPath,
      dpIdentityPath: dpIdentityPath,
      acmeEnabled: acmeDomains.isNotEmpty,
      acmeDomains: acmeDomains,
      acmeEmail: usingParty,
      acmeStaging: config.mode == IdrTargetMode.development,
      acmeWebroot: p.join(dir.path, 'acme', 'webroot'),
      acmeCertDir: acmeCertDir(dir),
      requireSourcePolicy: requireSourcePolicy?.call() ?? false,
    );
    final toml = await writer.writeTo(dir);
    _configPath = toml.path;
    idrLog(
      'agent: writing ${toml.path} fqhn=$verifiedFqhn '
      'discovery=${config.discoveryUrl}',
    );

    if (_process == null) {
      _process = ProcessManager();
      _logSub = _process!.logs.listen((line) {
        for (final part in line.split('\n')) {
          final t = part.trimRight();
          if (t.isNotEmpty) idrLog('agent: $t');
        }
      });
    }
    await _process!.start(
      binaryPath: config.agentBinaryPath,
      configPath: toml.path,
      workingDirectory: dir.path,
      injectEnv: injectEnv,
      entitlementJwt: entitlement.token,
    );
    idrLog('agent: process started binary=${config.agentBinaryPath}');

    final backoff = Backoff(
      initial: config.agentRestartInitialDelay,
      max: config.agentRestartMaxDelay,
    );
    await _health?.stop();
    _health = HealthMonitor(
      process: _process!,
      maxRestarts: config.maxAgentRestarts,
      backoff: backoff,
      onRestart: () async {
        _setStatus(AgentRuntimeStatus.reconnecting);
        final fresh = await _ensureFreshEntitlement?.call();
        final jwt = fresh?.token ?? entitlement.token;
        if (fresh != null) {
          await File(jwtPath).writeAsString(jwt);
        }
        await _process!.start(
          binaryPath: config.agentBinaryPath,
          configPath: _configPath ?? toml.path,
          workingDirectory: dir.path,
          injectEnv: injectEnv,
          entitlementJwt: jwt,
        );
        _setStatus(AgentRuntimeStatus.running);
      },
      onBudgetExceeded: () {
        onAttention?.call(const IdrTargetAttention(
          code: IdrTargetErrorCode.agentCrashBudgetExceeded,
          message: IdrTargetMessages.agentCrashBudgetExceeded,
        ));
      },
    );
    _health!.start();
    _setStatus(AgentRuntimeStatus.running);
  }

  /// Rewrite TOML and restart the process when services change.
  Future<void> reloadConfig({
    required String verifiedFqhn,
    required String usingParty,
    required EntitlementToken entitlement,
    required List<IdrServiceEntry> services,
    required String targetIdentityPem,
    required String targetIdentityPublicB64url,
    String? dpIdentityJson,
    Future<EntitlementToken?> Function()? ensureFreshEntitlement,
  }) async {
    if (status == AgentRuntimeStatus.stopped) return;
    await stop();
    await start(
      verifiedFqhn: verifiedFqhn,
      usingParty: usingParty,
      entitlement: entitlement,
      services: services,
      targetIdentityPem: targetIdentityPem,
      targetIdentityPublicB64url: targetIdentityPublicB64url,
      dpIdentityJson: dpIdentityJson,
      ensureFreshEntitlement: ensureFreshEntitlement,
    );
  }

  /// Dart reminted the JWT — write it and restart the agent so Presence
  /// registration picks up the new token. Does not mint inside the agent.
  Future<void> applyFreshEntitlement(EntitlementToken token) async {
    if (status == AgentRuntimeStatus.stopped) return;
    final args = _lastStart;
    if (args == null) return;
    final jwtPath = _jwtPath;
    if (jwtPath != null) {
      await File(jwtPath).writeAsString(token.token);
    }
    idrLog('agent: applying refreshed entitlement JWT');
    await stop();
    await start(
      verifiedFqhn: args.verifiedFqhn,
      usingParty: args.usingParty,
      entitlement: token,
      services: args.services,
      targetIdentityPem: args.targetIdentityPem,
      targetIdentityPublicB64url: args.targetIdentityPublicB64url,
      dpIdentityJson: args.dpIdentityJson,
      ensureFreshEntitlement: _ensureFreshEntitlement,
    );
  }

  Future<void> stop() async {
    await _health?.stop();
    _health = null;
    await _process?.stop();
    _setStatus(AgentRuntimeStatus.stopped);
  }

  Future<void> dispose() async {
    await stop();
    await _logSub?.cancel();
    _logSub = null;
    await _process?.dispose();
    _process = null;
  }
}

class _AgentStartArgs {
  const _AgentStartArgs({
    required this.verifiedFqhn,
    required this.usingParty,
    required this.services,
    required this.targetIdentityPem,
    required this.targetIdentityPublicB64url,
    this.dpIdentityJson,
  });

  final String verifiedFqhn;
  final String usingParty;
  final List<IdrServiceEntry> services;
  final String targetIdentityPem;
  final String targetIdentityPublicB64url;
  final String? dpIdentityJson;
}
