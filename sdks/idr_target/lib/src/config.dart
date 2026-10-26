import 'dart:io';

import 'package:idr_target/src/tls/terminator.dart';

/// Runtime mode for the Target SDK.
enum IdrTargetMode {
  /// Full Auth/Billing + seat checks.
  production,

  /// Local control plane; softens seat/cosign when Billing allows `AUTH_AGENT_TOKEN_DEV_ALLOW`.
  development,
}

/// TLS configuration. No free-form Presence FQHN here.
class IdrTlsConfig {
  const IdrTlsConfig({
    this.terminator = const NginxTerminator(),
    this.certDir,
    this.enableEntityCaLeaf = false,
  });

  /// Local TLS terminator (nginx default; HAProxy via adapter).
  final IdrTlsTerminator terminator;

  /// Directory for materialized fullchain/privkey (Phase 2 / ACME).
  final String? certDir;

  /// Phase 2: request Entity-CA leaf for personal/enterprise native FQHNs.
  /// Phase 1 leaves this false (Relay terminates `*.idr.to`).
  final bool enableEntityCaLeaf;
}

/// Top-level SDK configuration.
class IdrTargetConfig {
  IdrTargetConfig({
    /// Single Auth+Billing control plane (billing). Preferred.
    Uri? controlPlaneUrl,

    /// Deprecated alias for [controlPlaneUrl].
    Uri? apiBaseUrl,
    required this.agentBinaryPath,

    /// Deprecated — ignored when [controlPlaneUrl] / [apiBaseUrl] set; kept for
    /// binary compatibility. Prefer one [controlPlaneUrl].
    Uri? billingBaseUrl,
    this.mode = IdrTargetMode.production,
    String? discoveryUrl,
    String? discoveryKey,
    String? agentRegion,
    bool? insecureDev,
    this.httpUpstream = '127.0.0.1:18080',
    this.tlsUpstream = '127.0.0.1:443',
    this.tls = const IdrTlsConfig(),
    this.configDirectory,
    this.maxAgentRestarts = 5,
    this.agentRestartInitialDelay = const Duration(seconds: 1),
    this.agentRestartMaxDelay = const Duration(seconds: 30),
  })  : controlPlaneUrl = controlPlaneUrl ??
            apiBaseUrl ??
            billingBaseUrl ??
            (throw ArgumentError(
              'controlPlaneUrl (or apiBaseUrl) is required',
            )),
        apiBaseUrl = controlPlaneUrl ?? apiBaseUrl ?? billingBaseUrl!,
        billingBaseUrl = billingBaseUrl ?? controlPlaneUrl ?? apiBaseUrl!,
        discoveryUrl = _resolveDiscoveryUrl(mode, discoveryUrl),
        // Public verifying key (not a secret). Required so target-agent can boot
        // against live slim discovery (public.idr.to) which omits per-server keys.
        // Local mock Presence still works: insecure_dev skips a failed verify.
        discoveryKey =
            discoveryKey ?? 'lQuEz1V7pbbyCT-li64zM0Wee6dC42L3zKaeJ8UKg6w',
        agentRegion = agentRegion ??
            (mode == IdrTargetMode.development ? 'local' : 'eu-central'),
        insecureDev = insecureDev ?? (mode == IdrTargetMode.development);

  /// Billing Auth+Billing control plane origin.
  final Uri controlPlaneUrl;

  /// @Deprecated Use [controlPlaneUrl].
  final Uri apiBaseUrl;

  /// @Deprecated Use [controlPlaneUrl].
  final Uri billingBaseUrl;

  final String agentBinaryPath;
  final IdrTargetMode mode;
  final String discoveryUrl;
  final String discoveryKey;
  final String agentRegion;
  final String httpUpstream;
  final String tlsUpstream;
  final bool insecureDev;
  final IdrTlsConfig tls;

  /// Override config dir; default `%APPDATA%/to.idr/idr_target` on Windows.
  final String? configDirectory;

  final int maxAgentRestarts;
  final Duration agentRestartInitialDelay;
  final Duration agentRestartMaxDelay;

  String get controlPlaneBase =>
      controlPlaneUrl.toString().replaceAll(RegExp(r'/$'), '');

  /// @Deprecated Use [controlPlaneBase].
  String get apiBase => controlPlaneBase;

  /// @Deprecated Use [controlPlaneBase].
  String get billingBase => controlPlaneBase;

  static String _resolveDiscoveryUrl(IdrTargetMode mode, String? explicit) {
    final fromEnv = Platform.environment['IDR_DISCOVERY_URL']?.trim();
    if (fromEnv != null && fromEnv.isNotEmpty) return fromEnv;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    if (mode == IdrTargetMode.development) {
      return 'http://127.0.0.1:8081/.well-known/idr-presence.json';
    }
    return 'https://public.idr.to/.well-known/idr-presence.json';
  }
}
