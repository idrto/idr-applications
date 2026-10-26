import 'service_entry.dart';

/// Curated local upstream preset for Target gateway exposures (`[[services]]`).
class ServicePreset {
  const ServicePreset({
    required this.label,
    required this.name,
    required this.type,
    required this.hint,
    this.baseUrl,
    this.host,
    this.port,
    this.credentialMode = 'source',
    this.requireUpstreamTls,
  });

  final String label;
  final String name;
  final String type; // http | tcp
  final String hint;
  final String? baseUrl;
  final String? host;
  final int? port;
  final String credentialMode;
  final bool? requireUpstreamTls;

  /// Map this preset to a gateway [IdrServiceEntry].
  IdrServiceEntry toServiceEntry({String? nameOverride, bool enabled = true}) {
    return IdrServiceEntry(
      name: nameOverride ?? name,
      type: type,
      baseUrl: baseUrl,
      host: host,
      port: port,
      enabled: enabled,
      credentialMode: credentialMode,
      requireUpstreamTls: requireUpstreamTls,
      label: label,
    );
  }
}

/// Well-known loopback apps Source can open over the attested Target gateway.
class ServicePresets {
  ServicePresets._();

  static const List<ServicePreset> all = [
    ServicePreset(
      label: 'Ollama',
      name: 'ollama',
      type: 'http',
      hint: 'Local LLM — secrets stay on Target when credential_mode=target',
      baseUrl: 'http://127.0.0.1:11434',
      credentialMode: 'target',
    ),
    ServicePreset(
      label: 'LM Studio',
      name: 'lmstudio',
      type: 'http',
      hint: 'Local OpenAI-compatible API',
      baseUrl: 'http://127.0.0.1:1234',
      credentialMode: 'target',
    ),
    ServicePreset(
      label: 'Postgres',
      name: 'postgres',
      type: 'tcp',
      hint: 'DB over WebRTC; prefer Source creds + upstream TLS',
      host: '127.0.0.1',
      port: 5432,
      credentialMode: 'source',
      requireUpstreamTls: true,
    ),
    ServicePreset(
      label: 'HTTP API',
      name: 'api',
      type: 'http',
      hint: 'Generic loopback HTTP upstream',
      baseUrl: 'http://127.0.0.1:8080',
      credentialMode: 'source',
    ),
  ];
}

/// Alias for app / UI call sites that still use the Upstream* names.
typedef UpstreamPreset = ServicePreset;

/// Alias for [ServicePresets].
typedef UpstreamPresets = ServicePresets;
