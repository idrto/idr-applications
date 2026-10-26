import 'package:idr_session/idr_session.dart';
import 'package:two_key_dart_sdk/two_key_headless.dart';

import '../errors.dart';
import 'login_options.dart';
import 'session_store.dart';

/// Auth workflows over the billing SDK [BillingAuthClient]. Holds no Target status.
class AuthManager {
  AuthManager({
    required BillingAuthClient client,
    required SessionStore store,
    required LoopbackAuthSessionLauncher launcher,
  })  : _client = client,
        _store = store,
        _launcher = launcher;

  final BillingAuthClient _client;
  final SessionStore _store;
  final LoopbackAuthSessionLauncher _launcher;

  IdrLoginOptions? loginOptions;

  /// Cached session; refreshed from the live Better Auth session when possible.
  Future<IdrAuthSession?> restore() async {
    final saved = await _store.loadSession();
    if (saved == null) return null;
    try {
      return await _mint() ?? saved;
    } catch (_) {
      // Never clear here — wiping on refresh failure forced SignIn every launch.
      return saved;
    }
  }

  Future<IdrAuthSession> signInWithGoogle() async {
    try {
      final session = await signInLoopback(client: _client, launcher: _launcher);
      if (session == null) {
        throw const IdrTargetException(
          code: IdrTargetErrorCode.networkUnavailable,
          message: IdrTargetErrorMessages.signInTimeout,
        );
      }
      await _store.saveSession(session);
      return session;
    } on BillingAuthException catch (e) {
      throw _toTarget(e, IdrTargetErrorCode.authRequired);
    }
  }

  Future<void> signOut() async {
    try {
      await _client.signOut();
    } on BillingAuthException {
      // Local sign-out still proceeds when the server is unreachable.
    }
    await _client.clearLocalAuthSession();
    await _store.clearSession();
  }

  /// Configured sign-in methods (`GET /api/auth/.well-known/oauth-providers`).
  Future<IdrLoginOptions> fetchLoginOptions({
    required String apiBase,
    bool force = false,
  }) async {
    if (!force && loginOptions != null) return loginOptions!;
    try {
      final options =
          IdrLoginOptions.fromDiscovery(await _client.fetchOAuthProviders());
      if (options.isEmpty) {
        throw const IdrTargetException(
          code: IdrTargetErrorCode.configInvalid,
          message: IdrTargetErrorMessages.noLoginProviders,
        );
      }
      loginOptions = options;
      return options;
    } on IdrTargetException {
      rethrow;
    } catch (e) {
      final attention = IdrTargetErrors.attentionFor(
        e,
        apiBase: apiBase,
        fallbackCode: IdrTargetErrorCode.configInvalid,
        context: 'login-options',
      );
      throw IdrTargetException(
        code: attention.code,
        message: attention.message,
        cause: e,
      );
    }
  }

  void clearLoginOptions() => loginOptions = null;

  /// Bind the session to org [slug] (`me` = personal) and re-mint the API JWT
  /// so billing calls are scoped to that org.
  Future<({IdrAuthSession session, String slug, String name, String role})>
      bindOrganization(String slug) async {
    try {
      final org = await _client.bindOrganization(slug: slug);
      final session = await _mint();
      if (session == null) {
        throw const IdrTargetException(
          code: IdrTargetErrorCode.authRequired,
          message: IdrTargetErrorMessages.authRequired,
        );
      }
      return (
        session: session,
        slug: org.slug,
        name: org.name,
        role: org.role,
      );
    } on BillingAuthException catch (e) {
      throw _toTarget(e, IdrTargetErrorCode.authInvalid);
    }
  }

  Future<List<OrgMember>> listOrganizationMembers() =>
      _org(() => _client.listOrganizationMembers());

  Future<List<OrgInvitation>> listOrganizationInvitations() =>
      _org(() => _client.listOrganizationInvitations());

  Future<void> inviteOrganizationMember({
    required String email,
    String role = 'member',
  }) =>
      _org(() => _client.inviteOrganizationMember(email: email, role: role));

  Future<void> updateOrganizationMemberRole({
    required String memberId,
    required String role,
  }) =>
      _org(() => _client.updateOrganizationMemberRole(
            memberId: memberId,
            role: role,
          ));

  Future<void> removeOrganizationMember({required String memberIdOrEmail}) =>
      _org(() =>
          _client.removeOrganizationMember(memberIdOrEmail: memberIdOrEmail));

  Future<T> _org<T>(Future<T> Function() run) async {
    try {
      return await run();
    } on BillingAuthException catch (e) {
      throw _toTarget(e, IdrTargetErrorCode.authInvalid);
    }
  }

  Future<IdrAuthSession?> _mint() async {
    final session = await mintIdrSession(_client);
    if (session == null) return null;
    await _store.saveSession(session);
    return session;
  }

  static IdrTargetException _toTarget(
    BillingAuthException e,
    IdrTargetErrorCode fallback,
  ) =>
      IdrTargetException(
        code: IdrTargetErrorCode.tryParse(e.code ?? '') ?? fallback,
        message: e.message,
        cause: e,
      );
}
