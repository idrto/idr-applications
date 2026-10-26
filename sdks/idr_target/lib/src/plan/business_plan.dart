/// Commercial package the user picks before registering a host.
///
/// Maps to catalog packages: Personal / Enterprise / Service Provider.
enum IdrBusinessPlan {
  personal,
  enterprise,
  serviceProvider;

  static IdrBusinessPlan? fromPlanCode(String? code) => switch (code) {
        'idr_personal_bundle' => IdrBusinessPlan.personal,
        'idr_enterprise_bundle' => IdrBusinessPlan.enterprise,
        'idr_sp_target' => IdrBusinessPlan.serviceProvider,
        _ => null,
      };

  String get planCode => switch (this) {
        IdrBusinessPlan.personal => 'idr_personal_bundle',
        IdrBusinessPlan.enterprise => 'idr_enterprise_bundle',
        IdrBusinessPlan.serviceProvider => 'idr_sp_target',
      };
}

/// Copy for plan selection UI — what each package does.
extension IdrBusinessPlanInfo on IdrBusinessPlan {
  String get title => switch (this) {
        IdrBusinessPlan.personal => 'Personal',
        IdrBusinessPlan.enterprise => 'Enterprise',
        IdrBusinessPlan.serviceProvider => 'Service Provider',
      };

  String get priceHint => switch (this) {
        IdrBusinessPlan.personal => 'From US\$10 / year',
        IdrBusinessPlan.enterprise => 'From US\$50 / year',
        IdrBusinessPlan.serviceProvider => 'From US\$50 / year / Target',
      };

  /// Catalog list price shown on checkout (UI preview).
  String get checkoutPrice => switch (this) {
        IdrBusinessPlan.personal => 'US\$10',
        IdrBusinessPlan.enterprise => 'US\$50',
        IdrBusinessPlan.serviceProvider => 'US\$50',
      };

  String get checkoutCadence => switch (this) {
        IdrBusinessPlan.personal => 'per year',
        IdrBusinessPlan.enterprise => 'per year',
        IdrBusinessPlan.serviceProvider => 'per year / Target',
      };

  String get summary => switch (this) {
        IdrBusinessPlan.personal =>
          'For individuals. Your email is your account home; each machine gets '
              'a short name like laptop under *.idr.to.',
        IdrBusinessPlan.enterprise =>
          'For companies. Your brand is the org id, with org-wide and '
              'department admins (Finance, APAC, and so on).',
        IdrBusinessPlan.serviceProvider =>
          'For operators who host Targets for customers. Pay per machine, '
              'optional customer domain, and guest access when enabled.',
      };

  /// Short bullets: what this plan does for this Target.
  List<String> get capabilities => switch (this) {
        IdrBusinessPlan.personal => const [
            'Tied to your email account',
            'Up to 5 machines',
            'Simple names (laptop, desktop, …)',
            'Secure *.idr.to address included',
            'Only your own apps can connect',
          ],
        IdrBusinessPlan.enterprise => const [
            'Brand name is your company id',
            'Names like laptop--brand.idr.to',
            'Org admin can approve all machines',
            'Department admins for teams (fin, eng, …)',
            'Team access stays inside your org',
          ],
        IdrBusinessPlan.serviceProvider => const [
            'One seat per machine you operate',
            'Optional customer domain (cam.example.com)',
            'HTTPS on the device when using a custom domain',
            'Guest / anonymous access when the package allows it',
            'Fits cameras, APIs, and hosted apps',
          ],
      };
}
