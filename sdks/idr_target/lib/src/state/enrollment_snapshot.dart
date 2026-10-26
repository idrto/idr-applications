import '../registration/enrollment_models.dart';

/// Enrollment facet of [TargetState] (awaiting admin + pending CSR list).
class EnrollmentSnapshot {
  const EnrollmentSnapshot({
    this.awaitingAdmin = false,
    this.pullToken,
    this.pending = const [],
  });

  final bool awaitingAdmin;
  final String? pullToken;

  /// Empty by default on facade snapshot until EnrollmentManager fills it.
  final List<EnrollmentRequest> pending;
}
