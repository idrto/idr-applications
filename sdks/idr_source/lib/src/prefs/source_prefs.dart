import 'dart:convert';
import 'dart:io';

import 'package:idr_session/idr_session.dart' show idrSourceDirectory;
import 'package:path/path.dart' as p;

/// Optional non-secret prefs (last FQHN / active service / model).
abstract class SourcePrefs {
  Future<String?> get lastFqhn;
  Future<void> setLastFqhn(String? v);
  Future<String?> get activeService;
  Future<void> setActiveService(String? v);
  Future<String?> get activeModel;
  Future<void> setActiveModel(String? v);
}

/// In-memory prefs for tests.
class MemorySourcePrefs implements SourcePrefs {
  String? _lastFqhn;
  String? _activeService;
  String? _activeModel;

  @override
  Future<String?> get lastFqhn async => _lastFqhn;

  @override
  Future<void> setLastFqhn(String? v) async => _lastFqhn = v;

  @override
  Future<String?> get activeService async => _activeService;

  @override
  Future<void> setActiveService(String? v) async => _activeService = v;

  @override
  Future<String?> get activeModel async => _activeModel;

  @override
  Future<void> setActiveModel(String? v) async => _activeModel = v;
}

/// JSON file prefs under a config directory (CLI).
class FileSourcePrefs implements SourcePrefs {
  FileSourcePrefs({Directory? directory})
      : _directory = directory ?? defaultDirectory();

  final Directory _directory;

  static Directory defaultDirectory() => idrSourceDirectory;

  File get _file => File(p.join(_directory.path, 'prefs.json'));

  Future<Map<String, dynamic>> _load() async {
    if (!await _file.exists()) return {};
    final raw = await _file.readAsString();
    if (raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return {};
    return Map<String, dynamic>.from(decoded);
  }

  Future<void> _save(Map<String, dynamic> map) async {
    if (!await _directory.exists()) {
      await _directory.create(recursive: true);
    }
    await _file.writeAsString(const JsonEncoder.withIndent('  ').convert(map));
  }

  Future<String?> _get(String key) async {
    final map = await _load();
    final v = map[key];
    if (v == null) return null;
    final s = v.toString();
    return s.isEmpty ? null : s;
  }

  Future<void> _set(String key, String? v) async {
    final map = await _load();
    if (v == null || v.isEmpty) {
      map.remove(key);
    } else {
      map[key] = v;
    }
    await _save(map);
  }

  @override
  Future<String?> get lastFqhn => _get('lastFqhn');

  @override
  Future<void> setLastFqhn(String? v) => _set('lastFqhn', v);

  @override
  Future<String?> get activeService => _get('activeService');

  @override
  Future<void> setActiveService(String? v) => _set('activeService', v);

  @override
  Future<String?> get activeModel => _get('activeModel');

  @override
  Future<void> setActiveModel(String? v) => _set('activeModel', v);
}
