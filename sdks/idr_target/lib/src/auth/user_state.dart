/// Persisted first-run / account UI state (survives app restarts).
///
/// Stored via [TargetUserStatePersistence] on SessionStore — onboarding and
/// role/plan choices are not shown again once completed.
class TargetUserState {
  const TargetUserState({
    this.onboardingDone = false,
    this.accountPath,
    this.planCode,
    this.hasActivePlan = false,
    this.enterpriseCaRole,
    this.enterpriseEntityConfirmed = false,
    this.entityRole,
    this.adminAlsoTarget = false,
  });

  final bool onboardingDone;

  /// `rootAdmin` | `joinTarget`
  final String? accountPath;

  /// `idr_personal_bundle` | `idr_enterprise_bundle` | `idr_sp_target`
  final String? planCode;
  final bool hasActivePlan;

  /// `root` | `intermediate`
  final String? enterpriseCaRole;
  final bool enterpriseEntityConfirmed;

  /// `adminCa` | `enrollTarget`
  final String? entityRole;

  /// Admin device also registered as Target (survives restart).
  final bool adminAlsoTarget;

  bool get hasRestorableAccount =>
      onboardingDone && accountPath != null && hasActivePlan && planCode != null;

  TargetUserState copyWith({
    bool? onboardingDone,
    String? accountPath,
    String? planCode,
    bool? hasActivePlan,
    String? enterpriseCaRole,
    bool? enterpriseEntityConfirmed,
    String? entityRole,
    bool? adminAlsoTarget,
    bool clearAccountPath = false,
    bool clearPlan = false,
    bool clearCaRole = false,
    bool clearEntityRole = false,
  }) {
    return TargetUserState(
      onboardingDone: onboardingDone ?? this.onboardingDone,
      accountPath: clearAccountPath ? null : (accountPath ?? this.accountPath),
      planCode: clearPlan ? null : (planCode ?? this.planCode),
      hasActivePlan: clearPlan ? false : (hasActivePlan ?? this.hasActivePlan),
      enterpriseCaRole:
          clearCaRole ? null : (enterpriseCaRole ?? this.enterpriseCaRole),
      enterpriseEntityConfirmed:
          enterpriseEntityConfirmed ?? this.enterpriseEntityConfirmed,
      entityRole: clearEntityRole ? null : (entityRole ?? this.entityRole),
      adminAlsoTarget: adminAlsoTarget ?? this.adminAlsoTarget,
    );
  }

  Map<String, dynamic> toJson() => {
        'onboardingDone': onboardingDone,
        'accountPath': accountPath,
        'planCode': planCode,
        'hasActivePlan': hasActivePlan,
        'enterpriseCaRole': enterpriseCaRole,
        'enterpriseEntityConfirmed': enterpriseEntityConfirmed,
        'entityRole': entityRole,
        'adminAlsoTarget': adminAlsoTarget,
      };

  factory TargetUserState.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const TargetUserState();
    return TargetUserState(
      onboardingDone: j['onboardingDone'] == true,
      accountPath: j['accountPath'] as String?,
      planCode: j['planCode'] as String?,
      hasActivePlan: j['hasActivePlan'] == true,
      enterpriseCaRole: j['enterpriseCaRole'] as String?,
      enterpriseEntityConfirmed: j['enterpriseEntityConfirmed'] == true,
      entityRole: j['entityRole'] as String?,
      adminAlsoTarget: j['adminAlsoTarget'] == true,
    );
  }
}
