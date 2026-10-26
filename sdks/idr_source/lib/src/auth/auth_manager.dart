import 'dart:convert';

import 'package:idr_session/idr_session.dart';
import 'package:two_key_dart_sdk/two_key_headless.dart';

import '../errors.dart';

/// Source auth over [BillingAuthClient]: Google SSO via loopback redirect,
/// billing API JWT mint, cached [IdrAuthSession]. Holds no connection state.
class AuthManager {
  AuthManager({
    required BillingAuthClient client,
    required BillingAuthStorage storage,
    required LoopbackAuthSessionLauncher launcher,
    this.provider = 'google',
  })  : _client = client,
        _storage = storage,
        _launcher = launcher;

  static const _sessionKey = 'idr.source.session';

  final BillingAuthClient _client;
  final BillingAuthStorage _storage;
  final LoopbackAuthSessionLauncher _launcher;
  final String provider;

  Future<IdrAuthSession?> restore() async {
    final raw = await _storage.getItem(_sessionKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return IdrAuthSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      await _storage.removeItem(_sessionKey);
      return null;
    }
  }

  Future<IdrAuthSession> login() async {
    try {
      final session = await signInLoopback(
        client: _client,
        launcher: _launcher,
        provider: provider,
      );
      if (session == null) {
        throw const IdrSourceException(
          code: 'AUTH_FAILED',
          message: 'Sign-in did not complete (browser closed or timed out).',
        );
      }
      await _save(session);
      return session;
    } on BillingAuthException catch (e) {
      throw IdrSourceException(
          code: 'AUTH_FAILED', message: e.message, cause: e);
    }
  }

  Future<void> logout() async {
    try {
      await _client.signOut();
    } on BillingAuthException {
      // Local sign-out still proceeds when the server is unreachable.
    }
    await _client.clearLocalAuthSession();
    await _storage.removeItem(_sessionKey);
  }

  /// Bind the Better Auth session to billing org [slug] (`me` = personal),
  /// then re-mint the JWT so billing calls (enroll) are scoped to that org.
  /// The binding is server-side: later re-mints keep it until the next login.
  Future<({IdrAuthSession session, String slug, String name, String role})>
      bindOrganization(String slug) async {
    final ({String organizationId, String slug, String name, String role}) org;
    try {
      org = await _client.bindOrganization(slug: slug);
    } on BillingAuthException catch (e) {
      final text = '${e.code ?? ''} ${e.message}'.toLowerCase();
      throw IdrSourceException(
        code: text.contains('not_a_member') || text.contains('not a member')
            ? 'NOT_A_MEMBER'
            : e.statusCode == 404 || text.contains('not_found')
                ? 'ORG_NOT_FOUND'
                : 'BIND_FAILED',
        message: e.message,
        cause: e,
      );
    }
    final session = await _mintAndSave();
    if (session == null) {
      throw const IdrSourceException(
        code: 'AUTH_REQUIRED',
        message: 'Session expired. Sign in again (idr login --force).',
      );
    }
    return (session: session, slug: org.slug, name: org.name, role: org.role);
  }

  /// Re-mint the billing JWT from the live Better Auth session; null if signed out.
  Future<IdrAuthSession?> refreshAccessToken(IdrAuthSession _) =>
      _mintAndSave();

  Future<IdrAuthSession?> _mintAndSave() async {
    try {
      final session = await mintIdrSession(_client);
      if (session != null) await _save(session);
      return session;
    } on BillingAuthException catch (e) {
      throw IdrSourceException(
          code: 'AUTH_REFRESH_FAILED', message: e.message, cause: e);
    }
  }

  Future<void> _save(IdrAuthSession session) =>
      _storage.setItem(_sessionKey, jsonEncode(session.toJson()));
}
