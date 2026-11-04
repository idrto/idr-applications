import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:two_key_dart_sdk/two_key_headless.dart';

import 'package:idr_session/idr_session.dart';

/// This machine's Target, shared by the Target GUI and `idrt`: agent files
/// here, sign-in and identity in [targetStoreFile].
/// `%APPDATA%/to.idr/idr_target` (`$HOME/to.idr/idr_target` elsewhere);
/// `to.idr-dev`, `to.idr-staging` for those flavors ([IdrFlavor.current]).
Directory get defaultTargetDirectory {
  final home = Platform.environment['APPDATA'] ??
      Platform.environment['HOME'] ??
      '.';
  return Directory(
    p.join(home, 'to.idr${IdrFlavor.current.stateSuffix}', 'idr_target'),
  );
}

/// The Target's sign-in session, bound org, identity and CA keys
/// (DPAPI-encrypted on Windows, see [FileAuthStorage]).
File get targetStoreFile =>
    File(p.join(defaultTargetDirectory.path, 'secure', 'auth.json'));

/// Namespaced JSON/secret persistence over the billing SDK [BillingAuthStorage].
///
/// Writes are serialized within this process; [FileAuthStorage] also locks
/// across processes, so the GUI and `idrt` can share the default store.
class SessionStore {
  SessionStore({
    BillingAuthStorage? storage,
    this.prefix = 'idr.target.auth',
  }) : storage = storage ?? FileAuthStorage(file: targetStoreFile);

  /// Shared with [BillingAuthClient] so cookies and Target secrets live together.
  final BillingAuthStorage storage;
  final String prefix;

  static const _sessionKey = 'session';

  Future<void> _chain = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() op) {
    final done = Completer<T>();
    _chain = _chain.catchError((_) {}).then((_) async {
      try {
        done.complete(await op());
      } catch (e, st) {
        done.completeError(e, st);
      }
    });
    return done.future;
  }

  Future<void> saveSession(IdrAuthSession session) =>
      writeJson(_sessionKey, session.toJson());

  Future<IdrAuthSession?> loadSession() async {
    final j = await readJson(_sessionKey);
    final token = j?['token'];
    if (token is! String || token.isEmpty) return null;
    return IdrAuthSession.fromJson(j!);
  }

  Future<void> clearSession() => deleteSecret(_sessionKey);

  /// Generic secure string write (registration, JWT cache — never log values).
  Future<void> writeSecret(String name, String value) =>
      _serialized(() => storage.setItem('$prefix.sec.$name', value));

  Future<String?> readSecret(String name) =>
      _serialized(() => storage.getItem('$prefix.sec.$name'));

  Future<void> deleteSecret(String name) =>
      _serialized(() => storage.removeItem('$prefix.sec.$name'));

  Future<void> writeJson(String name, Map<String, dynamic> json) =>
      writeSecret(name, jsonEncode(json));

  Future<Map<String, dynamic>?> readJson(String name) async {
    final raw = await readSecret(name);
    if (raw == null || raw.isEmpty) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }
}
