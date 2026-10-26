/// Managed Target device under root or a zone (FQHN only after configure).
class EnterpriseTargetDevice {
  EnterpriseTargetDevice({
    required this.id,
    required this.label,
    this.zonePath = const [],
    this.hostLabel,
    this.verifiedFqhn,
  });

  final String id;
  final String label;
  final List<String> zonePath;
  String? hostLabel;
  String? verifiedFqhn;

  bool get hasFqhn =>
      (hostLabel?.isNotEmpty ?? false) && (verifiedFqhn?.isNotEmpty ?? false);

  String get zoneLabel => zonePath.isEmpty ? 'Root' : zonePath.join('.');

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'zonePath': zonePath,
        if (hostLabel != null) 'hostLabel': hostLabel,
        if (verifiedFqhn != null) 'verifiedFqhn': verifiedFqhn,
      };

  factory EnterpriseTargetDevice.fromJson(Map<String, dynamic> j) =>
      EnterpriseTargetDevice(
        id: j['id'] as String? ?? '',
        label: j['label'] as String? ?? '',
        zonePath: (j['zonePath'] as List?)?.cast<String>() ?? const [],
        hostLabel: j['hostLabel'] as String?,
        verifiedFqhn: j['verifiedFqhn'] as String?,
      );
}
