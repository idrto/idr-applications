import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_target/idr_target.dart';

import 'target.dart';

/// Enterprise zone admins and members: the zone this machine works in,
/// picked at setup from the zones billing says the user has a role in.
typedef ZoneContext = ({String zone, String role, String entityId});

const _zoneKey = 'idrt.zone';

Future<ZoneContext?> loadZoneContext() async {
  final j = await cliStore.readJson(_zoneKey);
  if (j == null) return null;
  return (
    zone: j['zone'] as String,
    role: j['role'] as String? ?? 'member',
    entityId: j['entityId'] as String,
  );
}

Future<void> saveZoneContext(ZoneContext z) => cliStore.writeJson(_zoneKey, {
  'zone': z.zone,
  'role': z.role,
  'entityId': z.entityId,
});

Future<void> clearZoneContext() => cliStore.deleteSecret(_zoneKey);

/// One of the signed-in user's zones, as billing reports it.
typedef MyZone = ({
  String zone,
  String? role,
  bool exists,
  bool membersApprove,
  bool adminsCreateSubzones,
  String? keyStatus,
});

/// The user's zones and the org's entity (`owner`: they own the org).
Future<({String? entityId, bool owner, List<MyZone> zones})> myZones(
  IdrTarget target,
) async {
  final j = await target.myZones();
  return (
    entityId: j['entityId'] as String?,
    owner: j['owner'] == true,
    zones: [
      for (final z in (j['zones'] as List? ?? const []).cast<Map>())
        (
          zone: z['zone'] as String,
          role: z['role'] as String?,
          exists: z['exists'] != false,
          membersApprove: z['membersApprove'] == true,
          adminsCreateSubzones: z['adminsCreateSubzones'] == true,
          keyStatus: (z['key'] as Map?)?['status'] as String?,
        ),
    ],
  );
}

/// Zone -> role, or empty when billing can't say (offline, not registered).
Future<Map<String, String>> myZoneRoles(IdrTarget target) async {
  try {
    return {
      for (final z in (await myZones(target)).zones)
        if (z.role != null) z.zone: z.role!,
    };
  } catch (_) {
    return const {};
  }
}

/// Picks up zone keys the root signed since they were requested here.
/// Returns the zones still waiting.
Future<List<String>> pullZoneKeys(IdrTarget target) async {
  final waiting = <String>[];
  for (final zone in await target.zoneKeyRequests()) {
    final status = await target.pullZoneKey(zone);
    if (status == 'approved') {
      ui.success('The root admin signed this machine\'s key for zone $zone.');
    } else if (status == 'rejected') {
      ui.warn('The root admin rejected this machine\'s key for zone $zone.');
    } else {
      waiting.add(zone);
    }
  }
  return waiting;
}

/// Zone admin: hold [zone]'s key here (asking the root to sign it once).
/// True when the key is usable now.
Future<bool> ensureZoneKey(
  IdrTarget target,
  String zone,
  String entityId,
) async {
  final status = await target.requestZoneKey(zone: zone, entityId: entityId);
  if (status == 'approved') {
    ui.info(
      'This machine holds the key for zone $zone: it approves $zone\'s '
      'machines and Sources (`idrt` > Pending approvals).',
    );
    return true;
  }
  ui.info('Asked the root admin to sign this machine\'s key for zone $zone.');
  ui.hint(
    'They approve it in `idrt` > Pending approvals. Open `idrt` here '
    'afterwards; the key is picked up automatically.',
  );
  return false;
}
