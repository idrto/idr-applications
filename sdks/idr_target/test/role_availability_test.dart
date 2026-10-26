import 'package:idr_target/src/plan/business_plan.dart';
import 'package:idr_target/src/plan/role_availability.dart';
import 'package:test/test.dart';

void main() {
  test('personal without Entity CA keeps Admin and disables Target', () {
    final roles = RoleAvailability.forPlan(
      plan: IdrBusinessPlan.personal,
      personalAdminExists: false,
    );
    expect(roles.adminPathEnabled, isTrue);
    expect(roles.targetPathEnabled, isFalse);
    expect(roles.personalAdminExists, isFalse);
  });

  test('personal after kickstart offers Target only', () {
    final roles = RoleAvailability.forPlan(
      plan: IdrBusinessPlan.personal,
      personalAdminExists: true,
    );
    expect(roles.adminPathEnabled, isFalse);
    expect(roles.targetPathEnabled, isTrue);
    expect(roles.personalAdminExists, isTrue);
  });

  test('probe failure fallback still offers Admin on personal', () {
    final roles = RoleAvailability.fallback(IdrBusinessPlan.personal);
    expect(roles.adminPathEnabled, isTrue);
    expect(roles.targetPathEnabled, isFalse);
    expect(roles.personalAdminExists, isFalse);
  });
}
