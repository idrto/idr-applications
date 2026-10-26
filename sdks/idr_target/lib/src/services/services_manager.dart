import '../auth/session_store.dart';
import 'port_scanner.dart';
import 'scan_hit.dart';
import 'service_entry.dart';

/// Local [[services]] list: persist, validate, scan, and expose.
class ServicesManager {
  ServicesManager({
    required SessionStore store,
    List<IdrServiceEntry>? initial,
    void Function()? onChange,
  })  : _store = store,
        _onChange = onChange,
        _services = List.of(initial ?? const []);

  static const _storeKey = 'services';

  final SessionStore _store;
  final void Function()? _onChange;
  final List<IdrServiceEntry> _services;

  List<IdrServiceEntry> get services => List.unmodifiable(_services);

  Future<void> load() async {
    final j = await _store.readJson(_storeKey);
    if (j == null) {
      if (_services.isNotEmpty) await persist();
      return;
    }
    final raw = j['entries'];
    if (raw is! List) return;
    _services
      ..clear()
      ..addAll(
        raw
            .whereType<Map>()
            .map((e) => IdrServiceEntry.fromJson(e.cast<String, dynamic>())),
      );
  }

  Future<void> persist() async {
    await _store.writeJson(_storeKey, {
      'entries': _services.map((e) => e.toJson()).toList(),
    });
  }

  String? validateName(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'Name is required';
    if (_services.any((s) => s.name == n)) return 'Name already used';
    return null;
  }

  String? validateEndpoint({
    required String type,
    required String endpoint,
  }) {
    final e = endpoint.trim();
    if (e.isEmpty) return 'Endpoint is required';
    if (type == 'tcp' && !e.contains(':')) {
      return 'Use host:port for TCP';
    }
    return null;
  }

  Future<String?> add(IdrServiceEntry entry) async {
    final err = validateName(entry.name);
    if (err != null) return err;
    _services.add(entry);
    await persist();
    _onChange?.call();
    return null;
  }

  Future<String?> addFromForm({
    required String name,
    required String type,
    required String endpoint,
    required String credentialMode,
    required bool requireTls,
    String? label,
  }) async {
    final nameErr = validateName(name);
    if (nameErr != null) return nameErr;
    final endpointErr = validateEndpoint(type: type, endpoint: endpoint);
    if (endpointErr != null) return endpointErr;

    final trimmed = endpoint.trim();
    String? baseUrl;
    String? host;
    int? port;
    if (type == 'tcp') {
      final parts = trimmed.split(':');
      host = parts.first.trim();
      port = int.tryParse(parts.length > 1 ? parts.last.trim() : '') ?? 0;
    } else {
      baseUrl = trimmed;
    }

    _services.add(
      IdrServiceEntry(
        name: name.trim(),
        type: type,
        baseUrl: baseUrl,
        host: host,
        port: port,
        credentialMode: credentialMode,
        requireUpstreamTls: requireTls,
        label: label,
      ),
    );
    await persist();
    _onChange?.call();
    return null;
  }

  Future<void> remove(String name) async {
    final before = _services.length;
    _services.removeWhere((s) => s.name == name);
    if (_services.length == before) return;
    await persist();
    _onChange?.call();
  }

  Future<void> toggle(String name) async {
    for (final s in _services) {
      if (s.name == name) {
        s.enabled = !s.enabled;
        await persist();
        _onChange?.call();
        return;
      }
    }
  }

  /// Scan listening loopback ports; omit hits already configured.
  Future<List<ScanHit>> scanExposable() async {
    final hits = await PortScanner.scanListening();
    return hits.where((h) => !_alreadyConfigured(h)).toList();
  }

  /// Add selected scan hits as [IdrServiceEntry]s. Returns how many were added.
  Future<int> exposeHits(Iterable<ScanHit> hits) async {
    var added = 0;
    for (final hit in hits) {
      if (_alreadyConfigured(hit)) continue;
      final name = _uniqueName(hit.presetName);
      _services.add(IdrServiceEntry.fromScanHit(hit, name: name));
      added++;
    }
    if (added > 0) {
      await persist();
      _onChange?.call();
    }
    return added;
  }

  bool _alreadyConfigured(ScanHit hit) {
    for (final s in _services) {
      if (s.port == hit.port &&
          (s.host ?? '127.0.0.1') == hit.host &&
          s.type == hit.type) {
        return true;
      }
      if (s.name == hit.presetName && s.port == hit.port) return true;
    }
    return false;
  }

  String _uniqueName(String base) {
    if (!_services.any((s) => s.name == base)) return base;
    var i = 2;
    while (_services.any((s) => s.name == '$base-$i')) {
      i++;
    }
    return '$base-$i';
  }
}
