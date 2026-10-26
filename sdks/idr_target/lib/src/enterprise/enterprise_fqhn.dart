/// Enterprise FQHN helpers.
///
/// Pattern: `{host}[.{zone...}]--{brand}.idr.to`
///
/// Examples (brand LG):
/// - `laptop--lg.idr.to`           — host at org root
/// - `laptop.fin--lg.idr.to`       — host under finance dept
/// - `db1.fin.apac--lg.idr.to`     — nested sub-dept
class EnterpriseFqhn {
  EnterpriseFqhn._();

  /// DNS-safe entity id from brand (brand acts as user / org id).
  static String brandDnsId(String brandName) {
    final lower = brandName.trim().toLowerCase();
    final slug = lower
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'org' : slug;
  }

  /// Left-hand name before `--{brand}`: `laptop` or `laptop.fin.apac`.
  static String leftHand({
    required String hostLabel,
    List<String> zonePath = const [],
  }) {
    final host = hostLabel.trim().toLowerCase();
    final zones = zonePath
        .map((z) => z.trim().toLowerCase())
        .where((z) => z.isNotEmpty)
        .toList();
    if (zones.isEmpty) return host;
    return '$host.${zones.join('.')}';
  }

  /// Full verified FQHN.
  static String build({
    required String hostLabel,
    required String brandName,
    List<String> zonePath = const [],
  }) {
    final left = leftHand(hostLabel: hostLabel, zonePath: zonePath);
    final brand = brandDnsId(brandName);
    return '$left--$brand.idr.to';
  }

  /// Parse zone labels from dotted input (`fin` or `fin.apac`).
  static List<String> parseZonePath(String raw) {
    return raw
        .trim()
        .toLowerCase()
        .split('.')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static bool isValidZoneLabel(String label) {
    return RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$').hasMatch(label);
  }

  static bool isValidHostLabel(String label) {
    return RegExp(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$').hasMatch(label) &&
        !label.contains('.');
  }
}

/// Where this admin sits in the enterprise hierarchy.
enum EnterpriseAdminScope {
  /// Org-wide Entity / Root CA.
  root,

  /// Intermediate CA under root — can sign leaf or intermediate CSRs.
  intermediate,

  /// Department / sub-dept admin — issues certs under their zone path only.
  zone,
}

extension EnterpriseAdminScopeInfo on EnterpriseAdminScope {
  String get title => switch (this) {
        EnterpriseAdminScope.root => 'Root CA',
        EnterpriseAdminScope.intermediate => 'Intermediate CA',
        EnterpriseAdminScope.zone => 'Zone admin',
      };

  String get summary => switch (this) {
        EnterpriseAdminScope.root =>
          'First enterprise admin. Issues the org CA, creates zones, and can '
              'sign leaf or intermediate certificates.',
        EnterpriseAdminScope.intermediate =>
          'CA under root. Can sign leaf device certificates or further '
              'intermediate CAs for your scope.',
        EnterpriseAdminScope.zone =>
          'Approve machines only in one department (for example Finance).',
      };
}

/// CA level offered after Admin → Enterprise (from server / stub).
enum EnterpriseCaRole {
  root,
  intermediate,
}

extension EnterpriseCaRoleInfo on EnterpriseCaRole {
  String get title => switch (this) {
        EnterpriseCaRole.root => 'Root Admin (Root CA)',
        EnterpriseCaRole.intermediate => 'Intermediate CA Admin',
      };

  String get summary => switch (this) {
        EnterpriseCaRole.root =>
          'You are the first admin for this enterprise. You hold the root CA '
              'and can sign leaf or intermediate certificates.',
        EnterpriseCaRole.intermediate =>
          'A root admin already exists. You become an intermediate CA and can '
              'sign leaf or intermediate certificates under that root.',
      };
}

/// A delegated department / zone under the enterprise brand.
class EnterpriseZone {
  EnterpriseZone({
    required this.path,
    required this.displayName,
    this.parentPath = const [],
    this.authoritySki,
    this.issuedAt,
  });

  /// Zone labels from root, e.g. `['fin']` or `['fin', 'apac']`.
  final List<String> path;
  final String displayName;
  final List<String> parentPath;

  /// SKI of this zone's CA (zone_authority) once issued under the root.
  final String? authoritySki;
  final DateTime? issuedAt;

  bool get hasCertificate => authoritySki != null;

  String get pathKey => path.join('.');

  bool containsHostZone(List<String> hostZone) {
    if (path.isEmpty) return true; // root covers all
    if (hostZone.length < path.length) return false;
    for (var i = 0; i < path.length; i++) {
      if (hostZone[i] != path[i]) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
        'path': path,
        'displayName': displayName,
        'parentPath': parentPath,
        if (authoritySki != null) 'authoritySki': authoritySki,
        if (issuedAt != null) 'issuedAt': issuedAt!.toIso8601String(),
      };

  factory EnterpriseZone.fromJson(Map<String, dynamic> j) => EnterpriseZone(
        path: (j['path'] as List?)?.cast<String>() ?? const [],
        displayName: j['displayName'] as String? ?? '',
        parentPath: (j['parentPath'] as List?)?.cast<String>() ?? const [],
        authoritySki: j['authoritySki'] as String?,
        issuedAt: DateTime.tryParse(j['issuedAt'] as String? ?? ''),
      );
}

/// Zone admin invite — local org graph until CP sync exists.
class EnterpriseZoneAdmin {
  const EnterpriseZoneAdmin({
    required this.email,
    required this.zonePath,
  });

  final String email;
  final List<String> zonePath;

  String get zoneLabel =>
      zonePath.isEmpty ? 'organization' : zonePath.join('.');

  Map<String, dynamic> toJson() => {
        'email': email,
        'zonePath': zonePath,
      };

  factory EnterpriseZoneAdmin.fromJson(Map<String, dynamic> j) =>
      EnterpriseZoneAdmin(
        email: j['email'] as String? ?? '',
        zonePath: (j['zonePath'] as List?)?.cast<String>() ?? const [],
      );
}
