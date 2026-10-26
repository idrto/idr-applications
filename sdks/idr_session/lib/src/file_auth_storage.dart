import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:two_key_dart_sdk/two_key_headless.dart';

/// [BillingAuthStorage] as one JSON file (CLI / headless; no secure enclave).
///
/// Default location: `%APPDATA%\idr\secure\auth.json` or `~/.config/idr/secure/auth.json`.
class FileAuthStorage implements BillingAuthStorage {
  FileAuthStorage({File? file}) : _file = file ?? _defaultFile();

  final File _file;

  static File _defaultFile() {
    final appData = Platform.environment['APPDATA'];
    final dir = (appData != null && appData.isNotEmpty)
        ? p.join(appData, 'idr', 'secure')
        : p.join(Platform.environment['HOME'] ?? '.', '.config', 'idr', 'secure');
    return File(p.join(dir, 'auth.json'));
  }

  Future<Map<String, String>> _load() async {
    if (!await _file.exists()) return {};
    final raw = await _file.readAsString();
    final decoded = raw.isEmpty ? null : jsonDecode(raw);
    if (decoded is! Map) return {};
    return decoded.map((k, v) => MapEntry('$k', '$v'));
  }

  Future<void> _save(Map<String, String> map) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(jsonEncode(map));
  }

  @override
  Future<String?> getItem(String key) async => (await _load())[key];

  @override
  Future<void> setItem(String key, String value) async =>
      _save((await _load())..[key] = value);

  @override
  Future<void> removeItem(String key) async => _save((await _load())..remove(key));
}
