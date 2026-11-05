import 'dart:async';

import 'package:idr_service_http/idr_service_http.dart' show ChatTurn;
import 'package:idr_session/idr_session.dart';
import 'package:two_key_dart_sdk/two_key_headless.dart';

import 'auth/auth_manager.dart';
import 'catalog/service_selection.dart';
import 'config.dart';
import 'connection/connection_manager.dart';
import 'errors.dart';
import 'identity/source_identity_manager.dart';
import 'library_path.dart';
import 'prefs/source_prefs.dart';
import 'services/chat_gateway.dart';
import 'state/ready_step.dart';
import 'state/source_state.dart';

/// Production Source facade — billing SSO, Presence/WebRTC, Target services.
class IdrSource {
  /// [authStorage] defaults to a JSON file (CLI); Flutter apps pass
  /// `SecureBillingAuthStorage(storagePrefix: IdrSource.storagePrefix)`.
  IdrSource({
    required this.config,
    BillingAuthStorage? authStorage,
    LoopbackAuthSessionLauncher? launcher,
    SourcePrefs? prefs,
    BillingAuthClient? authClient,
  }) : _prefs = prefs {
    final storage = authStorage ?? FileAuthStorage();
    final loopback = launcher ?? LoopbackAuthSessionLauncher();
    _authClient = authClient ??
        BillingAuthClient(
          billingBaseUrl: config.apiBase,
          deepLinkScheme: 'idr',
          storagePrefix: storagePrefix,
          storage: storage,
          sessionLauncher: loopback.call,
          nativeSignIn: true, // GET /api/auth/native/sign-in/social, no proxy link
        );
    _authClient.setOnline(false);
    _auth = AuthManager(
      client: _authClient,
      storage: storage,
      launcher: loopback,
    );
    _identity = SourceIdentityManager(
      storage: storage,
      enroll: DelegatePermissionsClient(
        billingBaseUrl: config.apiBase,
        sessionCookie: _authClient.getSessionCookie,
        // Billing serves these routes behind requireBillingAuth (Bearer JWT).
        accessToken: () async => _accessToken(await _ensureAuthSession()),
      ),
      // Enroll crypto: the manager's default, idr_dp (IDR_DP_LIB → next to
      // the exe → walk up). idr_c_api is WebRTC only; it has no idr_dp_* ABI.
    );
    _connection = ConnectionManager(config);
    _chat = ChatGateway();
  }

  static const storagePrefix = 'idr.source.auth';

  final IdrSourceConfig config;
  final SourcePrefs? _prefs;
  late final BillingAuthClient _authClient;
  late final AuthManager _auth;
  late final SourceIdentityManager _identity;
  late final ConnectionManager _connection;
  late final ChatGateway _chat;

  final _stateCtrl = StreamController<SourceState>.broadcast();
  SourceState _state = const SourceState(ready: SignedOut());
  ServiceSelection? _activeSelection;

  SourceState get state => _state;
  Stream<SourceState> get stateStream => _stateCtrl.stream;

  /// Resolved native library path (after connect / doctor probe).
  String? get resolvedLibraryPath =>
      _connection.lastResolvedLibraryPath ??
      resolveLibraryPath(config.libraryPath);

  void _publish({
    SourceReadyStep? ready,
    IdrAuthSession? session,
    String? fqhn,
    bool? connected,
    List<ServiceSelection>? services,
    String? activeService,
    List<String>? models,
    String? activeModel,
    SourceAttention? attention,
    bool clearSession = false,
    bool clearFqhn = false,
    bool clearActiveService = false,
    bool clearActiveModel = false,
    bool clearAttention = false,
  }) {
    _state = _state.copyWith(
      ready: ready,
      session: session,
      fqhn: fqhn,
      connected: connected,
      services: services,
      activeService: activeService,
      models: models,
      activeModel: activeModel,
      attention: attention,
      clearSession: clearSession,
      clearFqhn: clearFqhn,
      clearActiveService: clearActiveService,
      clearActiveModel: clearActiveModel,
      clearAttention: clearAttention,
    );
    if (!_stateCtrl.isClosed) {
      _stateCtrl.add(_state);
    }
  }

  SourceReadyStep _computeReady({
    IdrAuthSession? session,
    bool? connected,
    String? activeService,
  }) {
    final s = session ?? _state.session;
    if (s == null) return const SignedOut();
    final live = connected ?? _state.connected;
    final active = activeService ?? _state.activeService;
    if (!live) return const SignedIn();
    if (active != null && active.isNotEmpty) return const ServiceActive();
    return const Connected();
  }

  /// Restore billing session and load prefs (last FQHN / active names).
  Future<void> start() async {
    final session = await _auth.restore();
    final lastFqhn = await _prefs?.lastFqhn;
    final activeService = await _prefs?.activeService;
    final activeModel = await _prefs?.activeModel;
    _publish(
      session: session,
      clearSession: session == null,
      fqhn: lastFqhn,
      clearFqhn: lastFqhn == null || lastFqhn.isEmpty,
      activeService: activeService,
      clearActiveService: activeService == null || activeService.isEmpty,
      activeModel: activeModel,
      clearActiveModel: activeModel == null || activeModel.isEmpty,
      connected: false,
      ready: _computeReady(
        session: session,
        connected: false,
        activeService: activeService,
      ),
      clearAttention: true,
    );
  }

  /// Billing Google SSO. [force] re-runs login even if already signed in.
  Future<IdrAuthSession> login({bool force = false}) async {
    if (!force && _state.session != null) {
      return _state.session!;
    }
    try {
      final session = await _auth.login();
      _publish(
        session: session,
        ready: _computeReady(session: session),
        clearAttention: true,
      );
      return session;
    } on IdrSourceException catch (e) {
      _publish(
        attention: SourceAttention(code: e.code, message: e.message),
      );
      rethrow;
    }
  }

  /// Bind this sign-in to billing org [slug] (`me` = personal) so enrollment
  /// lands in that org's inbox. Billing files enrollments under the token's
  /// org, not the Target entity. Needs membership in the org.
  Future<({String slug, String name, String role})> bindOrganization(
    String slug,
  ) async {
    await _ensureAuthSession();
    try {
      final bound = await _auth.bindOrganization(slug.trim());
      _publish(session: bound.session, clearAttention: true);
      return (slug: bound.slug, name: bound.name, role: bound.role);
    } on IdrSourceException catch (e) {
      _publish(attention: SourceAttention(code: e.code, message: e.message));
      rethrow;
    }
  }

  /// Enroll this machine as a `machine_source` device for the Target at
  /// [fqhn] (defaults to last FQHN). Returns the Source locator `label--entity`.
  /// Throws `ENROLLMENT_PENDING` until the Target Admin approves.
  Future<String> enroll({
    String? fqhn,
    String? sourceLabel,
    String? zone,
  }) async {
    await _ensureAuthSession();
    final target = (fqhn ?? _state.fqhn ?? await _prefs?.lastFqhn)?.trim();
    if (target == null || target.isEmpty) {
      throw const IdrSourceException(
        code: 'ENROLL_FAILED',
        message: 'Target FQHN is required to enroll.',
      );
    }
    try {
      final host = await _identity.enroll(
        targetFqhn: target,
        sourceLabel: sourceLabel,
        zone: zone,
      );
      await _prefs?.setLastFqhn(target);
      _publish(fqhn: target, clearAttention: true);
      return host;
    } on IdrSourceException catch (e) {
      _publish(attention: SourceAttention(code: e.code, message: e.message));
      rethrow;
    }
  }

  /// Approved Source device locator, or null if not enrolled yet.
  Future<String?> enrolledSourceHost() async =>
      await _identity.approvedIdentityJson() == null
          ? null
          : _identity.enrolledHost();

  /// Sign out. The enrolled device identity stays, so signing back in needs
  /// no re-enroll; [forgetDevice] removes it.
  Future<void> logout({bool forgetDevice = false}) async {
    await _connection.disconnect();
    await _auth.logout();
    if (forgetDevice) await this.forgetDevice();
    _activeSelection = null;
    await _prefs?.setLastFqhn(null);
    await _prefs?.setActiveService(null);
    await _prefs?.setActiveModel(null);
    _publish(
      clearSession: true,
      clearFqhn: true,
      clearActiveService: true,
      clearActiveModel: true,
      connected: false,
      services: const [],
      models: const [],
      ready: const SignedOut(),
      clearAttention: true,
    );
  }

  /// Delete this machine's Source key and certificate (e.g. before handing
  /// the machine over). The next [enroll] creates a new device for the admin
  /// to approve; the old credential stays on billing until an admin revokes it.
  Future<void> forgetDevice() async {
    await _connection.disconnect();
    await _identity.clear();
  }

  /// Connect via Presence/WebRTC. Saves last FQHN; loads service catalog.
  Future<void> connect([String? fqhn]) async {
    final session = await _ensureAuthSession();
    final target = (fqhn ?? _state.fqhn ?? await _prefs?.lastFqhn)?.trim();
    if (target == null || target.isEmpty) {
      throw const IdrSourceException(
        code: 'CONNECT_FAILED',
        message: 'Target FQHN is required (pass an argument or connect once).',
      );
    }

    final token = await _accessToken(session);
    try {
      // Approved machine_source identity → mTLS; otherwise bearer-only
      // (anonymous Source, Service Provider targets).
      await _connection.connect(
        authToken: token,
        sourceId: session.email.isNotEmpty ? session.email : 'dart',
        fqhn: target,
        dpIdentityJson: await _identity.approvedIdentityJson(),
      );
      final connectedFqhn = _connection.fqhn ?? target;
      await _prefs?.setLastFqhn(connectedFqhn);

      final catalog = await _connection.listNamedServiceCatalog();
      final services = ServiceSelection.fromCatalogEntries(catalog);

      final preferred = ServiceSelection.named(
        services,
        _state.activeService ?? await _prefs?.activeService,
      );
      _activeSelection = preferred;
      final activeName = preferred?.name;

      _publish(
        session: session,
        fqhn: connectedFqhn,
        connected: true,
        services: services,
        activeService: activeName,
        clearActiveService: activeName == null,
        models: const [],
        clearActiveModel: preferred == null,
        ready: _computeReady(
          session: session,
          connected: true,
          activeService: activeName,
        ),
        clearAttention: true,
      );

      if (preferred != null) {
        try {
          await activate(preferred.name);
        } catch (e) {
          _publish(
            attention: SourceAttention(
              code: 'ACTIVATE_FAILED',
              message: 'Connected, but activate failed: $e',
            ),
          );
        }
      }
    } on IdrSourceException catch (e) {
      _publish(
        connected: false,
        ready: _computeReady(session: session, connected: false),
        attention: SourceAttention(code: e.code, message: e.message),
      );
      rethrow;
    }
  }

  Future<void> disconnect() async {
    await _connection.disconnect();
    _activeSelection = null;
    _publish(
      connected: false,
      services: const [],
      models: const [],
      clearActiveService: true,
      clearActiveModel: true,
      ready: _computeReady(connected: false, activeService: null),
      clearAttention: true,
    );
  }

  /// If already connected, return. Else connect using [fqhn] or prefs.lastFqhn.
  Future<void> ensureConnected([String? fqhn]) async {
    if (_connection.isConnected) return;
    await connect(fqhn);
  }

  Future<List<ServiceSelection>> listServices() async {
    await ensureConnected();
    final catalog = await _connection.listNamedServiceCatalog();
    var services = ServiceSelection.fromCatalogEntries(catalog);
    if (services.isEmpty) {
      services = List.of(_state.services);
    }
    _publish(
      services: services,
      ready: _computeReady(connected: true),
      clearAttention: true,
    );
    return services;
  }

  /// Activate a named catalog service and load models.
  Future<void> activate(String name, {String? model}) async {
    await ensureConnected();
    final services =
        _state.services.isEmpty ? await listServices() : _state.services;

    final found = ServiceSelection.named(services, name) ??
        ServiceSelection.fromAdvertisedName(name.trim());
    _activeSelection = found;

    await _prefs?.setActiveService(found.name);

    final models = await listModels();
    var activeModel = model?.trim();
    if (activeModel != null && activeModel.isEmpty) activeModel = null;
    activeModel ??= await _prefs?.activeModel;
    if (activeModel == null ||
        (models.isNotEmpty && !models.contains(activeModel))) {
      activeModel = models.isNotEmpty ? models.first : null;
    }
    await _prefs?.setActiveModel(activeModel);

    _publish(
      activeService: found.name,
      models: models,
      activeModel: activeModel,
      clearActiveModel: activeModel == null,
      ready: _computeReady(
        connected: true,
        activeService: found.name,
      ),
      clearAttention: true,
    );
  }

  Future<List<String>> listModels() async {
    await ensureConnected();
    final session = _connection.session;
    final service = _requireActiveService();
    if (session == null) {
      throw const IdrSourceException(
        code: 'NOT_CONNECTED',
        message: 'Not connected to a Target.',
      );
    }
    try {
      final models = await _chat.listModels(session: session, service: service);
      _publish(models: models, clearAttention: true);
      return models;
    } catch (e) {
      throw IdrSourceException(
        code: 'MODELS_FAILED',
        message: 'Failed to list models: $e',
        cause: e,
      );
    }
  }

  /// Chat against the active service. Caller owns [history].
  ///
  /// When [onDelta] is set: Ollama streams tokens; OpenAI-compatible services
  /// (LM Studio, HF, …) deliver the full reply as a single delta.
  ///
  /// [onDelta] may be async; each invocation is awaited so IO (e.g. stdout.flush)
  /// finishes before the next write.
  Future<String> chat(
    String prompt, {
    List<ChatTurn> history = const [],
    Future<void> Function(String delta)? onDelta,
  }) async {
    await ensureConnected();
    final session = _connection.session;
    final service = _requireActiveService();
    final model = _state.activeModel;
    if (session == null) {
      throw const IdrSourceException(
        code: 'NOT_CONNECTED',
        message: 'Not connected to a Target.',
      );
    }
    if (model == null || model.isEmpty) {
      throw const IdrSourceException(
        code: 'MODEL_REQUIRED',
        message: 'No active model. Run activate / listModels first.',
      );
    }
    try {
      return await _chat.chat(
        session: session,
        service: service,
        model: model,
        prompt: prompt,
        history: history,
        onDelta: onDelta,
      );
    } catch (e) {
      if (e is IdrSourceException) rethrow;
      throw IdrSourceException(
        code: 'CHAT_FAILED',
        message: 'Chat failed: $e',
        cause: e,
      );
    }
  }

  Future<IdrAuthSession> _ensureAuthSession() async {
    var session = _state.session;
    if (session == null) {
      session = await _auth.restore();
      if (session == null) {
        throw const IdrSourceException(
          code: 'AUTH_REQUIRED',
          message: 'Sign in first (login).',
        );
      }
      _publish(
        session: session,
        ready: _computeReady(session: session),
      );
    }
    return session;
  }

  Future<String> _accessToken(IdrAuthSession session) async {
    var current = session;
    if (current.accessTokenLikelyExpired) {
      final refreshed = await _auth.refreshAccessToken(current);
      if (refreshed != null) {
        current = refreshed;
        _publish(session: current);
      }
    }
    if (current.token.isEmpty) {
      throw const IdrSourceException(
        code: 'AUTH_REQUIRED',
        message: 'Access token missing. Sign in again.',
      );
    }
    return current.token;
  }

  ServiceSelection _requireActiveService() {
    final sel = _activeSelection;
    if (sel != null) return sel;
    final name = _state.activeService;
    if (name == null || name.isEmpty) {
      throw const IdrSourceException(
        code: 'SERVICE_REQUIRED',
        message: 'No active service. Call activate(name) first.',
      );
    }
    final inferred = ServiceSelection.named(_state.services, name) ??
        ServiceSelection.fromAdvertisedName(name);
    _activeSelection = inferred;
    return inferred;
  }

  Future<void> dispose() async {
    await _connection.disconnect();
    await _authClient.dispose();
    await _stateCtrl.close();
  }
}
