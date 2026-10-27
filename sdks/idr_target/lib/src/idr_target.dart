import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:two_key_dart_sdk/two_key_headless.dart';

import 'agent/agent_runtime.dart';
import 'auth/auth.dart';
import 'auth/auth_manager.dart';
import 'auth/user_state.dart';
import 'auth/user_state_store.dart';
import 'config.dart';
import 'crypto/dp/idr_dp_crypto.dart';
import 'crypto/idr_crypto.dart';
import 'dp/identity_store.dart';
import 'entitlement/billing_commerce.dart';
import 'entitlement/entitlement_manager.dart';
import 'errors.dart';
import 'internal/logging.dart';
import 'plan/business_plan.dart';
import 'plan/role_availability.dart';
import 'registration/custom_domain_client.dart';
import 'registration/enroll_client.dart';
import 'registration/enrollment_manager.dart';
import 'registration/enrollment_models.dart';
import 'registration/registration.dart';
import 'registration/registration_client.dart';
import 'registration/registration_manager.dart';
import 'enterprise/enterprise_fqhn.dart';
import 'enterprise/enterprise_org_manager.dart';
import 'enterprise/enterprise_org_models.dart';
import 'services/scan_hit.dart';
import 'services/service_entry.dart';
import 'services/services_manager.dart';
import 'state/agent_runtime_status.dart';
import 'state/enrollment_snapshot.dart';
import 'state/ready_step.dart';
import 'state/target_state.dart';
import 'status.dart';
import 'tls/certificate_manager.dart';
import 'tls/tls_status.dart';

/// Production Target Agent facade (orchestrator over managers).
///
/// Developers drive [start] / [signIn] / [registerHost] / [stop] and observe
/// [stateStream] (plus legacy [statusStream] / [attentionStream]).
class IdrTarget {
  IdrTarget({
    required this.config,
    IdrCrypto? crypto,
    SessionStore? store,
    BillingAuthClient? authClient,
    Future<bool> Function(Uri url)? openUrl,
    List<IdrServiceEntry>? services,
    http.Client? httpClient,
    BillingCommerceClient? billingCommerce,
  })  : _store = store ?? SessionStore(),
        _crypto = crypto,
        _openUrl = openUrl ?? LoopbackAuthSessionLauncher.openSystemBrowser {
    final launcher = LoopbackAuthSessionLauncher(openBrowser: _openUrl);
    _authClient = authClient ??
        BillingAuthClient(
          billingBaseUrl: config.controlPlaneBase,
          deepLinkScheme: 'idr',
          storagePrefix: _store.prefix,
          storage: _store.storage,
          sessionLauncher: launcher.call,
          httpClient: httpClient,
        );
    _authClient.setOnline(false);
    _auth = AuthManager(client: _authClient, store: _store, launcher: launcher);
    _identity = DpIdentityStore(_store);
    _registrationClient = RegistrationClient(
      controlPlaneUrl: config.controlPlaneBase,
      store: _store,
      httpClient: httpClient,
    );
    _enrollClient = EnrollClient(
      controlPlaneUrl: config.controlPlaneBase,
      httpClient: httpClient,
    );
    _customDomainClient = CustomDomainClient(
      controlPlaneUrl: config.controlPlaneBase,
      httpClient: httpClient,
    );

    _enrollment = EnrollmentManager(
      enroll: _enrollClient,
      registration: _registrationClient,
      identity: _identity,
      requireCrypto: _requireCrypto,
    );
    _registration = RegistrationManager(
      client: _registrationClient,
      enroll: _enrollClient,
      identity: _identity,
      requireCrypto: _requireCrypto,
      ensureAdminCa: ({
        required IdrAuthSession session,
        required String entityId,
      }) =>
          _enrollment.ensureAdminCa(
        session: session,
        entityId: entityId,
        ensureEmailEntity: _registrationClient.ensureEmailEntity,
        package: _dpPackage,
      ),
    );
    _entitlement = EntitlementManager(
      apiBaseUrl: config.controlPlaneBase,
      store: _store,
      requireCrypto: _requireCrypto,
    );
    _commerce = billingCommerce ??
        BillingCommerceClient(
          apiBaseUrl: config.controlPlaneBase,
          httpClient: httpClient,
        );
    _services = ServicesManager(
      store: _store,
      initial: services,
      onChange: _onServicesChanged,
    );
    _enterpriseOrg = EnterpriseOrgManager(
      store: _store,
      onChange: _publishState,
    );
    _agent = AgentRuntime(
      config: config,
      configDir: () => configDir,
      // Enterprise Targets serve only Presence-verified Sources, per zone policy.
      requireSourcePolicy: () => _dpPackage == 'enterprise',
      customDomains: _verifiedCustomDomains,
      onStatus: (s) {
        _agentStatus = s;
        switch (s) {
          case AgentRuntimeStatus.starting:
            _setStatus(IdrTargetStatus.starting);
          case AgentRuntimeStatus.running:
            _setStatus(IdrTargetStatus.running);
            _setAttention(null);
          case AgentRuntimeStatus.reconnecting:
            _setStatus(IdrTargetStatus.reconnecting);
          case AgentRuntimeStatus.stopped:
            break;
        }
        _publishState();
      },
      onAttention: _setAttention,
    );
  }

  final IdrTargetConfig config;
  final SessionStore _store;
  IdrCrypto? _crypto;
  late final BillingAuthClient _authClient;
  late final DpIdentityStore _identity;
  late final RegistrationClient _registrationClient;
  late final EnrollClient _enrollClient;
  late final CustomDomainClient _customDomainClient;
  late final AuthManager _auth;
  late final RegistrationManager _registration;
  late final EnrollmentManager _enrollment;
  late final EntitlementManager _entitlement;
  late final BillingCommerceClient _commerce;
  late final ServicesManager _services;
  late final EnterpriseOrgManager _enterpriseOrg;
  late final AgentRuntime _agent;
  final Future<bool> Function(Uri url) _openUrl;

  /// Current [[services]] gateway entries (from [ServicesManager]).
  List<IdrServiceEntry> get services => _services.services;

  /// Local enterprise org graph (zones / admins / devices).
  EnterpriseOrgManager get enterpriseOrg => _enterpriseOrg;

  /// Env vars injected into the agent process (shared with [AgentRuntime]).
  Map<String, String> get injectEnv => _agent.injectEnv;

  final _statusCtrl = StreamController<IdrTargetStatus>.broadcast();
  final _attentionCtrl = StreamController<IdrTargetAttention?>.broadcast();
  final _tlsCtrl = StreamController<IdrTlsStatus>.broadcast();
  final _stateCtrl = StreamController<TargetState>.broadcast();

  IdrTargetStatus _status = IdrTargetStatus.initializing;
  IdrTargetAttention? _attention;
  IdrTlsStatus _tlsStatus = IdrTlsStatus.pending;
  IdrAuthSession? _authSession;
  String? _pendingCheckoutSessionId;
  IdrTargetRegistration? _registrationState;
  TargetUserState _userState = const TargetUserState();
  AgentRuntimeStatus _agentStatus = AgentRuntimeStatus.stopped;
  CertificateManager? _certs;
  TargetState _state = const TargetState(
    status: IdrTargetStatus.initializing,
    readyStep: SignInRequired(),
    user: TargetUserState(),
    tls: IdrTlsStatus.pending,
  );

  Stream<IdrTargetStatus> get statusStream => _statusCtrl.stream;
  Stream<IdrTargetAttention?> get attentionStream => _attentionCtrl.stream;
  Stream<IdrTlsStatus> get tlsStatusStream => _tlsCtrl.stream;
  Stream<TargetState> get stateStream => _stateCtrl.stream;

  TargetState get state => _state;
  IdrTargetStatus get status => _status;
  IdrTargetAttention? get attention => _attention;
  IdrTlsStatus get tlsStatus => _tlsStatus;
  IdrAuthSession? get session => _authSession;
  IdrTargetRegistration? get registration => _registrationState;

  /// First-run / plan / role choices persisted in the SDK secure store.
  TargetUserState get userState => _userState;

  /// Last successful [fetchLoginOptions] result for this process (in-memory).
  IdrLoginOptions? get loginOptions => _auth.loginOptions;

  void _publishState() {
    final pull = _registrationState?.enrollPullToken;
    _state = TargetState(
      status: _status,
      readyStep: TargetReadyStep.resolve(
        session: _authSession,
        userState: _userState,
        registration: _registrationState,
      ),
      attention: _attention,
      session: _authSession,
      loginOptions: _auth.loginOptions,
      user: _userState,
      registration: _registrationState,
      enrollment: EnrollmentSnapshot(
        awaitingAdmin: pull != null && pull.isNotEmpty,
        pullToken: pull,
        pending: _enrollment.pending,
      ),
      tls: _tlsStatus,
      services: List.unmodifiable(services),
      agent: _agentStatus,
    );
    if (!_stateCtrl.isClosed) _stateCtrl.add(_state);
  }

  /// Persist first-run / plan / role UI state (does not clear SSO).
  Future<void> saveUserState(TargetUserState state) async {
    _userState = state;
    await _store.saveUserState(state);
    _publishState();
  }

  Future<void> markOnboardingDone() async {
    await saveUserState(_userState.copyWith(onboardingDone: true));
  }

  Future<void> saveAccountPath(String path) async {
    await saveUserState(_userState.copyWith(accountPath: path));
  }

  /// Probe whether the personal Billing email entity already exists (lookup only).
  Future<({bool exists, String entityId})> probePersonalEntity() async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    return _registration.probePersonalEntity(session);
  }

  /// Admin vs Target path availability for [plan].
  ///
  /// Personal Admin exists only after Entity CA kickstart (DP), not after a
  /// Billing email row from Source host register.
  Future<RoleAvailability> resolveRoleAvailability(IdrBusinessPlan plan) async {
    try {
      var adminExists = false;
      if (plan == IdrBusinessPlan.personal && _authSession != null) {
        final email = _authSession!.email.trim().toLowerCase();
        adminExists = email.isNotEmpty &&
            await _enrollClient.entityExists(
              session: _authSession!,
              entityId: email,
            );
      }
      return RoleAvailability.forPlan(
        plan: plan,
        personalAdminExists: adminExists,
      );
    } catch (_) {
      return RoleAvailability.fallback(plan);
    }
  }

  /// Whether [entityId] (default: the signed-in email) already has a root CA,
  /// i.e. some admin machine set it up. Lookup only.
  Future<bool> entityRootExists([String? entityId]) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    return _enrollClient.entityExists(
      session: session,
      entityId: entityId ?? session.email,
    );
  }

  Future<void> savePlanSelection({required String planCode}) async {
    await saveUserState(_userState.copyWith(planCode: planCode));
  }

  /// Refresh [TargetUserState.hasActivePlan] from Billing. Server is truth.
  Future<void> hydrateSubscription() async {
    final session = _authSession;
    if (session == null) return;
    try {
      final pendingSessionId = _pendingCheckoutSessionId;
      if (pendingSessionId != null) {
        await _commerce.fulfillCheckout(
          session: session,
          sessionId: pendingSessionId,
        );
      }
      final covering = await _commerce.fetchCovering(session);
      if (covering != null) {
        _pendingCheckoutSessionId = null;
        await saveUserState(
          _userState.copyWith(
            planCode: covering.planCode,
            hasActivePlan: true,
          ),
        );
        return;
      }
      await saveUserState(_userState.copyWith(hasActivePlan: false));
    } on IdrTargetException catch (e) {
      if (e.code == IdrTargetErrorCode.authExpired ||
          e.code == IdrTargetErrorCode.authRequired) {
        await _auth.signOut();
        _authSession = null;
        _setStatus(IdrTargetStatus.signedOut);
        _setAttention(IdrTargetAttention(code: e.code, message: e.message));
        return;
      }
      _setAttention(IdrTargetAttention(code: e.code, message: e.message));
    } catch (e) {
      _setAttention(IdrTargetErrors.attentionFor(
        e,
        apiBase: config.controlPlaneBase,
        fallbackCode: IdrTargetErrorCode.billingUnavailable,
        context: 'billing',
      ));
    }
  }

  /// Open Billing/Stripe checkout for [planCode], then rehydrate.
  Future<void> startCheckout(String planCode) async {
    final session = _authSession;
    if (session == null) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.authRequired,
        message: IdrTargetErrorMessages.authRequired,
      );
    }
    final created = await _commerce.createCheckoutSession(
      session: session,
      planCode: planCode,
    );
    _pendingCheckoutSessionId =
        created.sessionId.isEmpty ? null : created.sessionId;
    final opened = await _openUrl(Uri.parse(created.url));
    if (!opened) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.billingUnavailable,
        message: IdrTargetErrorMessages.billingUnavailable,
      );
    }
  }

  Future<void> saveEnterpriseUiFlags({
    String? caRole,
    bool? entityConfirmed,
    String? entityRole,
    bool? adminAlsoTarget,
  }) async {
    await saveUserState(
      _userState.copyWith(
        enterpriseCaRole: caRole,
        enterpriseEntityConfirmed: entityConfirmed,
        entityRole: entityRole,
        adminAlsoTarget: adminAlsoTarget,
      ),
    );
  }

  /// Clear role after sign-out. Plan cache stays; next [start]/[signIn] rehydrates.
  Future<void> clearAccountUserState() async {
    await saveUserState(
      _userState.copyWith(
        onboardingDone: true,
        clearAccountPath: true,
        clearCaRole: true,
        clearEntityRole: true,
        enterpriseEntityConfirmed: false,
        adminAlsoTarget: false,
      ),
    );
  }

  /// Load configured sign-in methods from Auth (oauth-providers discovery).
  Future<IdrLoginOptions> fetchLoginOptions({bool force = false}) async {
    try {
      final options = await _auth.fetchLoginOptions(
        apiBase: config.controlPlaneBase,
        force: force,
      );
      _publishState();
      return options;
    } catch (e) {
      final attention = e is IdrTargetException
          ? IdrTargetAttention(code: e.code, message: e.message)
          : IdrTargetErrors.attentionFor(
              e,
              apiBase: config.controlPlaneBase,
              fallbackCode: IdrTargetErrorCode.configInvalid,
              context: 'login-options',
            );
      _setAttention(attention);
      if (e is IdrTargetException) rethrow;
      throw IdrTargetException(
        code: attention.code,
        message: attention.message,
        cause: e,
      );
    }
  }

  Directory get configDir {
    if (config.configDirectory != null) {
      return Directory(config.configDirectory!);
    }
    final home = Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        '.';
    return Directory(p.join(home, 'to.idr', 'idr_target'));
  }

  void _setStatus(IdrTargetStatus s) {
    _status = s;
    if (!_statusCtrl.isClosed) _statusCtrl.add(s);
    _publishState();
  }

  void _setAttention(IdrTargetAttention? a) {
    _attention = a;
    if (!_attentionCtrl.isClosed) _attentionCtrl.add(a);
    if (a != null) {
      _status = IdrTargetStatus.needsAttention;
      if (!_statusCtrl.isClosed) _statusCtrl.add(_status);
    }
    _publishState();
  }

  void _setTls(IdrTlsStatus s) {
    _tlsStatus = s;
    if (!_tlsCtrl.isClosed) _tlsCtrl.add(s);
    _publishState();
  }

  IdrCrypto _requireCrypto() {
    if (_crypto != null) return _crypto!;
    try {
      _crypto = IdrDpCrypto.open();
      return _crypto!;
    } catch (_) {
      _setAttention(const IdrTargetAttention(
        code: IdrTargetErrorCode.cryptoUnavailable,
        message: IdrTargetMessages.cryptoUnavailable,
      ));
      throw StateError(IdrTargetMessages.cryptoUnavailable);
    }
  }

  /// Bind the session to billing org [slug] (`me` = personal) and rehydrate
  /// the subscription for that org. [role] is `owner` | `admin` | `member`.
  Future<({String slug, String name, String role})> bindOrganization(
    String slug,
  ) async {
    if (_authSession == null) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.authRequired,
        message: IdrTargetErrorMessages.authRequired,
      );
    }
    final bound = await _auth.bindOrganization(slug);
    _authSession = bound.session;
    await hydrateSubscription();
    return (slug: bound.slug, name: bound.name, role: bound.role);
  }

  Future<List<OrgMember>> listOrganizationMembers() =>
      _auth.listOrganizationMembers();

  Future<List<OrgInvitation>> listOrganizationInvitations() =>
      _auth.listOrganizationInvitations();

  Future<void> inviteOrganizationMember({
    required String email,
    String role = 'member',
  }) =>
      _auth.inviteOrganizationMember(email: email, role: role);

  Future<void> updateOrganizationMemberRole({
    required String memberId,
    required String role,
  }) =>
      _auth.updateOrganizationMemberRole(memberId: memberId, role: role);

  Future<void> removeOrganizationMember({required String memberIdOrEmail}) =>
      _auth.removeOrganizationMember(memberIdOrEmail: memberIdOrEmail);

  /// Signed-in billing portal URL for [redirectPath] (e.g. `/shop/idr_personal_bundle`).
  ///
  /// [orgSlug] preselects that org in the portal's account picker.
  /// Falls back to the plain portal URL (portal asks to sign in) when the
  /// one-time-token handoff is unavailable.
  Future<Uri> billingPortalUrl({
    required String portalBaseUrl,
    String redirectPath = '/',
    String? orgSlug,
  }) async {
    try {
      return await _authClient.createPortalHandoffUrl(
        portalBaseUrl: portalBaseUrl,
        redirectPath: redirectPath,
        orgSlug: orgSlug,
      );
    } catch (e) {
      idrLog('billingPortalUrl: handoff unavailable ($e)');
      final base = portalBaseUrl.replaceAll(RegExp(r'/$'), '');
      return Uri.parse('$base$redirectPath');
    }
  }

  /// Restore session / registration / UI state and advance when possible.
  ///
  /// [launchAgent] false restores and hydrates state only (CLI read commands).
  Future<void> start({bool launchAgent = true}) async {
    _setStatus(IdrTargetStatus.initializing);
    _setAttention(null);
    idrLog(
      'start: mode=${config.mode} discovery=${config.discoveryUrl} '
      'insecureDev=${config.insecureDev} agentBinary=${config.agentBinaryPath} '
      'configDir=${configDir.path}',
    );
    try {
      await configDir.create(recursive: true);
      _userState = await _store.loadUserState();
      await _services.load();
      await _enterpriseOrg.load();
      _publishState();
      _authSession = await _auth.restore();
      if (_authSession == null) {
        idrLog('start: stop — no auth session (Presence not started)');
        _setStatus(IdrTargetStatus.signedOut);
        _setAttention(const IdrTargetAttention(
          code: IdrTargetErrorCode.authRequired,
          message: IdrTargetMessages.signInRequired,
        ));
        return;
      }
      await hydrateSubscription();
      if (_authSession == null) return;
      _registrationState = await _registration.load();
      if (_registrationState == null) {
        idrLog('start: stop — no host registration (Presence not started)');
        // Admin-only Ready is gated by [TargetReadyStep]; do not fake agent running.
        _setStatus(IdrTargetStatus.registering);
        _setAttention(const IdrTargetAttention(
          code: IdrTargetErrorCode.hostNotRegistered,
          message: IdrTargetMessages.hostRegistrationRequired,
        ));
        return;
      }
      idrLog(
        'start: fqhn=${_registrationState!.verifiedFqhn} '
        'email=${_authSession!.email}',
      );
      final pull = _registrationState!.enrollPullToken;
      if (pull != null && pull.isNotEmpty) {
        await _tryPullEnrollment(pull);
      }
      if (!launchAgent) {
        _setStatus(IdrTargetStatus.stopped);
        return;
      }
      await _continueAfterRegistration();
      idrLog(
        'start: done status=$_status agent=$_agentStatus '
        'attention=${_attention?.code.wire}',
      );
    } catch (e) {
      idrLog('start failed: $e');
      _setStatus(IdrTargetStatus.failed);
      _setAttention(IdrTargetErrors.attentionFor(
        e,
        apiBase: config.controlPlaneBase,
        fallbackCode: IdrTargetErrorCode.configInvalid,
        context: 'startup',
      ));
    }
  }

  // --- Services (gateway [[services]]) ------------------------------------

  Future<String?> addService(IdrServiceEntry entry) => _services.add(entry);

  Future<String?> addServiceFromForm({
    required String name,
    required String type,
    required String endpoint,
    required String credentialMode,
    required bool requireTls,
    String? label,
  }) =>
      _services.addFromForm(
        name: name,
        type: type,
        endpoint: endpoint,
        credentialMode: credentialMode,
        requireTls: requireTls,
        label: label,
      );

  Future<void> removeService(String name) => _services.remove(name);

  Future<void> toggleService(String name) => _services.toggle(name);

  Future<List<ScanHit>> scanExposableServices() => _services.scanExposable();

  Future<int> exposeScanHits(Iterable<ScanHit> hits) =>
      _services.exposeHits(hits);

  void _onServicesChanged() {
    _publishState();
    unawaited(_reloadAgentIfRunning());
  }

  Future<void> _reloadAgentIfRunning() async {
    if (_agentStatus != AgentRuntimeStatus.running) return;
    final reg = _registrationState;
    final session = _authSession;
    final ent = _entitlement.entitlement;
    if (reg == null || session == null || ent == null) return;
    final targetId = await _identity.ensureTargetIdentity(_requireCrypto());
    await _agent.reloadConfig(
      verifiedFqhn: reg.verifiedFqhn,
      usingParty: session.email,
      entitlement: ent,
      services: services,
      targetIdentityPem: targetId.privatePem,
      targetIdentityPublicB64url: targetId.publicB64url,
      ensureFreshEntitlement: _entitlement.ensureFresh,
    );
  }

  // --- Enterprise org (local graph) ---------------------------------------

  List<EnterpriseZone> get enterpriseZones => _enterpriseOrg.zones;
  List<EnterpriseZoneAdmin> get enterpriseZoneAdmins =>
      _enterpriseOrg.zoneAdmins;
  List<EnterpriseTargetDevice> get enterpriseDevices => _enterpriseOrg.devices;

  Future<void> createZone({
    required String zoneName,
    required String adminEmail,
  }) =>
      _enterpriseOrg.createZoneWithAdmin(
        zoneName: zoneName,
        adminEmail: adminEmail,
      );

  Future<void> addEnterpriseZone({
    required List<String> path,
    required String displayName,
  }) =>
      _enterpriseOrg.addZone(path: path, displayName: displayName);

  Future<void> inviteZoneAdmin({
    required String zonePathRaw,
    required String email,
  }) =>
      _enterpriseOrg.inviteZoneAdmin(zonePathRaw: zonePathRaw, email: email);

  Future<EnterpriseTargetDevice?> addEnterpriseDevice({
    required String label,
    List<String> zonePath = const [],
  }) =>
      _enterpriseOrg.addDevice(label: label, zonePath: zonePath);

  Future<void> configureEnterpriseDeviceFqhn({
    required String deviceId,
    required String hostLabel,
    String? brandName,
  }) =>
      _enterpriseOrg.configureDeviceFqhn(
        deviceId: deviceId,
        hostLabel: hostLabel,
        brandName: brandName,
      );

  Future<void> syncEnterpriseOrgFromControlPlane() =>
      _enterpriseOrg.syncFromControlPlane();

  Future<void> signIn({bool launchAgent = true}) async {
    _setAttention(null);
    _setStatus(IdrTargetStatus.authenticating);
    try {
      _authSession = await _auth.signInWithGoogle();
      await hydrateSubscription();
      if (_authSession == null) return;
      _setStatus(IdrTargetStatus.registering);
      final existing = await _registration.load();
      if (existing != null) {
        _registrationState = existing;
        if (launchAgent) await _continueAfterRegistration();
      } else {
        _setAttention(const IdrTargetAttention(
          code: IdrTargetErrorCode.hostNotRegistered,
          message: IdrTargetMessages.hostRegistrationRequired,
        ));
      }
    } catch (e) {
      idrLog('signIn failed: $e');
      _setAttention(IdrTargetErrors.attentionFor(
        e,
        apiBase: config.controlPlaneBase,
        fallbackCode: IdrTargetErrorCode.authRequired,
        context: 'sign-in',
      ));
    }
  }

  Future<void> signOut() async {
    await stop();
    await _auth.signOut();
    await _registration.clear();
    await clearAccountUserState();
    _authSession = null;
    _registrationState = null;
    _auth.clearLoginOptions();
    _setStatus(IdrTargetStatus.signedOut);
    _setAttention(const IdrTargetAttention(
      code: IdrTargetErrorCode.authRequired,
      message: IdrTargetMessages.signedOut,
    ));
  }

  /// Whether [hostLabel] (in [zone]) is free under [entityId] (defaults to
  /// session email).
  Future<({bool available, String verifiedFqhn})> isHostAvailable({
    required String hostLabel,
    String? entityId,
    String? zone,
  }) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    return _registration.isHostAvailable(
      session: session,
      hostLabel: hostLabel,
      entityId: entityId,
      zone: zone,
    );
  }

  /// Register personal entity (email) + host label + CSR enroll.
  /// Verified FQHN is `host--entity` from the control plane.
  Future<IdrTargetRegistration> registerHost({
    required String label,
    String? payingPartyId,
    String? joinEntityId,
    String? zone,
  }) async {
    final session = _authSession;
    if (session == null) {
      throw StateError('sign in first');
    }
    _setStatus(IdrTargetStatus.registering);
    _setAttention(null);
    try {
      final withEnroll = await _registration.registerHost(
        session: session,
        label: label,
        payingPartyId: payingPartyId,
        joinEntityId: joinEntityId,
        zone: zone,
      );
      _registrationState = withEnroll;
      _publishState();

      final pullToken = withEnroll.enrollPullToken;
      if (pullToken != null) {
        await _tryPullEnrollment(pullToken);
      }
      await _continueAfterRegistration();
      return withEnroll;
    } catch (e) {
      idrLog('registerHost failed: $e');
      final attention = IdrTargetErrors.attentionFor(
        e,
        apiBase: config.controlPlaneBase,
        fallbackCode: IdrTargetErrorCode.hostNotRegistered,
        context: 'host registration',
      );
      _setAttention(attention);
      throw IdrTargetException(
        code: attention.code,
        message: attention.message,
        cause: e,
      );
    }
  }

  /// DP package for the entity root: Enterprise plans get `enterprise`
  /// (can issue zone authorities), everything else `personal`.
  String get _dpPackage => IdrBusinessPlan.fromPlanCode(_userState.planCode) ==
          IdrBusinessPlan.enterprise
      ? 'enterprise'
      : 'personal';

  /// Ensure DP entity + local admin CA keys (for Join approve).
  ///
  /// [package] defaults to the selected plan's DP package.
  Future<void> ensureAdminCa({String? entityId, String? package}) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    final id = (entityId ?? session.email).trim().toLowerCase();
    if (id.isEmpty) throw StateError('entityId required');
    await _enrollment.ensureAdminCa(
      session: session,
      entityId: id,
      ensureEmailEntity: _registrationClient.ensureEmailEntity,
      package: package ?? _dpPackage,
    );
  }

  /// Forget this machine's local root CA keys. Dev reset only: the server
  /// root must be cleared too, or the next [ensureAdminCa] cannot re-register.
  Future<void> forgetAdminCa() => _identity.clearAdminCa();

  /// Admin: list pending CSR enrollments for [entityId].
  Future<List<EnrollmentRequest>> listPendingEnrollments(
    String entityId,
  ) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    // Zone admins sign with a zone key; only the root machine has a root CA.
    if ((await _identity.loadZoneCas()).isEmpty ||
        await _identity.loadAdminCa() != null) {
      await ensureAdminCa(entityId: entityId);
    }
    final list = await _enrollment.listPending(
      session: session,
      entityId: entityId,
    );
    _publishState();
    return list;
  }

  /// Admin: reject a pending enrollment.
  Future<void> rejectEnrollment(String enrollId) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    await _enrollment.reject(session: session, enrollId: enrollId);
  }

  /// Admin: approve enrollment — signs CSR with local admin CA when PEMs omitted.
  Future<void> approveEnrollment({
    required String enrollId,
    String? entityId,
    CertSignKind kind = CertSignKind.leaf,
    String? leafPem,
    String? chainPem,
    Map<String, dynamic>? credential,
    String? issuerSki,
    Map<String, dynamic>? issuerPrivateJwk,
    String? payingPartyId,
    String? zone,
  }) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    final eid = (entityId ??
            _registrationState?.entityId ??
            session.email)
        .trim()
        .toLowerCase();
    if (eid.isEmpty) throw StateError('entityId required');
    await _enrollment.approve(
      session: session,
      enrollId: enrollId,
      entityId: eid,
      kind: kind,
      leafPem: leafPem,
      chainPem: chainPem,
      credential: credential,
      issuerSki: issuerSki,
      issuerPrivateJwk: issuerPrivateJwk,
      payingPartyId: payingPartyId ?? _registrationState?.payingPartyId,
      zone: zone,
    );
    _publishState();
    // Same device is admin and target. Sign does not dial Presence;
    // the agent starts only after this device pulls the signed enroll.
    final token = _registrationState?.enrollPullToken;
    if (token != null && token.isNotEmpty) {
      final status = await _tryPullEnrollment(token);
      if (status == 'approved') {
        await _continueAfterRegistration();
      }
    }
  }

  /// Enterprise root admin: issue the zone CA for [path] under the root and
  /// record it on the local org graph (adding the zone if needed).
  ///
  /// Nothing is added locally unless billing accepted the zone authority.
  Future<EnterpriseZone> createZoneAuthority({
    required List<String> path,
    required String displayName,
  }) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    if (IdrBusinessPlan.fromPlanCode(_userState.planCode) !=
        IdrBusinessPlan.enterprise) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.configInvalid,
        message: 'Zone certificates are an Enterprise feature.',
      );
    }
    if (path.isEmpty) throw StateError('zone path required');
    final issued = await _enrollment.issueZoneAuthority(
      session: session,
      zone: path.join('.'),
    );
    final zone = await _enterpriseOrg.attachAuthority(
      path: path,
      displayName: displayName,
      ski: issued.ski,
      issuedAt: issued.issuedAt,
    );
    _publishState();
    return zone;
  }

  /// Zones where the signed-in user has a role (from billing): `owner`,
  /// `entityId`, `zones: [{zone, exists, role, membersApprove,
  /// adminsCreateSubzones, key: {ski, status}?}]`.
  Future<Map<String, dynamic>> myZones() async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    return _enrollClient.myZones(session: session);
  }

  /// Give [email] a role in [zone]: `admin`, `member`, `none` (remove), or
  /// null (admin if the zone has none yet, else member).
  Future<Map<String, dynamic>> setZoneRole({
    required String zone,
    required String email,
    String? role,
  }) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    return _enrollClient.setZoneRole(
      session: session,
      zone: zone,
      email: email.trim().toLowerCase(),
      role: role,
    );
  }

  /// Block (or unblock) one Source on one Target; it keeps the zone's others.
  Future<Map<String, dynamic>> setTargetBlock({
    required String target,
    required String source,
    bool blocked = true,
  }) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    return _enrollClient.setTargetBlock(
      session: session,
      target: target,
      source: source,
      blocked: blocked,
    );
  }

  Future<Map<String, dynamic>> setZoneSettings({
    required String zone,
    bool? membersApprove,
    bool? adminsCreateSubzones,
  }) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    return _enrollClient.setZoneSettings(
      session: session,
      zone: zone,
      membersApprove: membersApprove,
      adminsCreateSubzones: adminsCreateSubzones,
    );
  }

  /// Zone admin: make [zone]'s key on this machine and ask the root admin to
  /// sign it (or a new sub-zone). `approved` once usable, else `pending`.
  Future<String> requestZoneKey({
    required String zone,
    required String entityId,
  }) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    return _enrollment.requestZoneKey(
      session: session,
      entityId: entityId.trim().toLowerCase(),
      zone: zone,
    );
  }

  /// Fetch [zone]'s key if the root signed it: `approved`, `rejected`,
  /// `pending`, or `none` (never asked).
  Future<String> pullZoneKey(String zone) =>
      _enrollment.pullZoneKey(zone.trim().toLowerCase());

  /// Zone keys asked for on this machine and not signed yet.
  Future<List<String>> zoneKeyRequests() => _enrollment.zoneKeyRequests();

  /// Zone CAs whose keys are held on this machine.
  Future<List<ZoneAuthority>> zoneAuthorities() =>
      _enrollment.localZoneAuthorities();

  /// Enterprise root admin: set which services zone [path]'s members may use
  /// (`['*']` = all). Re-signs the zone credential; members don't re-enroll.
  Future<({String zone, List<String> allowedServices, int policyVersion})>
      setZonePolicy({
    required List<String> path,
    required List<String> services,
  }) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    if (IdrBusinessPlan.fromPlanCode(_userState.planCode) !=
        IdrBusinessPlan.enterprise) {
      throw const IdrTargetException(
        code: IdrTargetErrorCode.configInvalid,
        message: 'Zone policies are an Enterprise feature.',
      );
    }
    return _enrollment.setZonePolicy(
      session: session,
      zone: path.join('.'),
      services: services,
    );
  }

  /// The org's active zone authorities as billing records them.
  Future<List<Map<String, dynamic>>> fetchZoneAuthorities() async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    return _enrollClient.listDelegates(session: session);
  }

  /// Enterprise owner: the org's issued credentials as billing records them.
  Future<List<Map<String, dynamic>>> listCredentials() async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    return _enrollClient.listCredentials(session: session);
  }

  /// Enterprise owner: revoke a member, Target or zone credential by [ski].
  /// Its next Presence session is denied. Refuses this machine's root CA.
  Future<({String ski, String status, String reason})> revokeCredential(
    String ski, {
    String? reason,
  }) async {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    final root = await _identity.loadAdminCa();
    if (root != null && root['issuerSki'] == ski) {
      throw ArgumentError('That is this machine\'s root CA; revoking it '
          'would cut off the whole org.');
    }
    final r = await _enrollClient.revokeCredential(
      session: session,
      ski: ski,
      reason: reason,
    );
    return (
      ski: r['ski'] as String? ?? ski,
      status: r['status'] as String? ?? 'revoked',
      reason: r['reason'] as String? ?? reason ?? 'other',
    );
  }

  /// Enterprise root admin: revoke zone [path]'s certificate. Its members
  /// are denied from their next session. The local zone CA key is dropped,
  /// so `createZoneAuthority` issues a fresh one; the zone itself stays.
  Future<({String ski, String status, String reason})> revokeZone(
    List<String> path, {
    String? reason,
  }) async {
    final key = path.join('.');
    String? ski;
    for (final z in enterpriseZones) {
      if (z.pathKey == key) ski = z.authoritySki;
    }
    ski ??= (await _identity.loadZoneCa(key))?['ski'] as String?;
    if (ski == null) {
      for (final z in await fetchZoneAuthorities()) {
        if (z['zone'] == key) ski = z['ski'] as String?;
      }
    }
    if (ski == null) throw ArgumentError('No certificate for zone $key.');
    final result = await revokeCredential(ski, reason: reason);
    await _identity.deleteZoneCa(key);
    await _enterpriseOrg.detachAuthority(path);
    _publishState();
    return result;
  }

  /// Device: poll enroll-pull using stored pull token.
  /// Returns `approved`, `rejected`, or `pending`.
  Future<String> refreshEnrollmentPull() async {
    final token = _registrationState?.enrollPullToken;
    if (token == null) return 'pending';
    return _tryPullEnrollment(token);
  }

  Future<String> _tryPullEnrollment(String pullToken) async {
    final result = await _enrollment.pull(
      pullToken: pullToken,
      registration: _registrationState,
      onRegistrationUpdated: (next) async {
        _registrationState = next;
        _publishState();
      },
    );
    return result;
  }

  /// Clear local Target enroll wait after reject (admin dual-role reset).
  Future<void> clearPendingTargetEnrollment() async {
    _registrationState =
        await _enrollment.clearPendingTargetEnrollment(_registrationState);
    _publishState();
  }

  Future<void> _continueAfterRegistration() async {
    final session = _authSession;
    final reg = _registrationState;
    if (session == null || reg == null) {
      idrLog('continue: stop — missing session/registration');
      return;
    }

    _setStatus(IdrTargetStatus.enrolling);
    final crypto = _requireCrypto();
    final machine = await _identity.ensureMachineKey(crypto);
    final targetId = await _identity.ensureTargetIdentity(crypto);
    final identity = await _identity.loadMachineIdentity();
    var credential = Map<String, dynamic>.from(
      (identity?['credential'] as Map?)?.cast<String, dynamic>() ?? {},
    );
    if (credential.isEmpty || credential['ski'] == null) {
      idrLog('continue: stop — machine credential missing SKI (enroll required)');
      _setAttention(const IdrTargetAttention(
        code: IdrTargetErrorCode.enrollmentRequired,
        message: IdrTargetMessages.enrollmentRequired,
      ));
      return;
    }
    credential['host'] = reg.verifiedFqhn;
    credential['publicJwk'] ??= machine.publicJwk;
    credential['entityId'] ??= reg.entityId;
    final signed = await _enrollment.ensureSignedMachineCredential(credential);
    if (!identical(signed, credential)) {
      credential = signed;
      await _identity.saveMachineIdentity(
        privatePem: machine.privatePem,
        publicB64url: machine.publicB64url,
        publicJwk: machine.publicJwk,
        credential: credential,
        fqhn: reg.verifiedFqhn,
        ski: credential['ski'] as String?,
      );
    }

    if (!EnrollmentManager.isCompleteMachineCredential(credential)) {
      idrLog('continue: stop — incomplete machine credential (enroll required)');
      _setAttention(const IdrTargetAttention(
        code: IdrTargetErrorCode.enrollmentRequired,
        message: IdrTargetMessages.enrollmentRequired,
      ));
      return;
    }

    _setStatus(IdrTargetStatus.authenticating);
    try {
      await _entitlement.mint(
        credential: credential,
        privatePem: machine.privatePem,
        targetIdentityB64url: targetId.publicB64url,
        sessionCookie: session.sessionCookie,
      );
    } catch (e) {
      idrLog('agent token mint failed: $e');
      _setAttention(IdrTargetErrors.attentionFor(
        e,
        apiBase: config.controlPlaneBase,
        fallbackCode: IdrTargetErrorCode.enrollmentRequired,
        context: 'entitlement',
      ));
      return;
    }

    final ent = _entitlement.entitlement!;
    if (ent.targetFqhn != null && ent.targetFqhn != reg.verifiedFqhn) {
      idrLog(
        'continue: stop — FQHN mismatch jwt=${ent.targetFqhn} '
        'reg=${reg.verifiedFqhn}',
      );
      _setAttention(IdrTargetAttention(
        code: IdrTargetErrorCode.fqhnUnverified,
        message: IdrTargetMessages.fqhnUnverified(
          ent.targetFqhn!,
          reg.verifiedFqhn,
        ),
      ));
      return;
    }

    _entitlement.startRefresher(
      credential: credential,
      privatePem: machine.privatePem,
      targetIdentityB64url: targetId.publicB64url,
      sessionCookie: session.sessionCookie,
      onRefreshed: _agent.applyFreshEntitlement,
    );

    await ensureTls();
    idrLog('continue: starting target-agent for ${reg.verifiedFqhn}');
    await _startAgent();
  }

  /// Phase 1: skip leaf for native `*.idr.to`. Phase 2: Entity-CA when enabled.
  Future<void> ensureTls() async {
    final reg = _registrationState;
    final session = _authSession;
    if (reg == null) return;

    _setStatus(IdrTargetStatus.securingTls);
    final crypto = _requireCrypto();
    final certDir = config.tls.certDir ?? p.join(configDir.path, 'certs');
    _certs = CertificateManager(
      crypto: crypto,
      terminator: config.tls.terminator,
      certDir: certDir,
      apiBaseUrl: config.controlPlaneBase,
    );

    if (_certs!.isNativeIdrFqhn(reg.verifiedFqhn) &&
        !config.tls.enableEntityCaLeaf) {
      final s = await _certs!.ensurePhase1Native(reg.verifiedFqhn);
      _setTls(s);
      return;
    }

    if (config.tls.enableEntityCaLeaf && session != null) {
      try {
        var pem = await _identity.loadTlsPrivatePem();
        if (pem == null || pem.isEmpty) {
          final mat = crypto.generateEd25519();
          pem = mat.privatePem;
          await _identity.saveTlsPrivatePem(pem);
        }
        final s = await _certs!.ensureEntityCaLeaf(
          session: session,
          registration: reg,
          privatePem: pem,
        );
        _setTls(s);
      } catch (e) {
        _setTls(IdrTlsStatus.needsAttention);
        _setAttention(_certs!.attentionForError(e));
      }
      return;
    }

    _setTls(IdrTlsStatus.notRequired);
  }

  Future<void> _startAgent() async {
    final reg = _registrationState;
    final session = _authSession;
    final ent = _entitlement.entitlement;
    if (reg == null || session == null || ent == null) {
      idrLog(
        'startAgent: stop — reg=${reg != null} session=${session != null} '
        'ent=${ent != null}',
      );
      return;
    }

    idrLog(
      'startAgent: fqhn=${reg.verifiedFqhn} discovery=${config.discoveryUrl}',
    );
    final targetId = await _identity.ensureTargetIdentity(_requireCrypto());
    await _agent.start(
      verifiedFqhn: reg.verifiedFqhn,
      usingParty: session.email,
      entitlement: ent,
      services: services,
      targetIdentityPem: targetId.privatePem,
      targetIdentityPublicB64url: targetId.publicB64url,
      dpIdentityJson: await _identity.loadAgentDeviceIdentityJson(),
      ensureFreshEntitlement: _entitlement.ensureFresh,
    );
    idrLog('startAgent: agent status=${_agent.status}');
  }

  /// Verified custom domains for [targetFqhn]; empty (ACME off) when billing
  /// can't say, so a billing hiccup never blocks the agent.
  Future<List<String>> _verifiedCustomDomains(String targetFqhn) async {
    final session = _authSession;
    if (session == null) return const [];
    try {
      final domains = await _customDomainClient.verifiedDomains(
        session: session,
        targetFqhn: targetFqhn,
      );
      if (domains.isNotEmpty) idrLog('agent: ACME for $domains');
      return domains;
    } catch (e) {
      idrLog('agent: no custom domains for ACME ($e)');
      return const [];
    }
  }

  // ---------------------------------------------------------------------------
  // Custom domains (customer CNAME → this Target; Let's Encrypt via the agent)
  // ---------------------------------------------------------------------------

  ({IdrAuthSession session, String fqhn}) _registeredTarget() {
    final session = _authSession;
    if (session == null) throw StateError('sign in first');
    final fqhn = registration?.verifiedFqhn;
    if (fqhn == null || fqhn.isEmpty) {
      throw StateError('register this machine as a Target first');
    }
    return (session: session, fqhn: fqhn);
  }

  /// Add [domain] to this Target. Billing returns the CNAME target to give
  /// the customer and the first check result. Owners / admins of the bound org.
  Future<CustomDomain> addCustomDomain(String domain) {
    final t = _registeredTarget();
    return _customDomainClient.add(
      session: t.session,
      targetFqhn: t.fqhn,
      domain: domain,
    );
  }

  /// This Target's custom domains (removed ones left out).
  Future<List<CustomDomain>> customDomains() {
    final t = _registeredTarget();
    return _customDomainClient.list(session: t.session, targetFqhn: t.fqhn);
  }

  /// Check [domain]'s CNAME now. A newly verified domain gets its certificate
  /// on the agent's next start.
  Future<CustomDomain> verifyCustomDomain(String domain) async {
    final d = await _customDomainNamed(domain);
    return _customDomainClient.verify(
        session: _registeredTarget().session, id: d.id);
  }

  Future<CustomDomain> removeCustomDomain(String domain) async {
    final d = await _customDomainNamed(domain);
    return _customDomainClient.remove(
        session: _registeredTarget().session, id: d.id);
  }

  Future<CustomDomain> _customDomainNamed(String domain) async {
    final want = domain.trim().toLowerCase().replaceAll(RegExp(r'\.$'), '');
    for (final d in await customDomains()) {
      if (d.domain == want) return d;
    }
    throw CustomDomainException(
        404, 'NOT_FOUND', '$want is not on this Target.');
  }

  /// The agent's Let's Encrypt status for [domain] (null before its first try).
  AcmeDomainStatus? acmeStatus(String domain) {
    final file =
        File(p.join(acmeCertDir(configDir), domain, 'acme-status.json'));
    if (!file.existsSync()) return null;
    try {
      return AcmeDomainStatus.fromJson(
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> stop() async {
    await _agent.stop();
    _entitlement.stop();
    _agentStatus = AgentRuntimeStatus.stopped;
    _setStatus(IdrTargetStatus.stopped);
  }

  Future<void> dispose() async {
    await stop();
    await _agent.dispose();
    await _authClient.dispose();
    await _statusCtrl.close();
    await _attentionCtrl.close();
    await _tlsCtrl.close();
    await _stateCtrl.close();
  }
}
