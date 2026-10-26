/// Curated ports / process names that are worth exposing to Source.
class ExposableServices {
  ExposableServices._();

  /// Well-known local ports Source can use over the generic gateway.
  static const Map<int, PortHint> byPort = {
    // AI / LLM
    11434: PortHint('Ollama', 'ollama', 'http', credentialMode: 'target'),
    1234: PortHint('LM Studio', 'lmstudio', 'http', credentialMode: 'target'),
    8000: PortHint('HTTP API', 'http-8000', 'http', credentialMode: 'target'),
    8001: PortHint('vLLM / HTTP', 'vllm', 'http', credentialMode: 'target'),
    8080: PortHint('HTTP API', 'http-8080', 'http', credentialMode: 'target'),
    8888: PortHint('Jupyter / HTTP', 'jupyter', 'http', credentialMode: 'target'),
    7860: PortHint('Gradio', 'gradio', 'http', credentialMode: 'target'),
    5000: PortHint('HTTP API', 'http-5000', 'http', credentialMode: 'target'),
    5001: PortHint('HTTP API', 'http-5001', 'http', credentialMode: 'target'),
    // Databases
    5432: PortHint(
      'Postgres',
      'postgres',
      'tcp',
      credentialMode: 'source',
      requireUpstreamTls: true,
    ),
    5433: PortHint(
      'Postgres',
      'postgres',
      'tcp',
      credentialMode: 'source',
      requireUpstreamTls: true,
    ),
    3306: PortHint(
      'MySQL',
      'mysql',
      'tcp',
      credentialMode: 'source',
      requireUpstreamTls: true,
    ),
    1433: PortHint(
      'SQL Server',
      'mssql',
      'tcp',
      credentialMode: 'source',
      requireUpstreamTls: true,
    ),
    6379: PortHint('Redis', 'redis', 'tcp', credentialMode: 'source'),
    27017: PortHint('MongoDB', 'mongodb', 'tcp', credentialMode: 'source'),
    9200: PortHint(
      'Elasticsearch',
      'elasticsearch',
      'http',
      credentialMode: 'source',
    ),
    5984: PortHint('CouchDB', 'couchdb', 'http', credentialMode: 'source'),
    // Messaging / cache
    5672: PortHint('RabbitMQ', 'rabbitmq', 'tcp', credentialMode: 'source'),
    11211: PortHint('Memcached', 'memcached', 'tcp', credentialMode: 'source'),
  };

  /// Process-name substrings → service hint (for non-standard ports).
  static const List<ProcHint> byProcess = [
    ProcHint(['ollama'], 'Ollama', 'ollama', 'http', credentialMode: 'target'),
    ProcHint(
      ['lm studio', 'lmstudio', 'lms.exe'],
      'LM Studio',
      'lmstudio',
      'http',
      credentialMode: 'target',
    ),
    ProcHint(
      ['postgres', 'pgsql'],
      'Postgres',
      'postgres',
      'tcp',
      credentialMode: 'source',
      requireUpstreamTls: true,
    ),
    ProcHint(
      ['mysqld', 'mariadbd'],
      'MySQL',
      'mysql',
      'tcp',
      credentialMode: 'source',
      requireUpstreamTls: true,
    ),
    ProcHint(['redis-server', 'redis'], 'Redis', 'redis', 'tcp'),
    ProcHint(['mongod'], 'MongoDB', 'mongodb', 'tcp'),
    ProcHint(['vllm'], 'vLLM', 'vllm', 'http', credentialMode: 'target'),
  ];

  /// Ports we never show (OS / admin / IDR control plane noise).
  static const Set<int> blockedPorts = {
    22, 23, 25, 53, 110, 135, 137, 138, 139, 445, 993, 995,
    1720, 1755, 1900, 2869, 3389, 5353, 5355, 7680,
    8081, // local Presence often
    9091, // target-agent metrics
    18080, 18443, // target nginx defaults in local TOML
  };

  static PortHint? hintForPort(int port) => byPort[port];

  static PortHint? hintForProcess(String? processName) {
    if (processName == null || processName.isEmpty) return null;
    final lower = processName.toLowerCase();
    for (final h in byProcess) {
      for (final key in h.keys) {
        if (lower.contains(key)) {
          return PortHint(
            h.label,
            h.presetName,
            h.type,
            credentialMode: h.credentialMode,
            requireUpstreamTls: h.requireUpstreamTls,
          );
        }
      }
    }
    return null;
  }

  static bool isExposable(int port, {String? processName}) {
    if (blockedPorts.contains(port)) return false;
    if (byPort.containsKey(port)) return true;
    return hintForProcess(processName) != null;
  }
}

class PortHint {
  const PortHint(
    this.label,
    this.presetName,
    this.type, {
    this.credentialMode = 'source',
    this.requireUpstreamTls,
  });

  final String label;
  final String presetName;
  final String type;
  final String credentialMode;
  final bool? requireUpstreamTls;
}

class ProcHint {
  const ProcHint(
    this.keys,
    this.label,
    this.presetName,
    this.type, {
    this.credentialMode = 'source',
    this.requireUpstreamTls,
  });

  final List<String> keys;
  final String label;
  final String presetName;
  final String type;
  final String credentialMode;
  final bool? requireUpstreamTls;
}
