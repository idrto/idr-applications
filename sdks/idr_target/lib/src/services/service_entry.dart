import 'scan_hit.dart';

/// One Target [[services]] gateway entry.
class IdrServiceEntry {
  IdrServiceEntry({
    required this.name,
    this.type = 'http',
    this.baseUrl,
    this.host,
    this.port,
    this.enabled = true,
    this.authEnvVar,
    this.authHeaderName = 'Authorization',
    this.authPrefix = 'Bearer ',
    this.credentialMode = 'source',
    this.requireUpstreamTls,
    this.label,
  });

  String name;
  String type;
  String? baseUrl;
  String? host;
  int? port;
  bool enabled;
  String? authEnvVar;
  String authHeaderName;
  String authPrefix;
  String credentialMode;
  bool? requireUpstreamTls;

  /// Optional human display label (e.g. `Ollama`); [name] remains the stream id.
  String? label;

  String get endpoint {
    if (type == 'tcp') {
      return '${host ?? '127.0.0.1'}:${port ?? 0}';
    }
    return baseUrl ?? '—';
  }

  factory IdrServiceEntry.fromScanHit(ScanHit hit, {String? name}) {
    return IdrServiceEntry(
      name: name ?? hit.presetName,
      type: hit.type,
      baseUrl: hit.type == 'http' ? 'http://${hit.host}:${hit.port}' : null,
      host: hit.host,
      port: hit.port,
      credentialMode: hit.credentialMode,
      requireUpstreamTls: hit.requireUpstreamTls,
      label: hit.label,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'type': type,
        if (baseUrl != null) 'baseUrl': baseUrl,
        if (host != null) 'host': host,
        if (port != null) 'port': port,
        'enabled': enabled,
        if (authEnvVar != null) 'authEnvVar': authEnvVar,
        'authHeaderName': authHeaderName,
        'authPrefix': authPrefix,
        'credentialMode': credentialMode,
        if (requireUpstreamTls != null)
          'requireUpstreamTls': requireUpstreamTls,
        if (label != null) 'label': label,
      };

  factory IdrServiceEntry.fromJson(Map<String, dynamic> j) => IdrServiceEntry(
        name: j['name'] as String? ?? '',
        type: j['type'] as String? ?? 'http',
        baseUrl: j['baseUrl'] as String?,
        host: j['host'] as String?,
        port: j['port'] as int?,
        enabled: j['enabled'] as bool? ?? true,
        authEnvVar: j['authEnvVar'] as String?,
        authHeaderName: j['authHeaderName'] as String? ?? 'Authorization',
        authPrefix: j['authPrefix'] as String? ?? 'Bearer ',
        credentialMode: j['credentialMode'] as String? ?? 'source',
        requireUpstreamTls: j['requireUpstreamTls'] as bool?,
        label: j['label'] as String?,
      );
}
