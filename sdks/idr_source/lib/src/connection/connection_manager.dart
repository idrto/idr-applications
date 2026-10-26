import 'package:idr_client/idr_client.dart';

import '../config.dart';
import '../errors.dart';
import '../library_path.dart';

/// Live WebRTC connection to a Target. Never persisted across processes.
class ConnectionManager {
  ConnectionManager(this.config);

  final IdrSourceConfig config;
  IdrRuntime? _runtime;
  IdrSession? _session;
  String? _fqhn;

  IdrSession? get session => _session;
  String? get fqhn => _fqhn;
  bool get isConnected => _session != null;

  /// Last resolved library path (for doctor / diagnostics).
  String? lastResolvedLibraryPath;

  Future<IdrSession> connect({
    required String authToken,
    required String sourceId,
    required String fqhn,
    String? dpIdentityJson,
  }) async {
    final target = canonicalPresenceFqhn(fqhn);
    if (target.isEmpty) {
      throw const IdrSourceException(
        code: 'CONNECT_FAILED',
        message: 'Target FQHN is required.',
      );
    }

    await disconnect();
    final runtime = await _create(
      authToken: authToken,
      sourceId: sourceId,
      dpIdentityJson: dpIdentityJson,
    );
    try {
      final session = await runtime.connect(target);
      _session = session;
      _fqhn = target;
      return session;
    } catch (e) {
      await _disposeRuntime();
      _session = null;
      _fqhn = null;
      throw IdrSourceException(
        code: 'CONNECT_FAILED',
        message: 'Connect to $target failed: $e',
        cause: e,
      );
    }
  }

  Future<List<NamedServiceInfo>> listNamedServiceCatalog() async {
    final session = _session;
    if (session == null) {
      throw const IdrSourceException(
        code: 'NOT_CONNECTED',
        message: 'Not connected to a Target.',
      );
    }
    return session.listNamedServiceCatalog();
  }

  Future<void> disconnect() async {
    final session = _session;
    _session = null;
    // Keep _fqhn so callers know last peer; facade may clear separately.
    if (session != null) {
      try {
        await session.close();
      } catch (_) {}
    }
    await _disposeRuntime();
  }

  /// [dpIdentityJson] (approved `machine_source` identity) switches the engine
  /// to `idrAuthMtls`; without it the bearer token alone is used.
  Future<IdrRuntime> _create({
    required String authToken,
    required String sourceId,
    String? dpIdentityJson,
  }) async {
    await _disposeRuntime();
    final lib = resolveLibraryPath(config.libraryPath);
    lastResolvedLibraryPath = lib;
    if (lib != null && lib.isNotEmpty && !libraryFileExists(lib)) {
      throw IdrSourceException(
        code: 'LIBRARY_MISSING',
        message: 'Native library not found: $lib',
      );
    }

    try {
      final runtime = await IdrRuntime.create(
        libraryPath: (lib == null || lib.isEmpty) ? null : lib,
        authToken: authToken,
        authMode: dpIdentityJson == null ? idrAuthBearer : idrAuthMtls,
        useMock: false,
        discoveryUrl: config.discoveryUrl,
        insecureDev: config.insecureDev,
        sourceId: sourceId,
        sourceRegion: config.sourceRegion,
      );
      _runtime = runtime;
      if (dpIdentityJson != null) {
        await runtime.setDpIdentity(dpIdentityJson);
      }
      return runtime;
    } catch (e) {
      if (e is IdrSourceException) rethrow;
      throw IdrSourceException(
        code: 'RUNTIME_FAILED',
        message: 'Failed to create Source runtime: $e',
        cause: e,
      );
    }
  }

  Future<void> _disposeRuntime() async {
    final r = _runtime;
    _runtime = null;
    if (r != null) await r.dispose();
  }
}

/// `{host}--{entity}` → `{host}--{entity}.idr.to`. Already-suffixed and dotted DNS unchanged.
String canonicalPresenceFqhn(String fqhn) {
  var s = fqhn.trim().toLowerCase();
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  if (s.contains('--') && !s.endsWith('.idr.to')) {
    return '$s.idr.to';
  }
  return s;
}
