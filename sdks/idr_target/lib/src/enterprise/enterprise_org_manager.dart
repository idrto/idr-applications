import '../auth/session_store.dart';
import '../errors.dart';
import 'enterprise_fqhn.dart';
import 'enterprise_org_models.dart';
import 'enterprise_org_store.dart';

/// Local CRUD for enterprise zones / admins / devices.
///
/// Remote control-plane sync is not available yet ([remoteSyncAvailable]).
class EnterpriseOrgManager {
  EnterpriseOrgManager({
    required SessionStore store,
    void Function()? onChange,
  })  : _store = EnterpriseOrgStore(store),
        _onChange = onChange;

  final EnterpriseOrgStore _store;
  final void Function()? _onChange;

  final List<EnterpriseZone> _zones = [];
  final List<EnterpriseZoneAdmin> _zoneAdmins = [];
  final List<EnterpriseTargetDevice> _devices = [];
  int _deviceSeq = 0;
  String? _brandName;

  /// After creating a zone, UI may prompt for first-device ownership.
  String? pendingFirstDeviceZoneKey;

  List<EnterpriseZone> get zones => List.unmodifiable(_zones);
  List<EnterpriseZoneAdmin> get zoneAdmins => List.unmodifiable(_zoneAdmins);
  List<EnterpriseTargetDevice> get devices => List.unmodifiable(_devices);
  String? get brandName => _brandName;

  bool get remoteSyncAvailable => false;

  List<EnterpriseTargetDevice> devicesInZone(List<String> zonePath) {
    final key = zonePath.join('.');
    return _devices.where((d) => d.zonePath.join('.') == key).toList();
  }

  List<EnterpriseTargetDevice> get rootDevices => devicesInZone(const []);

  Future<void> load() async {
    final snap = await _store.load();
    _zones
      ..clear()
      ..addAll(snap.zones);
    _zoneAdmins
      ..clear()
      ..addAll(snap.zoneAdmins);
    _devices
      ..clear()
      ..addAll(snap.devices);
    _deviceSeq = snap.deviceSeq;
    _brandName = snap.brandName;
  }

  Future<void> setBrandName(String? brand) async {
    _brandName = brand;
    await _persist();
  }

  Future<void> clear() async {
    _zones.clear();
    _zoneAdmins.clear();
    _devices.clear();
    _deviceSeq = 0;
    _brandName = null;
    pendingFirstDeviceZoneKey = null;
    await _store.clear();
    _onChange?.call();
  }

  Future<void> addZone({
    required List<String> path,
    required String displayName,
  }) async {
    if (path.isEmpty) return;
    final key = path.join('.');
    if (_zones.any((z) => z.pathKey == key)) return;
    _zones.add(
      EnterpriseZone(
        path: path,
        displayName: displayName,
        parentPath: path.length > 1
            ? path.sublist(0, path.length - 1)
            : const [],
      ),
    );
    await _persist();
  }

  /// Record the issued zone CA on a zone (adds the zone if missing).
  Future<EnterpriseZone> attachAuthority({
    required List<String> path,
    required String displayName,
    required String ski,
    required DateTime issuedAt,
  }) async {
    final key = path.join('.');
    final i = _zones.indexWhere((z) => z.pathKey == key);
    final zone = EnterpriseZone(
      path: path,
      displayName: i < 0 ? displayName : _zones[i].displayName,
      parentPath:
          path.length > 1 ? path.sublist(0, path.length - 1) : const [],
      authoritySki: ski,
      issuedAt: issuedAt,
    );
    if (i < 0) {
      _zones.add(zone);
    } else {
      _zones[i] = zone;
    }
    await _persist();
    return zone;
  }

  /// Forget a zone's (revoked) certificate; the zone itself stays.
  Future<void> detachAuthority(List<String> path) async {
    final i = _zones.indexWhere((z) => z.pathKey == path.join('.'));
    if (i < 0 || _zones[i].authoritySki == null) return;
    final z = _zones[i];
    _zones[i] = EnterpriseZone(
      path: z.path,
      displayName: z.displayName,
      parentPath: z.parentPath,
    );
    await _persist();
  }

  /// Create zone + zone admin; then UI may prompt for first device ownership.
  Future<void> createZoneWithAdmin({
    required String zoneName,
    required String adminEmail,
  }) async {
    final name = zoneName.trim();
    final email = adminEmail.trim();
    if (name.isEmpty || email.isEmpty) return;
    final path = EnterpriseFqhn.parseZonePath(name);
    if (path.isEmpty) return;
    await addZone(
      path: path,
      displayName: name.contains('.') ? path.last : name,
    );
    await inviteZoneAdmin(zonePathRaw: path.join('.'), email: email);
    pendingFirstDeviceZoneKey = path.join('.');
    _onChange?.call();
  }

  void clearPendingFirstDevicePrompt() {
    pendingFirstDeviceZoneKey = null;
    _onChange?.call();
  }

  Future<void> addZoneFromInput({
    required String pathRaw,
    required String displayNameRaw,
  }) async {
    final path = EnterpriseFqhn.parseZonePath(pathRaw);
    final name = displayNameRaw.trim().isEmpty
        ? path.join(' · ')
        : displayNameRaw.trim();
    await addZone(path: path, displayName: name);
  }

  Future<void> inviteZoneAdmin({
    required String zonePathRaw,
    required String email,
  }) async {
    final path = EnterpriseFqhn.parseZonePath(zonePathRaw);
    final trimmed = email.trim();
    if (path.isEmpty || trimmed.isEmpty) return;
    if (!_zones.any((z) => z.pathKey == path.join('.'))) return;
    if (_zoneAdmins.any(
      (a) => a.email == trimmed && a.zoneLabel == path.join('.'),
    )) {
      return;
    }
    _zoneAdmins.add(EnterpriseZoneAdmin(email: trimmed, zonePath: path));
    await _persist();
  }

  /// Register a Target device (no FQHN yet).
  Future<EnterpriseTargetDevice?> addDevice({
    required String label,
    List<String> zonePath = const [],
  }) async {
    final name = label.trim();
    if (name.isEmpty) return null;
    final device = EnterpriseTargetDevice(
      id: 'dev-${++_deviceSeq}',
      label: name,
      zonePath: List.unmodifiable(zonePath),
    );
    _devices.add(device);
    await _persist();
    return device;
  }

  /// FQHN only when configuring a Target Device.
  Future<void> configureDeviceFqhn({
    required String deviceId,
    required String hostLabel,
    String? brandName,
  }) async {
    final normalized = hostLabel.trim().toLowerCase();
    if (normalized.isEmpty) return;
    final brand = brandName ?? _brandName ?? 'org';
    for (final d in _devices) {
      if (d.id != deviceId) continue;
      d.hostLabel = normalized;
      d.verifiedFqhn = EnterpriseFqhn.build(
        hostLabel: normalized,
        brandName: brand,
        zonePath: d.zonePath,
      );
      await _persist();
      return;
    }
  }

  /// Control-plane org sync is not implemented yet.
  Future<void> syncFromControlPlane() async {
    throw IdrTargetException.forCode(IdrTargetErrorCode.notImplemented);
  }

  Future<void> _persist() async {
    await _store.save(
      EnterpriseOrgSnapshot(
        zones: List.of(_zones),
        zoneAdmins: List.of(_zoneAdmins),
        devices: List.of(_devices),
        deviceSeq: _deviceSeq,
        brandName: _brandName,
      ),
    );
    _onChange?.call();
  }
}
