/// A listening endpoint that Source can usefully open via the Target gateway.
class ScanHit {
  const ScanHit({
    required this.host,
    required this.port,
    required this.label,
    required this.presetName,
    required this.type,
    this.processName,
    this.requireUpstreamTls,
    this.credentialMode = 'source',
  });

  final String host;
  final int port;

  /// Human label (e.g. `Ollama`).
  final String label;

  /// Suggested [[services]] name (e.g. `ollama`).
  final String presetName;

  /// `http` | `tcp`
  final String type;
  final String? processName;
  final bool? requireUpstreamTls;
  final String credentialMode;

  String get hostPort => '$host:$port';

  /// Chip / row text: `Ollama · 127.0.0.1:11434`
  String get displayLabel {
    final proc = processName;
    if (proc != null &&
        proc.isNotEmpty &&
        !label.toLowerCase().contains(proc.toLowerCase())) {
      return '$label ($proc) · $hostPort';
    }
    return '$label · $hostPort';
  }
}
