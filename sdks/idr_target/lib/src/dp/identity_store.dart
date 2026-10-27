import '../auth/session_store.dart';
import 'package:idr_dp_ffi/idr_dp_ffi.dart';

import 'agent_identity_file.dart';

/// Machine DeviceIdentity persisted in secure storage (`dp.identity`).
class MachineIdentityStore {
  MachineIdentityStore(this.store);

  final SessionStore store;
  static const key = 'dp.identity';

  Future<void> saveMachineIdentity({
    required String privatePem,
    required String publicB64url,
    required Map<String, dynamic> publicJwk,
    required Map<String, dynamic> credential,
    String? fqhn,
    String? ski,
    String? publicPem,
  }) async {
    await store.writeJson(key, {
      'private_pem': privatePem,
      'public_b64url': publicB64url,
      'public_jwk': publicJwk,
      'credential': credential,
      if (publicPem != null && publicPem.isNotEmpty) 'public_pem': publicPem,
      if (fqhn != null) 'fqhn': fqhn,
      if (ski != null) 'ski': ski,
    });
  }

  Future<Map<String, dynamic>?> loadMachineIdentity() => store.readJson(key);

  /// Rust `identity.dp.json` bytes, or null if enroll is incomplete.
  Future<String?> loadAgentDeviceIdentityJson() async {
    final stored = await loadMachineIdentity();
    if (stored == null) return null;
    return agentDeviceIdentityMap(stored) == null
        ? null
        : encodeAgentDeviceIdentity(stored);
  }

  Future<String?> loadPrivatePem() async {
    final j = await loadMachineIdentity();
    return j?['private_pem'] as String?;
  }

  /// Ensure a machine key exists; create via [crypto] if missing.
  ///
  /// When [forHostLabel] is set and the stored identity is already tied to a
  /// different host, mint a new key — one machine SKI ↔ one host seat.
  Future<Ed25519KeyMaterial> ensureMachineKey(
    IdrCrypto crypto, {
    String? forHostLabel,
    bool forceNew = false,
  }) async {
    final existing = await loadMachineIdentity();
    if (!forceNew &&
        existing != null &&
        (existing['private_pem'] as String?)?.isNotEmpty == true) {
      final fqhn = (existing['fqhn'] as String?)?.toLowerCase() ?? '';
      final label = forHostLabel?.trim().toLowerCase() ?? '';
      final hostMismatch = label.isNotEmpty &&
          fqhn.isNotEmpty &&
          !fqhn.startsWith('$label--');
      if (!hostMismatch) {
        return Ed25519KeyMaterial.fromJson(existing);
      }
    }
    return rotateMachineKey(crypto);
  }

  /// Replace local machine key (new device identity / new host seat).
  Future<Ed25519KeyMaterial> rotateMachineKey(IdrCrypto crypto) async {
    final mat = crypto.generateEd25519();
    await saveMachineIdentity(
      privatePem: mat.privatePem,
      publicB64url: mat.publicB64url,
      publicJwk: mat.publicJwk,
      credential: {},
      ski: mat.ski.isNotEmpty ? mat.ski : crypto.ski(mat.publicB64url),
      publicPem: mat.publicPem,
    );
    return mat;
  }
}

/// Target-specific identity persisted alongside the machine identity.
class DpIdentityStore extends MachineIdentityStore {
  DpIdentityStore(super.store);

  static const _tlsKey = 'tls.private_pem';
  static const _targetIdentityKey = 'target.identity';
  static const _adminKey = 'dp.admin_ca';

  Future<void> saveTlsPrivatePem(String pem) => store.writeSecret(_tlsKey, pem);

  Future<String?> loadTlsPrivatePem() => store.readSecret(_tlsKey);

  Future<void> saveAdminCa({
    required String issuerSki,
    required Map<String, dynamic> privateJwk,
    String? entityId,
    String? caCertPem,
    String? commonName,
    String? package,
  }) async {
    await store.writeJson(_adminKey, {
      'issuerSki': issuerSki,
      'privateJwk': privateJwk,
      if (entityId != null) 'entityId': entityId,
      if (caCertPem != null) 'caCertPem': caCertPem,
      if (commonName != null) 'commonName': commonName,
      if (package != null) 'package': package,
    });
  }

  Future<Map<String, dynamic>?> loadAdminCa() => store.readJson(_adminKey);

  /// Forget the local root CA keys (dev reset after the server root is cleared).
  Future<void> clearAdminCa() => store.deleteSecret(_adminKey);

  static const _zoneCasKey = 'dp.zone_cas';

  /// Zone CA keys held on this (root admin) machine, by zone (`zone-a`, `fin.apac`).
  Future<Map<String, Map<String, dynamic>>> loadZoneCas() async {
    final raw = await store.readJson(_zoneCasKey);
    return {
      for (final e in (raw ?? const {}).entries)
        if (e.value is Map) e.key: Map<String, dynamic>.from(e.value as Map),
    };
  }

  Future<Map<String, dynamic>?> loadZoneCa(String zone) async =>
      (await loadZoneCas())[zone];

  /// [entry]: `ski`, `privateJwk`, `certPem`, `chainPem` (zone + root),
  /// `deviceId`, `issuedAt`.
  Future<void> saveZoneCa(String zone, Map<String, dynamic> entry) async {
    final all = await loadZoneCas();
    all[zone] = entry;
    await store.writeJson(_zoneCasKey, all);
  }

  static const _zoneKeyRequestsKey = 'dp.zone_key_requests';

  /// Zone keys this machine asked the root to sign, by zone: `ski`,
  /// `privateJwk`, `pullToken`, `enrollId`. Moved to [saveZoneCa] once signed.
  Future<Map<String, Map<String, dynamic>>> loadZoneKeyRequests() async {
    final raw = await store.readJson(_zoneKeyRequestsKey);
    return {
      for (final e in (raw ?? const {}).entries)
        if (e.value is Map) e.key: Map<String, dynamic>.from(e.value as Map),
    };
  }

  Future<void> saveZoneKeyRequest(
    String zone,
    Map<String, dynamic>? entry,
  ) async {
    final all = await loadZoneKeyRequests();
    if (entry == null) {
      all.remove(zone);
    } else {
      all[zone] = entry;
    }
    await store.writeJson(_zoneKeyRequestsKey, all);
  }

  Future<void> deleteZoneCa(String zone) async {
    final all = await loadZoneCas();
    if (all.remove(zone) != null) await store.writeJson(_zoneCasKey, all);
  }

  Future<Ed25519KeyMaterial> ensureTargetIdentity(IdrCrypto crypto) async {
    final raw = await store.readJson(_targetIdentityKey);
    if (raw != null && (raw['private_pem'] as String?)?.isNotEmpty == true) {
      return Ed25519KeyMaterial.fromJson(raw);
    }
    final mat = crypto.generateEd25519();
    await store.writeJson(_targetIdentityKey, mat.toJson());
    return mat;
  }
}
