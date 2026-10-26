import '../auth/session_store.dart';
import 'enterprise_fqhn.dart';
import 'enterprise_org_models.dart';

/// Persists the local enterprise org graph under SessionStore key `enterprise_org`.
class EnterpriseOrgStore {
  EnterpriseOrgStore(this._store);

  static const storeKey = 'enterprise_org';

  final SessionStore _store;

  Future<EnterpriseOrgSnapshot> load() async {
    final j = await _store.readJson(storeKey);
    if (j == null) return EnterpriseOrgSnapshot.empty();
    return EnterpriseOrgSnapshot.fromJson(j);
  }

  Future<void> save(EnterpriseOrgSnapshot snapshot) async {
    await _store.writeJson(storeKey, snapshot.toJson());
  }

  Future<void> clear() async {
    await _store.deleteSecret(storeKey);
  }
}

/// Serializable local org graph (zones / admins / devices).
class EnterpriseOrgSnapshot {
  const EnterpriseOrgSnapshot({
    this.zones = const [],
    this.zoneAdmins = const [],
    this.devices = const [],
    this.deviceSeq = 0,
    this.brandName,
  });

  factory EnterpriseOrgSnapshot.empty() => const EnterpriseOrgSnapshot();

  final List<EnterpriseZone> zones;
  final List<EnterpriseZoneAdmin> zoneAdmins;
  final List<EnterpriseTargetDevice> devices;
  final int deviceSeq;
  final String? brandName;

  Map<String, dynamic> toJson() => {
        'zones': zones.map((z) => z.toJson()).toList(),
        'zoneAdmins': zoneAdmins.map((a) => a.toJson()).toList(),
        'devices': devices.map((d) => d.toJson()).toList(),
        'deviceSeq': deviceSeq,
        if (brandName != null) 'brandName': brandName,
      };

  factory EnterpriseOrgSnapshot.fromJson(Map<String, dynamic> j) {
    List<Map<String, dynamic>> maps(dynamic raw) => raw is List
        ? raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList()
        : const [];

    return EnterpriseOrgSnapshot(
      zones: maps(j['zones']).map(EnterpriseZone.fromJson).toList(),
      zoneAdmins:
          maps(j['zoneAdmins']).map(EnterpriseZoneAdmin.fromJson).toList(),
      devices: maps(j['devices']).map(EnterpriseTargetDevice.fromJson).toList(),
      deviceSeq: j['deviceSeq'] as int? ?? 0,
      brandName: j['brandName'] as String?,
    );
  }
}
