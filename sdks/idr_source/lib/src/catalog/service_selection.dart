import 'package:idr_client/idr_client.dart' show NamedServiceInfo;

/// Named Target service the Source is talking to.
class ServiceSelection {
  const ServiceSelection({
    required this.name,
    required this.kind,
    this.hostHeader,
    this.credentialMode = 'source',
    this.requireUpstreamTls = false,
  });

  final String name;

  /// `ollama` | `huggingface` | `openai` | `postgres` | `generic`
  final String kind;
  final String? hostHeader;

  /// From Target catalog: `source` | `target`.
  final String credentialMode;

  /// From Target catalog — Source must use TLS inside the mux stream.
  final bool requireUpstreamTls;

  static const ollama = ServiceSelection(
    name: 'ollama',
    kind: 'ollama',
    hostHeader: '127.0.0.1:11434',
    credentialMode: 'target',
  );

  static const huggingface = ServiceSelection(
    name: 'huggingface',
    kind: 'huggingface',
    hostHeader: 'router.huggingface.co',
    credentialMode: 'target',
  );

  /// Built-in nginx / transport names — hide from the service picker.
  static const catalogSkip = {
    'http',
    'https',
    'web',
    'tcp',
    'tls',
    'http_passthrough',
    'tls_passthrough',
    'tcp_connect',
  };

  /// Map a Target-advertised service name to a selection + API flavor.
  factory ServiceSelection.fromAdvertisedName(
    String name, {
    String credentialMode = 'source',
    bool requireUpstreamTls = false,
  }) {
    final key = name.trim().toLowerCase();
    final compact = key.replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (compact == 'ollama' || compact.startsWith('ollama')) {
      return ServiceSelection(
        name: name,
        kind: 'ollama',
        hostHeader: '127.0.0.1:11434',
        credentialMode: credentialMode,
        requireUpstreamTls: requireUpstreamTls,
      );
    }
    if (compact.contains('huggingface') || compact == 'hf') {
      return ServiceSelection(
        name: name,
        kind: 'huggingface',
        hostHeader: 'router.huggingface.co',
        credentialMode: credentialMode,
        requireUpstreamTls: requireUpstreamTls,
      );
    }
    if (compact.contains('postgres') ||
        compact.contains('pgsql') ||
        compact == 'pg') {
      return ServiceSelection(
        name: name,
        kind: 'postgres',
        credentialMode: credentialMode,
        requireUpstreamTls: requireUpstreamTls,
      );
    }
    // LM Studio and other OpenAI-compatible local gateways.
    if (compact.contains('lmstudio') ||
        compact.contains('openai') ||
        compact.contains('studio') ||
        compact == 'lms') {
      return ServiceSelection(
        name: name,
        kind: 'openai',
        hostHeader: '127.0.0.1:1234',
        credentialMode: credentialMode,
        requireUpstreamTls: requireUpstreamTls,
      );
    }
    return ServiceSelection(
      name: name,
      kind: 'generic',
      hostHeader: name,
      credentialMode: credentialMode,
      requireUpstreamTls: requireUpstreamTls,
    );
  }

  static List<ServiceSelection> fromCatalog(Iterable<String> names) {
    final out = <ServiceSelection>[];
    final seen = <String>{};
    for (final raw in names) {
      final name = raw.trim();
      if (name.isEmpty) continue;
      if (catalogSkip.contains(name.toLowerCase())) continue;
      if (!seen.add(name.toLowerCase())) continue;
      out.add(ServiceSelection.fromAdvertisedName(name));
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Case-insensitive match on [name], or null.
  static ServiceSelection? named(
      Iterable<ServiceSelection> services, String? name) {
    final key = name?.trim().toLowerCase();
    if (key == null || key.isEmpty) return null;
    for (final s in services) {
      if (s.name.toLowerCase() == key) return s;
    }
    return null;
  }

  static List<ServiceSelection> fromCatalogEntries(
    Iterable<NamedServiceInfo> entries,
  ) {
    final out = <ServiceSelection>[];
    final seen = <String>{};
    for (final e in entries) {
      final name = e.name.trim();
      if (name.isEmpty) continue;
      if (catalogSkip.contains(name.toLowerCase())) continue;
      if (!seen.add(name.toLowerCase())) continue;
      out.add(
        ServiceSelection.fromAdvertisedName(
          name,
          credentialMode: e.credentialMode,
          requireUpstreamTls: e.requireUpstreamTls,
        ),
      );
    }
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  String get shortLabel {
    switch (kind) {
      case 'ollama':
        return name.toLowerCase() == 'ollama' ? 'Ollama' : name;
      case 'huggingface':
        return name.toLowerCase() == 'huggingface' ? 'Hugging Face' : name;
      case 'openai':
        return name;
      case 'postgres':
        return name.toLowerCase() == 'postgres' ? 'Postgres' : name;
      default:
        return name;
    }
  }

  bool get isOllama => kind == 'ollama';
  bool get isHuggingFace => kind == 'huggingface';
  bool get isOpenAiCompatible => kind == 'openai' || kind == 'huggingface';
  bool get isGeneric => kind == 'generic';
  bool get isPostgres => kind == 'postgres';
  bool get sourceProvidesCredentials => credentialMode == 'source';

  /// Chat-capable kinds for CLI REPL entry.
  bool get isChatKind =>
      isOllama || isHuggingFace || isOpenAiCompatible || isGeneric;

  @override
  bool operator ==(Object other) =>
      other is ServiceSelection &&
      other.name == name &&
      other.kind == kind &&
      other.credentialMode == credentialMode &&
      other.requireUpstreamTls == requireUpstreamTls;

  @override
  int get hashCode =>
      Object.hash(name, kind, credentialMode, requireUpstreamTls);
}
