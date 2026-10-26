/// Persisted host/entity registration. [verifiedFqhn] is `host--entity.idr.to`.
class IdrTargetRegistration {
  const IdrTargetRegistration({
    required this.entityId,
    required this.hostLabel,
    required this.verifiedFqhn,
    this.machineSki,
    this.payingPartyId,
    this.seatId,
    this.enrollPullToken,
  });

  final String entityId;
  final String hostLabel;

  /// Locator from control plane — `host--entity.idr.to`.
  final String verifiedFqhn;
  final String? machineSki;
  final String? payingPartyId;
  final String? seatId;
  /// DP enroll pull token while waiting for admin approval.
  final String? enrollPullToken;

  Map<String, dynamic> toJson() => {
        'entityId': entityId,
        'hostLabel': hostLabel,
        'verifiedFqhn': verifiedFqhn,
        'machineSki': machineSki,
        'payingPartyId': payingPartyId,
        'seatId': seatId,
        'enrollPullToken': enrollPullToken,
      };

  factory IdrTargetRegistration.fromJson(Map<String, dynamic> j) =>
      IdrTargetRegistration(
        entityId: j['entityId'] as String,
        hostLabel: j['hostLabel'] as String,
        verifiedFqhn: j['verifiedFqhn'] as String,
        machineSki: j['machineSki'] as String?,
        payingPartyId: j['payingPartyId'] as String?,
        seatId: j['seatId'] as String?,
        enrollPullToken: j['enrollPullToken'] as String?,
      );
}
