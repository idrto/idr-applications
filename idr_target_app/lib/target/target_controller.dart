import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:idr_target/idr_target.dart';

import 'target_env.dart';

/// Billing org this machine is bound to (Enterprise / Provider); null = personal.
typedef TargetOrg = ({String slug, String name, String role});

/// A customer tenant a Service Provider runs Targets for (local to this machine).
typedef Tenant = ({String id, String name, String? org});

/// Outcome of a setup step: done, or the user must pay first.
enum SetupResult { done, needsBilling }

/// Org `owner` / `admin` can buy and register hosts; `member` cannot.
bool canBill(String role) => role == 'owner' || role == 'admin';

/// User-facing text for anything the SDK, billing or the OS can throw.
String describeError(Object e) {
  if (e is IdrTargetException) return e.message;
  if (e is CustomDomainException) return e.message;
  if (e is StateError) return e.message;
  if (e is ArgumentError) return '${e.message}';
  return '$e';
}

/// Thin presentation-side orchestration over [IdrTarget].
///
/// All business operations (auth, registration, enrollment, CA, billing,
/// services, domains, agent) are SDK calls. This class only sequences them the
/// way the tested `idrt` CLI does (`personal|enterprise|provider setup`,
/// `register`, `approve`, `domain`, `start`), keeps the few settings the CLI
/// keeps outside the SDK (bound org, provider tenants) and exposes busy/error
/// state to widgets.
class TargetController extends ChangeNotifier {
  TargetController({IdrTarget? target, SessionStore? store})
    : store = store ?? SessionStore(),
      _injected = target {
    this.target =
        _injected ?? IdrTarget(config: buildConfig(), store: this.store);
  }

  final SessionStore store;
  final IdrTarget? _injected;
  late final IdrTarget target;
  StreamSubscription<TargetState>? _sub;

  static const _orgKey = 'idrt.org';
  static const _providerKey = 'idrt.provider';
  static const _setupKey = 'idrg.setup';

  bool booted = false;
  String? busyLabel;
  String? error;
  TargetOrg? org;
  IdrLoginOptions? loginOptions;
  String? loginOptionsError;
  List<Tenant> tenants = const [];
  String? machineTenant;
  bool _adminCaReady = false;

  bool get busy => busyLabel != null;
  TargetState get state => target.state;
  IdrAuthSession? get session => target.session;
  IdrTargetRegistration? get registration => target.registration;
  TargetUserState get user => target.userState;
  IdrBusinessPlan? get plan => IdrBusinessPlan.fromPlanCode(user.planCode);
  bool get isAdminMachine => user.accountPath == 'rootAdmin';
  bool get covered => user.hasActivePlan;
  bool get awaitingApproval => state.enrollment.awaitingAdmin;
  bool get agentRunning =>
      state.agent == AgentRuntimeStatus.running ||
      state.agent == AgentRuntimeStatus.reconnecting;

  /// Setup is complete when the paid plan is active and, for admin machines,
  /// the local CA exists (the CLI creates it right after billing passes).
  bool get setupPending =>
      state.readyStep is Ready && isAdminMachine && !_adminCaReady;

  // --- Lifecycle -------------------------------------------------------------

  Future<void> boot() async {
    if (booted) return;
    _sub = target.stateStream.listen((_) => notifyListeners());
    try {
      await target.start(launchAgent: false);
      await _loadLocal();
      if (session == null) await loadLoginOptions();
    } catch (e) {
      error = describeError(e);
    }
    booted = true;
    notifyListeners();
  }

  Future<void> _loadLocal() async {
    final o = await store.readJson(_orgKey);
    org = o == null
        ? null
        : (
            slug: o['slug'] as String,
            name: o['name'] as String? ?? '',
            role: o['role'] as String? ?? 'member',
          );
    final p = await store.readJson(_providerKey);
    tenants = [
      for (final t in (p?['tenants'] as List? ?? const []).cast<Map>())
        (
          id: t['id'] as String,
          name: t['name'] as String,
          org: t['org'] as String?,
        ),
    ];
    machineTenant = p?['machineTenant'] as String?;
    _adminCaReady = (await store.readJson(_setupKey))?['adminCa'] == true;
  }

  /// Runs [body] once at a time; any failure lands in [error].
  Future<T?> run<T>(String label, Future<T> Function() body) async {
    if (busy) return null;
    busyLabel = label;
    error = null;
    notifyListeners();
    try {
      return await body();
    } catch (e) {
      error = describeError(e);
      return null;
    } finally {
      busyLabel = null;
      notifyListeners();
    }
  }

  /// Rebuild listeners after a change made through [target] directly.
  void refresh() => notifyListeners();

  void clearError() {
    error = null;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    unawaited(target.dispose());
    super.dispose();
  }

  // --- Sign-in ---------------------------------------------------------------

  Future<void> loadLoginOptions({bool force = false}) async {
    try {
      loginOptions = await target.fetchLoginOptions(force: force);
      loginOptionsError = null;
    } catch (e) {
      loginOptionsError = describeError(e);
    }
    notifyListeners();
  }

  Future<void> signIn() => run('Waiting for sign-in in your browser', () async {
    await target.signIn(launchAgent: false);
    if (session == null) {
      throw StateError(
        'Sign-in failed: ${target.attention?.message ?? 'unknown error'}',
      );
    }
    await _loadLocal();
  });

  Future<void> signOut() => run('Signing out', () async {
    await target.signOut();
    await store.deleteSecret(_orgKey);
    await store.deleteSecret(_providerKey);
    await store.deleteSecret(_setupKey);
    org = null;
    tenants = const [];
    machineTenant = null;
    _adminCaReady = false;
    await loadLoginOptions(force: true);
  });

  // --- Mode setup (idrt personal|enterprise|provider setup) --------------------

  Future<void> _saveOrg(TargetOrg o) async {
    org = o;
    await store.writeJson(_orgKey, {
      'slug': o.slug,
      'name': o.name,
      'role': o.role,
    });
  }

  Future<void> _clearOrg() async {
    org = null;
    await store.deleteSecret(_orgKey);
  }

  /// Paid plan of a different mode blocks this one (one subscription per org).
  void _requireNoOtherPlan(IdrBusinessPlan want, String who) {
    final paid = user.hasActivePlan ? plan : null;
    if (paid != null && paid != want) {
      throw StateError(
        '$who has an active ${paid.title} subscription, not ${want.title}.',
      );
    }
  }

  /// Forget the chosen mode (only before this machine is registered).
  Future<void> changeMode() => run('Resetting mode', () async {
    if (registration != null) {
      throw StateError(
        'This machine is already registered. Sign out to start over.',
      );
    }
    if (org != null) {
      await target.bindOrganization('me');
      await _clearOrg();
    }
    await target.saveUserState(
      user.copyWith(
        clearPlan: true,
        clearAccountPath: true,
        clearCaRole: true,
        clearEntityRole: true,
        enterpriseEntityConfirmed: false,
        adminAlsoTarget: false,
      ),
    );
    await target.hydrateSubscription();
  });

  Future<SetupResult> _afterPlanChosen() async {
    await target.hydrateSubscription();
    if (!covered) return SetupResult.needsBilling;
    await finishSetup();
    return SetupResult.done;
  }

  /// Personal: the first machine for this email is the admin.
  Future<void> setupPersonal() => run('Setting up Personal', () async {
    if (org != null) {
      await target.bindOrganization('me');
      await _clearOrg();
    }
    _requireNoOtherPlan(IdrBusinessPlan.personal, 'Your account');
    await target.savePlanSelection(planCode: IdrBusinessPlan.personal.planCode);
    if (user.accountPath == null) {
      final roles = await target.resolveRoleAvailability(
        IdrBusinessPlan.personal,
      );
      final admin = roles.adminPathEnabled;
      await target.saveAccountPath(admin ? 'rootAdmin' : 'joinTarget');
      await target.saveEnterpriseUiFlags(
        entityRole: admin ? 'adminCa' : 'enrollTarget',
      );
    }
    await _afterPlanChosen();
  });

  /// Whether the org has no admin machine yet (decides the default role).
  Future<bool?> orgHasAdminMachine() async {
    try {
      return await target.entityRootExists();
    } catch (_) {
      return null;
    }
  }

  /// Enterprise: bind the billing org, pick admin or Target role.
  /// [admin] null = decide like the CLI (first machine of the org's owner
  /// becomes admin, otherwise Target).
  Future<void> setupEnterprise({
    required String slug,
    bool? admin,
    String? brand,
  }) => run('Setting up Enterprise', () async {
    final problem = orgSlugProblem(slug);
    if (problem != null) throw StateError(problem);
    final bound = await _bindOrg(slug);
    if (!canBill(bound.role)) {
      await target.bindOrganization('me');
      await _clearOrg();
      throw StateError(
        'You are a ${bound.role} of ${bound.name}. Registering a machine needs '
        'owner or admin. Ask an owner to change your role, or use `idrt` for '
        'zone-only members.',
      );
    }
    _requireNoOtherPlan(IdrBusinessPlan.enterprise, bound.name);
    await target.savePlanSelection(
      planCode: IdrBusinessPlan.enterprise.planCode,
    );
    if (user.accountPath == null) {
      final isAdmin =
          admin ??
          (bound.role == 'owner' && await orgHasAdminMachine() == false);
      await target.saveAccountPath(isAdmin ? 'rootAdmin' : 'joinTarget');
      await target.saveEnterpriseUiFlags(
        entityRole: isAdmin ? 'adminCa' : 'enrollTarget',
      );
    } else if (admin == true && !isAdminMachine) {
      await _promoteToAdmin(bound);
    }
    final b = brand?.trim();
    await target.enterpriseOrg.setBrandName(
      b != null && b.isNotEmpty
          ? b
          : target.enterpriseOrg.brandName ?? bound.name,
    );
    await _afterPlanChosen();
  });

  Future<TargetOrg> _bindOrg(String slug) async {
    try {
      final o = await target.bindOrganization(slug.trim());
      await _saveOrg(o);
      return o;
    } on IdrTargetException catch (e) {
      if (!e.message.contains('Organization not found')) rethrow;
      throw StateError(
        'No organization has the slug "${slug.trim()}". Create it in the '
        'billing portal or check the slug there.',
      );
    }
  }

  /// A Target whose org has no admin machine can never be approved: make it
  /// the admin instead of starting over (same rule as the CLI).
  Future<void> _promoteToAdmin(TargetOrg o) async {
    final me = session!.email.trim().toLowerCase();
    final entity = registration?.entityId.trim().toLowerCase() ?? me;
    if (entity != me) {
      throw StateError(
        'This machine joined $entity; that account\'s admin machine approves it.',
      );
    }
    if (await target.entityRootExists(entity)) {
      throw StateError(
        '${o.name} already has an admin machine. Approve this machine there.',
      );
    }
    await target.saveAccountPath('rootAdmin');
    await target.saveEnterpriseUiFlags(entityRole: 'adminCa');
  }

  /// Service Provider: bind the provider org. Provider machines are Targets.
  Future<void> setupProvider(String slug) =>
      run('Setting up Provider', () async {
        final problem = orgSlugProblem(slug);
        if (problem != null) throw StateError(problem);
        final bound = await _bindBilling(slug, fallback: 'me');
        _requireNoOtherPlan(IdrBusinessPlan.serviceProvider, bound.name);
        await target.savePlanSelection(
          planCode: IdrBusinessPlan.serviceProvider.planCode,
        );
        await _saveOrg(bound);
        if (user.accountPath == null) {
          await target.saveAccountPath('joinTarget');
          await target.saveEnterpriseUiFlags(entityRole: 'enrollTarget');
        }
        await _saveProvider();
        await _afterPlanChosen();
      });

  /// Bind to [slug] and require owner/admin there; on failure bind back.
  Future<TargetOrg> _bindBilling(
    String slug, {
    required String fallback,
  }) async {
    final bound = await target.bindOrganization(slug.trim());
    if (!canBill(bound.role)) {
      await target.bindOrganization(fallback);
      throw StateError(
        'You are a ${bound.role} of ${bound.name}; a provider needs owner or '
        'admin there to buy seats and register Targets.',
      );
    }
    return bound;
  }

  /// Billing slugs are names, domains or emails, never blank or spaced.
  static String? orgSlugProblem(String slug) {
    final s = slug.trim();
    if (s.isEmpty) {
      return 'Enter the organization slug from the billing portal.';
    }
    if (RegExp(r'\s').hasMatch(s)) {
      return 'An organization slug has no spaces (e.g. acme or acme.com); '
          'copy it from the billing portal.';
    }
    if (s == 'me' || s == 'personal') {
      return 'That is your personal account: choose Personal instead.';
    }
    return null;
  }

  /// After billing passes: the CLI finishes setup by creating the admin CA.
  Future<void> finishSetup() async {
    final p = plan;
    if (p == null || !covered || user.accountPath == null) return;
    if (p == IdrBusinessPlan.enterprise) {
      await target.saveEnterpriseUiFlags(
        entityConfirmed: true,
        caRole: isAdminMachine ? 'root' : null,
      );
    }
    if (isAdminMachine && !_adminCaReady) {
      await target.ensureAdminCa(
        package: p == IdrBusinessPlan.enterprise ? 'enterprise' : null,
      );
      _adminCaReady = true;
      await store.writeJson(_setupKey, {'adminCa': true});
    }
    await target.markOnboardingDone();
    notifyListeners();
  }

  /// Gate hook: resume setup after the app restarted mid-way or billing passed.
  Future<void> resumeSetup() => run('Finishing setup', finishSetup);

  // --- Billing -----------------------------------------------------------------

  ({String subscribe, String manage}) get portalPaths => (
    subscribe: '/shop/${plan?.planCode ?? IdrBusinessPlan.personal.planCode}',
    manage: '/subscriptions',
  );

  /// Opens the portal (already signed in when possible). Returns the plain URL
  /// shown to the user when no browser could be opened.
  Future<String?> openPortal(String path, {String? orgSlug}) async {
    if (portalBaseUrl.isEmpty) {
      throw StateError(
        'Set IDR_BILLING_PORTAL_URL to the billing portal origin.',
      );
    }
    final url = await target.billingPortalUrl(
      portalBaseUrl: portalBaseUrl,
      redirectPath: path,
      orgSlug: orgSlug ?? org?.slug,
    );
    final opened = await LoopbackAuthSessionLauncher.openSystemBrowser(url);
    return opened ? null : '$portalBaseUrl$path';
  }

  Future<void> refreshSubscription() => run('Checking subscription', () async {
    await target.hydrateSubscription();
    if (covered) await finishSetup();
  });

  // --- Register this machine (idrt <mode> register) ----------------------------

  static String? hostProblem(String label) {
    final host = label.trim().toLowerCase();
    if (EnterpriseFqhn.isValidHostLabel(host)) return null;
    final fixed = host
        .replaceAll(RegExp(r'[^a-z0-9-]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return 'Use lowercase letters, digits and -.'
        '${fixed.isEmpty ? '' : ' Try "$fixed".'}';
  }

  /// Whether the host label is free. Null on an invalid label.
  Future<({bool available, String fqhn})?> checkHost(
    String label, {
    String? zone,
    String? entityId,
  }) async {
    if (hostProblem(label) != null) return null;
    try {
      final r = await target.isHostAvailable(
        hostLabel: label.trim().toLowerCase(),
        zone: zone,
        entityId: entityId,
      );
      return (available: r.available, fqhn: r.verifiedFqhn);
    } catch (_) {
      return null;
    }
  }

  /// Register this machine as a Target, then approve it here when this machine
  /// can (admin machines): same sequence as the CLI's `registerThisMachine`.
  Future<void> registerMachine(
    String label, {
    String? zone,
    String? entityId,
    String? tenantId,
  }) => run('Registering this machine', () async {
    final problem = hostProblem(label);
    if (problem != null) throw StateError('Invalid host name. $problem');
    if (registration != null) return;
    final host = label.trim().toLowerCase();
    final Tenant? tenant = tenantId == null
        ? null
        : tenants.firstWhere((t) => t.id == tenantId);
    if (tenant != null) await _bindTenantBilling(tenant);
    final check = await target.isHostAvailable(
      hostLabel: host,
      entityId: entityId,
      zone: zone,
    );
    if (!check.available) {
      throw StateError(
        '${check.verifiedFqhn} is taken. Pick another host name.',
      );
    }
    try {
      await target.registerHost(
        label: host,
        joinEntityId: entityId,
        zone: zone,
      );
    } on IdrTargetException catch (e) {
      if (tenant != null && e.code == IdrTargetErrorCode.quotaExceeded) {
        throw StateError(
          '${org?.name ?? 'The billing org'} has no free Target seat. Add a '
          'seat in the billing portal, then try again.',
        );
      }
      rethrow;
    }
    if (isAdminMachine) {
      await target.saveEnterpriseUiFlags(adminAlsoTarget: true);
    }
    if (plan == IdrBusinessPlan.enterprise) {
      await target.addEnterpriseDevice(
        label: host,
        zonePath: zone == null ? const [] : EnterpriseFqhn.parseZonePath(zone),
      );
    }
    if (tenant != null) {
      machineTenant = tenant.id;
      await _saveProvider();
    }
    if (await isApprover()) await approveSelfIfPending(zone: zone);
  });

  Future<void> _bindTenantBilling(Tenant t) async {
    final slug = t.org ?? org!.slug;
    if (org?.slug != slug) {
      final fallback = org?.slug ?? 'me';
      final bound = await _bindBilling(slug, fallback: fallback);
      await _saveOrg(bound);
    }
    _requireNoOtherPlan(IdrBusinessPlan.serviceProvider, org!.name);
    if (!covered) {
      throw StateError(
        'No active Service Provider subscription for ${org!.name}. Open '
        'Billing to add a Target seat.',
      );
    }
  }

  // --- Approvals (idrt <mode> pending|approve|reject) --------------------------

  /// Admin machines, or a machine holding a zone key, review enrollments.
  Future<bool> isApprover() async {
    if (plan == IdrBusinessPlan.serviceProvider) return true;
    return isAdminMachine || (await target.zoneAuthorities()).isNotEmpty;
  }

  String get approverEntity =>
      (registration?.entityId ?? session!.email).trim().toLowerCase();

  Future<List<EnrollmentRequest>> pendingRequests() async => [
    for (final r in await target.listPendingEnrollments(approverEntity))
      if (r.isPending) r,
  ];

  Future<Set<String>> zoneKeysHere() async => {
    for (final z in await target.zoneAuthorities()) z.zone,
  };

  /// Admin machine: approve this machine's own pending Target registration.
  Future<bool> approveSelfIfPending({String? zone}) async {
    final reg = registration;
    if (reg == null || !awaitingApproval) return false;
    final mine =
        (await target.listPendingEnrollments(reg.entityId.trim().toLowerCase()))
            .where(
              (r) =>
                  r.isPending &&
                  ((reg.machineSki != null && r.subjectSki == reg.machineSki) ||
                      r.verifiedFqhn == reg.verifiedFqhn),
            );
    if (mine.isEmpty) return false;
    await target.approveEnrollment(enrollId: mine.first.id, zone: zone);
    return true;
  }

  Future<void> approve(EnrollmentRequest r, {String? zone}) =>
      run('Approving ${r.hostLabel}', () async {
        final keys = await zoneKeysHere();
        final needed = zone ?? (r.isZoneKey ? null : r.zone);
        if (needed != null && !keys.contains(needed)) {
          throw StateError(
            'This machine has no key for zone $needed. Issue it under '
            'Organization > Zones first.',
          );
        }
        await target.approveEnrollment(enrollId: r.id, zone: zone);
      });

  Future<void> reject(EnrollmentRequest r) =>
      run('Rejecting ${r.hostLabel}', () => target.rejectEnrollment(r.id));

  /// Target waiting for its admin: poll the enroll-pull once.
  Future<String?> refreshEnrollment() => run('Checking approval', () async {
    final status = await target.refreshEnrollmentPull();
    if (status == 'rejected') {
      await target.clearPendingTargetEnrollment();
      throw StateError('The admin rejected this machine. Register again.');
    }
    return status;
  });

  /// Silent poll while this Target waits for its admin; starts serving once
  /// approved. Never raises (called from a timer).
  Future<void> pollEnrollment() async {
    if (busy || !awaitingApproval) return;
    try {
      final status = await target.refreshEnrollmentPull();
      if (status == 'approved') {
        await startServing();
      } else if (status == 'rejected') {
        await target.clearPendingTargetEnrollment();
        error = 'The admin rejected this machine. Register it again.';
        notifyListeners();
      }
    } catch (_) {
      // Offline or admin not reachable yet: try again on the next tick.
    }
  }

  // --- Agent (idrt start) -------------------------------------------------------

  Future<void> startServing() => run('Starting the Target agent', () async {
    await target.hydrateSubscription();
    if (!covered) return;
    await target.start();
    final s = target.status;
    if (s != IdrTargetStatus.running && s != IdrTargetStatus.starting) {
      final a = target.attention;
      throw StateError(
        'The Target agent did not start (${s.name})'
        '${a == null ? '' : ': ${a.message}'}',
      );
    }
  });

  Future<void> stopServing() => run('Stopping the Target agent', target.stop);

  // --- Services (idrt services) -----------------------------------------------

  /// Null on success, else the validation message.
  Future<String?> addService({
    required String name,
    required String type,
    required String endpoint,
    required bool requireTls,
  }) async {
    final err = await target.addServiceFromForm(
      name: name,
      type: type,
      endpoint: endpoint,
      credentialMode: 'source',
      requireTls: requireTls,
    );
    notifyListeners();
    return err;
  }

  Future<void> removeService(String name) =>
      run('Removing $name', () => target.removeService(name));

  Future<void> toggleService(String name) =>
      run('Updating $name', () => target.toggleService(name));

  // --- Custom domains (idrt provider domain) ------------------------------------

  Future<List<CustomDomain>?> domains() async {
    try {
      return await target.customDomains();
    } catch (e) {
      error = describeError(e);
      notifyListeners();
      return null;
    }
  }

  // --- Provider tenants (local to this machine) ---------------------------------

  Future<void> _saveProvider() => store.writeJson(_providerKey, {
    'org': org?.slug,
    'orgName': org?.name,
    'tenants': [
      for (final t in tenants) {'id': t.id, 'name': t.name, 'org': t.org},
    ],
    'machineTenant': machineTenant,
  });

  Future<void> addTenant(String id, {String? name, String? billingOrg}) => run(
    'Adding tenant',
    () async {
      final tid = id.trim().toLowerCase();
      if (!EnterpriseFqhn.isValidZoneLabel(tid)) {
        throw StateError('Tenant id must be lowercase letters, digits and -.');
      }
      if (tenants.any((t) => t.id == tid)) {
        throw StateError('Tenant $tid already exists.');
      }
      final bo = billingOrg?.trim();
      String? tenantOrg;
      if (bo != null && bo.isNotEmpty && bo != org?.slug) {
        // Verify the provider can bill there, then restore this machine's org.
        final current = org?.slug ?? 'me';
        final bound = await _bindBilling(bo, fallback: current);
        await target.bindOrganization(current);
        tenantOrg = bound.slug;
      }
      final n = name?.trim();
      tenants = [
        ...tenants,
        (id: tid, name: n == null || n.isEmpty ? tid : n, org: tenantOrg),
      ];
      await _saveProvider();
    },
  );

  Future<void> removeTenant(String id) => run('Removing tenant', () async {
    if (id == machineTenant && registration != null) {
      throw StateError('This machine serves that tenant. Sign out first.');
    }
    tenants = [...tenants.where((t) => t.id != id)];
    await _saveProvider();
  });

  // --- Enterprise org (zones, policy, revoke, members) --------------------------

  Future<void> addZone(
    String pathRaw,
    String name,
  ) => run('Issuing zone certificate', () async {
    if (user.enterpriseCaRole != 'root' || !isAdminMachine) {
      throw StateError(
        'Only the root CA admin machine issues zone certificates.',
      );
    }
    final path = EnterpriseFqhn.parseZonePath(pathRaw.trim().toLowerCase());
    if (path.isEmpty || !path.every(EnterpriseFqhn.isValidZoneLabel)) {
      throw StateError(
        'Use lowercase letters, digits and -, with dots between levels.',
      );
    }
    if (path.length > 1 &&
        !target.enterpriseZones.any(
          (z) => z.pathKey == path.sublist(0, path.length - 1).join('.'),
        )) {
      throw StateError(
        'Add the parent zone ${path.sublist(0, path.length - 1).join('.')} first.',
      );
    }
    await target.createZoneAuthority(
      path: path,
      displayName: name.trim().isEmpty ? path.last : name.trim(),
    );
  });

  Future<void> setZonePolicy(String zone, List<String> services) =>
      run('Signing zone policy', () async {
        await target.setZonePolicy(
          path: EnterpriseFqhn.parseZonePath(zone),
          services: services,
        );
      });

  Future<void> revokeZone(String zone, {String? reason}) =>
      run('Revoking zone', () async {
        await target.revokeZone(
          EnterpriseFqhn.parseZonePath(zone),
          reason: reason,
        );
      });

  Future<void> revokeCredential(String ski, {String? reason}) =>
      run('Revoking credential', () async {
        await target.revokeCredential(ski, reason: reason);
      });

  /// Add [email] to [zone] (admin if the zone has none yet, else member).
  Future<void> addToZone(String zone, String email, {String? role}) =>
      run('Adding $email to $zone', () async {
        await target.setZoneRole(zone: zone, email: email, role: role);
      });
}
