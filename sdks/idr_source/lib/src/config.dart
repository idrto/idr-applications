import 'dart:io';

import 'package:idr_session/idr_session.dart' show IdrFlavor;

/// Runtime mode for the Source SDK.
enum IdrSourceMode {
  development,
  production,
}

/// Top-level Source SDK configuration (billing API + Presence discovery).
class IdrSourceConfig {
  const IdrSourceConfig({
    required this.mode,
    required this.apiBaseUrl,
    required this.discoveryUrl,
    this.libraryPath,
    this.insecureDev = false,
    this.sourceRegion = 'local',
  });

  final IdrSourceMode mode;

  /// Auth/Billing control plane origin (no trailing slash required).
  final String apiBaseUrl;

  /// Presence discovery document URL.
  final String discoveryUrl;

  /// Native `idr_c_api` library path; null → resolve via env / walk-up.
  final String? libraryPath;

  /// Allow insecure local Presence (dev only).
  final bool insecureDev;

  final String sourceRegion;

  String get apiBase => apiBaseUrl.replaceAll(RegExp(r'/$'), '');

  /// [flavor]'s billing + discovery URLs; env overrides `IDR_API_BASE_URL`,
  /// `IDR_DISCOVERY_URL`, `IDR_C_API_LIB` (see [IdrFlavor]).
  factory IdrSourceConfig.forFlavor(IdrFlavor flavor) {
    final envLib = Platform.environment['IDR_C_API_LIB']?.trim();
    return IdrSourceConfig(
      mode: flavor.isDev ? IdrSourceMode.development : IdrSourceMode.production,
      apiBaseUrl: flavor.controlPlaneUrl('IDR_API_BASE_URL'),
      discoveryUrl: flavor.discoveryUrl,
      libraryPath: (envLib != null && envLib.isNotEmpty) ? envLib : null,
      insecureDev: flavor.isDev,
      sourceRegion: flavor.isDev ? 'local' : 'unknown',
    );
  }
}
