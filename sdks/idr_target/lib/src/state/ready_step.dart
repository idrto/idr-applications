import '../auth/auth.dart';

import '../auth/user_state.dart';
import '../plan/business_plan.dart';
import '../registration/registration.dart';

/// Product readiness gate (sign-in → plan → role → billing → setup → ready).
///
/// Splash / onboarding remain app-local. Ready ≠ agent running.
sealed class TargetReadyStep {
  const TargetReadyStep();

  /// Derives readiness from session + [TargetUserState] + registration.
  ///
  /// [isAdminPath] defaults to `userState.accountPath == 'rootAdmin'`.
  /// [csrAwaiting] is true while waiting for admin enroll approval (also
  /// inferred from [IdrTargetRegistration.enrollPullToken] when set).
  static TargetReadyStep resolve({
    IdrAuthSession? session,
    required TargetUserState userState,
    IdrTargetRegistration? registration,
    bool? isAdminPath,
    bool csrAwaiting = false,
  }) {
    if (session == null) return const SignInRequired();

    // planConfirmed is app-only; SDK treats a set planCode as confirmed.
    if (userState.planCode == null) return const PlanRequired();

    if (userState.accountPath == null) return const RoleRequired();

    if (!userState.hasActivePlan) return const BillingRequired();

    final admin = isAdminPath ?? userState.accountPath == 'rootAdmin';
    final plan = IdrBusinessPlan.fromPlanCode(userState.planCode);

    // Enterprise admin: CA role + entity before home (no host FQHN required).
    if (plan == IdrBusinessPlan.enterprise && admin) {
      if (userState.enterpriseCaRole == null ||
          !userState.enterpriseEntityConfirmed) {
        return const EnterpriseSetupRequired();
      }
      return const Ready();
    }

    // Personal admin: home without host registration.
    if (plan == IdrBusinessPlan.personal && admin) {
      return const Ready();
    }

    // Enterprise join Target: confirm entity before host registration.
    if (plan == IdrBusinessPlan.enterprise &&
        !userState.enterpriseEntityConfirmed) {
      return const EnterpriseSetupRequired();
    }

    final fqhn = registration?.verifiedFqhn.trim() ?? '';
    final regComplete = registration != null && fqhn.isNotEmpty;
    final pull = registration?.enrollPullToken?.trim() ?? '';
    final awaiting = csrAwaiting || pull.isNotEmpty;

    // Waiting for enroll approval is still Ready for the gate; attention
    // surfaces the pending enroll state.
    if (regComplete || awaiting) return const Ready();

    return const RegistrationRequired();
  }
}

final class SignInRequired extends TargetReadyStep {
  const SignInRequired();
}

final class PlanRequired extends TargetReadyStep {
  const PlanRequired();
}

final class RoleRequired extends TargetReadyStep {
  const RoleRequired();
}

final class BillingRequired extends TargetReadyStep {
  const BillingRequired();
}

final class RegistrationRequired extends TargetReadyStep {
  const RegistrationRequired();
}

/// Enterprise CA role and/or entity profile still needed.
final class EnterpriseSetupRequired extends TargetReadyStep {
  const EnterpriseSetupRequired();
}

final class Ready extends TargetReadyStep {
  const Ready();
}
