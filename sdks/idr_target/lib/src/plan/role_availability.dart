import 'business_plan.dart';

/// Which Admin / Target path cards are available after plan selection.
class RoleAvailability {
  const RoleAvailability({
    required this.adminPathEnabled,
    required this.targetPathEnabled,
    this.personalAdminExists = false,
  });

  final bool adminPathEnabled;
  final bool targetPathEnabled;
  final bool personalAdminExists;

  /// Conservative defaults when the control plane probe fails.
  factory RoleAvailability.fallback(IdrBusinessPlan plan) => RoleAvailability(
        adminPathEnabled: plan != IdrBusinessPlan.serviceProvider,
        targetPathEnabled: plan != IdrBusinessPlan.personal,
      );

  /// [personalAdminExists] is DP Entity CA kickstart, not a Billing email row.
  factory RoleAvailability.forPlan({
    required IdrBusinessPlan plan,
    required bool personalAdminExists,
  }) {
    switch (plan) {
      case IdrBusinessPlan.personal:
        if (!personalAdminExists) {
          return const RoleAvailability(
            adminPathEnabled: true,
            targetPathEnabled: false,
          );
        }
        return const RoleAvailability(
          adminPathEnabled: false,
          targetPathEnabled: true,
          personalAdminExists: true,
        );
      case IdrBusinessPlan.enterprise:
        return const RoleAvailability(
          adminPathEnabled: true,
          targetPathEnabled: true,
        );
      case IdrBusinessPlan.serviceProvider:
        return const RoleAvailability(
          adminPathEnabled: false,
          targetPathEnabled: true,
        );
    }
  }
}
