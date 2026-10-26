import 'dart:io';

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

  /// Mode defaults, then optional env overrides:
  /// `IDR_API_BASE_URL`, `IDR_DISCOVERY_URL`, `IDR_C_API_LIB`.
  factory IdrSourceConfig.defaults(IdrSourceMode mode) {
    late final IdrSourceConfig base;
    switch (mode) {
      case IdrSourceMode.development:
        base = const IdrSourceConfig(
          mode: IdrSourceMode.development,
          apiBaseUrl: 'http://127.0.0.1:3000',
          discoveryUrl: 'http://127.0.0.1:8081/.well-known/idr-presence.json',
          libraryPath: null,
          insecureDev: true,
          sourceRegion: 'local',
        );
      case IdrSourceMode.production:
        // Production stubs — replace when shipping.
        base = const IdrSourceConfig(
          mode: IdrSourceMode.production,
          apiBaseUrl: 'http://127.0.0.1:3000',
          discoveryUrl: 'https://public.idr.to/.well-known/idr-presence.json',
          libraryPath: null,
          insecureDev: false,
          sourceRegion: 'unknown',
        );
    }

    final envApi = Platform.environment['IDR_API_BASE_URL']?.trim();
    final envDiscovery = Platform.environment['IDR_DISCOVERY_URL']?.trim();
    final envLib = Platform.environment['IDR_C_API_LIB']?.trim();

    return IdrSourceConfig(
      mode: base.mode,
      apiBaseUrl:
          (envApi != null && envApi.isNotEmpty) ? envApi : base.apiBaseUrl,
      discoveryUrl: (envDiscovery != null && envDiscovery.isNotEmpty)
          ? envDiscovery
          : base.discoveryUrl,
      libraryPath:
          (envLib != null && envLib.isNotEmpty) ? envLib : base.libraryPath,
      insecureDev: base.insecureDev,
      sourceRegion: base.sourceRegion,
    );
  }
}
