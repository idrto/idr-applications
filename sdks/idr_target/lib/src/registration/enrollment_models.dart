/// How an admin signs a CSR (leaf device vs intermediate CA).
enum CertSignKind {
  leaf,
  intermediate,
}

/// A zone CA issued under the enterprise root and registered on billing.
/// Its private key stays on the root admin machine.
typedef ZoneAuthority = ({
  String zone,
  String ski,
  String certPem,
  String? deviceId,
  DateTime issuedAt,
});

extension CertSignKindInfo on CertSignKind {
  String get title => switch (this) {
        CertSignKind.leaf => 'Sign leaf',
        CertSignKind.intermediate => 'Sign intermediate',
      };

  String get shortLabel => switch (this) {
        CertSignKind.leaf => 'leaf',
        CertSignKind.intermediate => 'intermediate',
      };
}

/// How this device joins a Personal or Enterprise entity.
enum EntityDeviceRole {
  /// This machine is (or will be) an admin / CA authority.
  adminCa,

  /// This machine enrolls as a Target: local key + CSR → admin signs leaf.
  enrollTarget,
}

extension EntityDeviceRoleInfo on EntityDeviceRole {
  String get title => switch (this) {
        EntityDeviceRole.adminCa => 'Admin',
        EntityDeviceRole.enrollTarget => 'This machine',
      };

  String get summary => switch (this) {
        EntityDeviceRole.adminCa =>
          'You manage the enterprise: zones, admins, devices, and certificates. '
              'Root Admin does not need a host FQHN.',
        EntityDeviceRole.enrollTarget =>
          'This device joins under an admin as a Target. Hostname / FQHN is '
              'configured only after the device is registered.',
      };
}

/// Enterprise identity — brand/company name and/or verified email.
class EnterpriseEntityProfile {
  const EnterpriseEntityProfile({
    this.adminEmail,
    this.brandName,
  });

  /// Verified admin / org email (optional if [brandName] is set).
  final String? adminEmail;

  /// Brand / company name (optional if [adminEmail] is set).
  final String? brandName;

  String get identityLabel {
    final brand = brandName?.trim() ?? '';
    if (brand.isNotEmpty) return brand;
    return adminEmail?.trim() ?? '';
  }

  /// DNS-safe org id from brand, else email local-part.
  String get brandDnsId {
    final brand = brandName?.trim() ?? '';
    final source =
        brand.isNotEmpty ? brand : (adminEmail?.split('@').first ?? 'org');
    final lower = source.trim().toLowerCase();
    final slug = lower
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'org' : slug;
  }
}

/// Optional SP custom-domain path (CNAME → native FQHN + Let's Encrypt on Target).
class SpCustomDomainChoice {
  const SpCustomDomainChoice({
    required this.enabled,
    this.domain,
  });

  final bool enabled;
  final String? domain;

  static const disabled = SpCustomDomainChoice(enabled: false);
}

enum EnrollmentRequestStatus { pending, signed, rejected }

/// CSR enroll request from a sub-device — admin signs or rejects.
class EnrollmentRequest {
  EnrollmentRequest({
    required this.id,
    required this.hostLabel,
    required this.requesterEmail,
    required this.csrPem,
    required this.submittedAt,
    this.zonePath = const [],
    this.verifiedFqhn,
    this.entityId,
    this.subjectSki,
    this.publicJwk,
    this.status = EnrollmentRequestStatus.pending,
    this.kind = 'machine_target',
    this.target,
  });

  final String id;
  final String hostLabel;
  final String requesterEmail;
  final String csrPem;
  final DateTime submittedAt;

  /// Zone under brand, e.g. `['fin']` → host.fin--brand.idr.to
  final List<String> zonePath;
  final String? verifiedFqhn;
  final String? entityId;
  final String? subjectSki;
  final Map<String, dynamic>? publicJwk;
  EnrollmentRequestStatus status;

  /// `machine_target`, `machine_source`, or `zone_authority` (a zone key
  /// request: a zone admin's key, or a new sub-zone).
  final String kind;

  /// Source: the Target it enrolls for.
  final String? target;

  bool get isZoneKey => kind == 'zone_authority';

  String? get zone => zonePath.isEmpty ? null : zonePath.join('.');
  CertSignKind? signedAs;

  bool get isPending => status == EnrollmentRequestStatus.pending;

  String get zoneLabel =>
      zonePath.isEmpty ? 'organization' : zonePath.join('.');

  /// Map a control-plane enroll-list row into a typed request.
  factory EnrollmentRequest.fromApi(Map<String, dynamic> row) {
    final host = (row['host'] as String?) ?? '';
    final hostLabel = host.contains('--') ? host.split('--').first : host;
    final publicJwk = row['publicJwk'];
    return EnrollmentRequest(
      id: (row['enrollId'] as String?) ?? (row['id'] as String?) ?? '',
      hostLabel: hostLabel.isNotEmpty ? hostLabel : 'device',
      requesterEmail: (row['requestedBy'] as String?) ?? '',
      csrPem: (row['csrPem'] as String?) ?? '',
      submittedAt: row['createdAt'] != null
          ? DateTime.tryParse(row['createdAt'].toString()) ?? DateTime.now()
          : DateTime.now(),
      zonePath: row['zone'] != null && (row['zone'] as String).isNotEmpty
          ? [(row['zone'] as String)]
          : const [],
      verifiedFqhn: host.isNotEmpty ? host : null,
      entityId: row['entityId'] as String?,
      subjectSki: (row['ski'] as String?) ?? (row['subjectSki'] as String?),
      publicJwk:
          publicJwk is Map ? Map<String, dynamic>.from(publicJwk) : null,
      kind: (row['kind'] as String?) ?? 'machine_target',
      target: row['target'] as String?,
    );
  }
}
