import '../auth/auth.dart';
import '../crypto/idr_crypto.dart';
import 'agent_token_client.dart';
import 'token_refresher.dart';

/// Agent entitlement JWT mint + [TokenRefresher] lifecycle.
class EntitlementManager {
  EntitlementManager({
    required this.apiBaseUrl,
    required this.store,
    required IdrCrypto Function() requireCrypto,
  }) : _requireCrypto = requireCrypto;

  final String apiBaseUrl;
  final SessionStore store;
  final IdrCrypto Function() _requireCrypto;

  AgentTokenClient? _client;
  TokenRefresher? _refresher;
  EntitlementToken? entitlement;

  AgentTokenClient clientFor(IdrCrypto crypto) {
    _client ??= AgentTokenClient(
      apiBaseUrl: apiBaseUrl,
      store: store,
      crypto: crypto,
    );
    return _client!;
  }

  Future<EntitlementToken> mint({
    required Map<String, dynamic> credential,
    required String privatePem,
    required String targetIdentityB64url,
    String? sessionCookie,
  }) async {
    final crypto = _requireCrypto();
    final client = clientFor(crypto);
    entitlement = await client.mint(
      credential: credential,
      privatePem: privatePem,
      targetIdentityB64url: targetIdentityB64url,
      sessionCookie: sessionCookie,
    );
    return entitlement!;
  }

  void startRefresher({
    required Map<String, dynamic> credential,
    required String privatePem,
    required String targetIdentityB64url,
    String? sessionCookie,
    Future<void> Function(EntitlementToken token)? onRefreshed,
  }) {
    final crypto = _requireCrypto();
    final client = clientFor(crypto);
    _refresher?.stop();
    _refresher = TokenRefresher(
      client: client,
      mint: () async {
        final t = await client.mint(
          credential: credential,
          privatePem: privatePem,
          targetIdentityB64url: targetIdentityB64url,
          sessionCookie: sessionCookie,
        );
        entitlement = t;
        return t;
      },
      onRefreshed: onRefreshed,
    );
    if (entitlement != null) {
      _refresher!.start(entitlement!);
    }
  }

  Future<EntitlementToken?> ensureFresh() async {
    final fresh = await _refresher?.ensureFresh();
    if (fresh != null) entitlement = fresh;
    return fresh;
  }

  void stop() {
    _refresher?.stop();
    _refresher = null;
  }
}
