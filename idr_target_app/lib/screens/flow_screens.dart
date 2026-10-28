import 'package:flutter/material.dart';
import 'package:idr_target/idr_target.dart';

import '../target/target_controller.dart';
import '../ui/components/buttons/idr_button.dart';
import '../ui/components/cards/idr_card.dart';
import '../ui/components/feedback/idr_feedback.dart';
import '../ui/components/inputs/idr_fields.dart';
import '../ui/components/layout/idr_layout.dart';
import '../ui/idr_dashboard.dart';
import '../ui/theme/idr_theme.dart';
import '../widgets/common.dart';

const _steps = ['Sign in', 'Mode', 'Billing', 'Register'];

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: IdrColors.bg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IdrMark(size: 48),
            SizedBox(height: 20),
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ],
        ),
      ),
    );
  }
}

/// Offers only the sign-in methods the Auth server advertises AND the SDK can
/// run today (`IdrLoginOptions.actionableProviders`: Google).
class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key, required this.controller});

  final TargetController controller;

  @override
  Widget build(BuildContext context) {
    final options = controller.loginOptions;
    final providers = options?.actionableProviders ?? const [];
    return FlowScaffold(
      controller: controller,
      title: 'Sign in to IDR',
      subtitle: 'Publish services from this machine to approved devices.',
      steps: _steps,
      step: 0,
      maxWidth: 420,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.loginOptionsError != null) ...[
            IdrAlert(
              tone: IdrTone.error,
              title: 'Cannot reach the sign-in service',
              message: controller.loginOptionsError,
              actions: IdrButton(
                label: 'Retry',
                size: IdrButtonSize.sm,
                onPressed: () => controller.loadLoginOptions(force: true),
              ),
            ),
          ] else if (options == null)
            const Center(child: CircularProgressIndicator(strokeWidth: 2))
          else if (providers.isEmpty)
            IdrAlert(
              tone: IdrTone.warning,
              title: 'No sign-in method available',
              message:
                  'The server offers no sign-in method this app can run yet.',
              actions: IdrButton(
                label: 'Retry',
                size: IdrButtonSize.sm,
                onPressed: () => controller.loadLoginOptions(force: true),
              ),
            )
          else
            for (final p in providers) ...[
              IdrButton(
                label: 'Continue with ${_providerName(p)}',
                variant: IdrButtonVariant.primary,
                size: IdrButtonSize.lg,
                expand: true,
                loading: controller.busy,
                onPressed: controller.busy ? null : controller.signIn,
              ),
              const SizedBox(height: 8),
            ],
          if (controller.busy)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Finish signing in in your browser, then return here.',
                textAlign: TextAlign.center,
                style: IdrText.body(size: 12, color: IdrColors.zinc500),
              ),
            ),
          const SizedBox(height: 20),
          // Signing in for the first time creates the account.
          Text(
            'By continuing, you agree to the IDR Terms of Service and Privacy Policy.',
            textAlign: TextAlign.center,
            style: IdrText.body(
              size: 12,
              color: IdrColors.zinc400,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  static String _providerName(IdrAuthProvider p) => switch (p) {
    IdrAuthProvider.google => 'Google',
    IdrAuthProvider.microsoft => 'Microsoft',
    IdrAuthProvider.apple => 'Apple',
  };
}

/// Choose Personal / Enterprise / Service Provider and set it up
/// (`idrt personal|enterprise|provider setup`).
class ModeScreen extends StatefulWidget {
  const ModeScreen({super.key, required this.controller});

  final TargetController controller;

  @override
  State<ModeScreen> createState() => _ModeScreenState();
}

class _ModeScreenState extends State<ModeScreen> {
  late IdrBusinessPlan? _plan = widget.controller.plan;
  final _slug = TextEditingController();
  final _brand = TextEditingController();
  String _role = 'auto';

  TargetController get c => widget.controller;

  @override
  void dispose() {
    _slug.dispose();
    _brand.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const blurbs = {
      IdrBusinessPlan.personal: (
        'Use my own devices',
        'Your email is your account. The first machine becomes the admin and approves your other machines.',
        'laptop--you@example.com.idr.to',
      ),
      IdrBusinessPlan.enterprise: (
        'Manage an organization',
        'An organization pays. A root admin machine approves devices and issues zone certificates.',
        'host--brand.idr.to',
      ),
      IdrBusinessPlan.serviceProvider: (
        "Run Targets for customers",
        'Pay per Target seat. Each machine serves one customer tenant, with optional custom domains.',
        'host--provider.idr.to',
      ),
    };
    return FlowScaffold(
      controller: c,
      title: 'How will you use this machine?',
      subtitle: 'You can change this until the machine is registered.',
      steps: _steps,
      step: 1,
      maxWidth: 760,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IdrStatGrid(
            columns: 3,
            children: [
              for (final e in blurbs.entries)
                ChoiceCard(
                  title: e.value.$1,
                  body: e.value.$2,
                  footnote: e.value.$3,
                  selected: _plan == e.key,
                  onTap: c.busy ? null : () => setState(() => _plan = e.key),
                ),
            ],
          ),
          const SizedBox(height: 24),
          if (_plan != null) _form(_plan!),
        ],
      ),
    );
  }

  Widget _form(IdrBusinessPlan plan) {
    final valid = TargetController.orgSlugProblem(_slug.text) == null;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('${plan.title} setup', style: IdrText.display(size: 18)),
            const SizedBox(height: 4),
            Text(
              plan.priceHint,
              style: IdrText.body(size: 12, color: IdrColors.zinc500),
            ),
            const SizedBox(height: 16),
            if (plan != IdrBusinessPlan.personal) ...[
              IdrField(
                label: 'Organization slug',
                required: true,
                hint: 'Copy it from the billing portal (e.g. acme).',
                child: IdrTextField(
                  controller: _slug,
                  hint: 'acme',
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (plan == IdrBusinessPlan.enterprise) ...[
              IdrField(
                label: 'This machine will',
                hint: 'Auto: the owner\'s first machine becomes the admin.',
                child: IdrSelect<String>(
                  value: _role,
                  options: const [
                    IdrOption(value: 'auto', label: 'Decide automatically'),
                    IdrOption(
                      value: 'admin',
                      label: 'Admin: approve devices, hold the org CA',
                    ),
                    IdrOption(value: 'target', label: 'Target: serve services'),
                  ],
                  onChanged: (v) => setState(() => _role = v),
                ),
              ),
              const SizedBox(height: 12),
              IdrField(
                label: 'Brand name',
                hint: 'Optional. Defaults to the organization name.',
                child: IdrTextField(controller: _brand, hint: 'Acme'),
              ),
              const SizedBox(height: 12),
            ],
            if (plan == IdrBusinessPlan.personal)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: IdrAlert(
                  tone: IdrTone.info,
                  title: 'First machine is the admin',
                  message: 'If this email already has an admin machine, this one joins it and waits for approval.',
                ),
              ),
            IdrButton(
              label: 'Continue',
              variant: IdrButtonVariant.primary,
              size: IdrButtonSize.lg,
              expand: true,
              loading: c.busy,
              onPressed: c.busy || (plan != IdrBusinessPlan.personal && !valid)
                  ? null
                  : () => _submit(plan),
            ),
            if (c.plan != null) ...[
              const SizedBox(height: 8),
              IdrButton(
                label: 'Choose a different mode',
                variant: IdrButtonVariant.ghost,
                expand: true,
                onPressed: c.busy
                    ? null
                    : () async {
                        await c.changeMode();
                        setState(() => _plan = null);
                      },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _submit(IdrBusinessPlan plan) {
    return switch (plan) {
      IdrBusinessPlan.personal => c.setupPersonal(),
      IdrBusinessPlan.enterprise => c.setupEnterprise(
        slug: _slug.text,
        admin: switch (_role) {
          'admin' => true,
          'target' => false,
          _ => null,
        },
        brand: _brand.text,
      ),
      IdrBusinessPlan.serviceProvider => c.setupProvider(_slug.text),
    };
  }
}

/// Subscription gate: checkout in the billing portal, then confirm here.
class BillingScreen extends StatefulWidget {
  const BillingScreen({super.key, required this.controller});

  final TargetController controller;

  @override
  State<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends State<BillingScreen> {
  String? _fallbackUrl;

  TargetController get c => widget.controller;

  Future<void> _open(String path) async {
    final url = await c.run('Opening billing portal', () => c.openPortal(path));
    setState(() => _fallbackUrl = url);
  }

  @override
  Widget build(BuildContext context) {
    final plan = c.plan ?? IdrBusinessPlan.personal;
    final org = c.org;
    final managedByOthers = org != null && !canBill(org.role);
    return FlowScaffold(
      controller: c,
      title: 'Activate ${plan.title}',
      subtitle: org == null
          ? 'A subscription is needed before this machine can be registered.'
          : 'Billed to ${org.name} (${org.slug}), you are ${org.role}.',
      steps: _steps,
      step: 2,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          IdrCard(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${plan.checkoutPrice} ${plan.checkoutCadence}',
                  style: IdrText.display(size: 20),
                ),
                const SizedBox(height: 8),
                for (final cap in plan.capabilities)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '✓  $cap',
                      style: IdrText.body(size: 12, color: IdrColors.zinc600),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (managedByOthers)
            IdrAlert(
              tone: IdrTone.warning,
              title: 'Billing is managed by owners and admins',
              message:
                  'Ask an owner of ${org.name} to subscribe, then check again.',
            )
          else ...[
            IdrButton(
              label: 'Open checkout in browser',
              variant: IdrButtonVariant.primary,
              size: IdrButtonSize.lg,
              expand: true,
              onPressed: c.busy ? null : () => _open(c.portalPaths.subscribe),
            ),
            const SizedBox(height: 8),
          ],
          IdrButton(
            label: 'I have completed checkout',
            expand: true,
            loading: c.busy,
            onPressed: c.busy ? null : c.refreshSubscription,
          ),
          if (_fallbackUrl != null) ...[
            const SizedBox(height: 12),
            IdrAlert(
              tone: IdrTone.info,
              title: 'Could not open a browser',
              message: 'Visit this address to continue:\n$_fallbackUrl',
            ),
          ],
          if (c.registration == null) ...[
            const SizedBox(height: 8),
            IdrButton(
              label: 'Choose a different mode',
              variant: IdrButtonVariant.ghost,
              expand: true,
              onPressed: c.busy ? null : c.changeMode,
            ),
          ],
          const SizedBox(height: 4),
          IdrButton(
            label: 'Sign out',
            variant: IdrButtonVariant.ghost,
            expand: true,
            onPressed: c.busy ? null : c.signOut,
          ),
        ],
      ),
    );
  }
}

/// Runs finish-setup (admin CA) when billing is already paid.
class FinishSetupScreen extends StatefulWidget {
  const FinishSetupScreen({super.key, required this.controller});

  final TargetController controller;

  @override
  State<FinishSetupScreen> createState() => _FinishSetupScreenState();
}

class _FinishSetupScreenState extends State<FinishSetupScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.controller.busy) widget.controller.resumeSetup();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return FlowScaffold(
      controller: c,
      title: 'Setting up this machine',
      subtitle: 'Creating the admin certificate authority on this machine.',
      steps: _steps,
      step: 2,
      child: c.error == null
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : IdrButton(
              label: 'Try again',
              variant: IdrButtonVariant.primary,
              onPressed: c.busy ? null : c.resumeSetup,
            ),
    );
  }
}

class RegisterScreen extends StatelessWidget {
  const RegisterScreen({super.key, required this.controller});

  final TargetController controller;

  @override
  Widget build(BuildContext context) {
    return FlowScaffold(
      controller: controller,
      title: 'Register this machine',
      subtitle:
          'Give it a short name. Others reach it at name--account.idr.to.',
      steps: _steps,
      step: 3,
      child: RegisterForm(controller: controller),
    );
  }
}

/// Host registration form (`idrt <mode> register <host>`), for every mode.
class RegisterForm extends StatefulWidget {
  const RegisterForm({super.key, required this.controller});

  final TargetController controller;

  @override
  State<RegisterForm> createState() => _RegisterFormState();
}

class _RegisterFormState extends State<RegisterForm> {
  final _host = TextEditingController();
  final _zone = TextEditingController();
  final _entity = TextEditingController();
  final _tenantId = TextEditingController();
  final _tenantName = TextEditingController();
  final _tenantOrg = TextEditingController();
  String? _tenant;
  String? _hostHint;
  bool _checking = false;

  TargetController get c => widget.controller;
  IdrBusinessPlan get plan => c.plan ?? IdrBusinessPlan.personal;

  @override
  void dispose() {
    for (final t in [
      _host,
      _zone,
      _entity,
      _tenantId,
      _tenantName,
      _tenantOrg,
    ]) {
      t.dispose();
    }
    super.dispose();
  }

  String? get _zoneValue =>
      _zone.text.trim().isEmpty ? null : _zone.text.trim().toLowerCase();
  String? get _entityValue =>
      _entity.text.trim().isEmpty ? null : _entity.text.trim().toLowerCase();

  Future<void> _check() async {
    final problem = TargetController.hostProblem(_host.text);
    if (problem != null) {
      setState(() => _hostHint = problem);
      return;
    }
    setState(() => _checking = true);
    final r = await c.checkHost(
      _host.text,
      zone: _zoneValue,
      entityId: _entityValue,
    );
    if (!mounted) return;
    setState(() {
      _checking = false;
      _hostHint = r == null
          ? 'Could not check availability.'
          : r.available
          ? '${r.fqhn} is available.'
          : '${r.fqhn} is taken. Pick another name.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final isProvider = plan == IdrBusinessPlan.serviceProvider;
    final isEnterprise = plan == IdrBusinessPlan.enterprise;
    final ready =
        TargetController.hostProblem(_host.text) == null &&
        (!isProvider || _tenant != null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isProvider) ..._tenantPicker(),
        IdrField(
          label: 'Host name',
          required: true,
          hint:
              _hostHint ??
              'Lowercase letters, digits and -. For example: laptop',
          child: IdrTextField(
            controller: _host,
            hint: 'laptop',
            onChanged: (_) => setState(() => _hostHint = null),
          ),
        ),
        if (isEnterprise) ...[
          const SizedBox(height: 12),
          IdrField(
            label: 'Zone',
            hint: 'Optional department, e.g. fin or fin.apac.',
            child: IdrTextField(controller: _zone, hint: 'fin'),
          ),
          const SizedBox(height: 12),
          IdrAccordion(
            label: 'Advanced',
            child: IdrField(
              label: 'Join entity',
              hint: 'Owner sign-in email. Needed when you are not the organization owner.',
              child: IdrTextField(controller: _entity, hint: 'owner@acme.com'),
            ),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: IdrButton(
                label: 'Check name',
                loading: _checking,
                onPressed: c.busy || _checking || _host.text.trim().isEmpty
                    ? null
                    : _check,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 2,
              child: IdrButton(
                label: 'Register',
                variant: IdrButtonVariant.primary,
                loading: c.busy,
                onPressed: c.busy || !ready
                    ? null
                    : () => c.registerMachine(
                        _host.text,
                        zone: _zoneValue,
                        entityId: _entityValue,
                        tenantId: _tenant,
                      ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (c.registration == null && !c.isAdminMachine)
          Text(
            'Unless this machine is the admin, an admin approves it before it can serve.',
            style: IdrText.body(
              size: 12,
              color: IdrColors.zinc400,
              height: 1.4,
            ),
          ),
      ],
    );
  }

  List<Widget> _tenantPicker() {
    return [
      if (c.tenants.isNotEmpty) ...[
        IdrField(
          label: 'Customer tenant',
          required: true,
          hint: 'One machine serves one tenant.',
          child: IdrSelect<String?>(
            value: _tenant,
            options: [
              const IdrOption(value: null, label: 'Choose a tenant'),
              for (final t in c.tenants)
                IdrOption(value: t.id, label: '${t.id} (${t.name})'),
            ],
            onChanged: (v) => setState(() => _tenant = v),
          ),
        ),
        const SizedBox(height: 12),
      ],
      IdrAccordion(
        label: c.tenants.isEmpty ? 'Add your first tenant' : 'Add a tenant',
        initiallyOpen: c.tenants.isEmpty,
        child: Column(
          children: [
            IdrField(
              label: 'Tenant id',
              child: IdrTextField(
                controller: _tenantId,
                hint: 'acme',
                onChanged: (_) => setState(() {}),
              ),
            ),
            const SizedBox(height: 8),
            IdrField(
              label: 'Display name',
              child: IdrTextField(controller: _tenantName, hint: 'Acme Corp'),
            ),
            const SizedBox(height: 8),
            IdrField(
              label: 'Customer billing org',
              hint: 'Optional. The customer\'s org pays for its seats (you must be owner or admin there). Default: your provider org.',
              child: IdrTextField(controller: _tenantOrg, hint: 'acme'),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: IdrButton(
                label: 'Add tenant',
                size: IdrButtonSize.sm,
                onPressed: c.busy || _tenantId.text.trim().isEmpty
                    ? null
                    : () async {
                        await c.addTenant(
                          _tenantId.text,
                          name: _tenantName.text,
                          billingOrg: _tenantOrg.text,
                        );
                        if (c.error == null) {
                          setState(() {
                            _tenant = _tenantId.text.trim().toLowerCase();
                            _tenantId.clear();
                            _tenantName.clear();
                            _tenantOrg.clear();
                          });
                        }
                      },
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
    ];
  }
}
