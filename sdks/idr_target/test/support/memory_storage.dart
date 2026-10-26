import 'package:two_key_dart_sdk/two_key_dart_sdk.dart';

/// In-memory [BillingAuthStorage] for tests.
class MemoryStorage implements BillingAuthStorage {
  final Map<String, String> map = {};

  @override
  Future<String?> getItem(String key) async => map[key];

  @override
  Future<void> setItem(String key, String value) async => map[key] = value;

  @override
  Future<void> removeItem(String key) async => map.remove(key);
}
