import 'dart:async';

import 'agent_token_client.dart';

/// Refresh entitlement JWT before expiry.
class TokenRefresher {
  TokenRefresher({
    required this.client,
    required this.mint,
    this.refreshSkew = const Duration(minutes: 5),
    this.onRefreshed,
  });

  final AgentTokenClient client;
  final Future<EntitlementToken> Function() mint;
  final Duration refreshSkew;
  final Future<void> Function(EntitlementToken token)? onRefreshed;

  Timer? _timer;
  EntitlementToken? current;

  void start(EntitlementToken token) {
    current = token;
    _timer?.cancel();
    final delay = refreshDelay(token.expiresAt, skew: refreshSkew);
    _timer = Timer(delay, () async {
      try {
        current = await mint();
        await onRefreshed?.call(current!);
        start(current!);
      } catch (_) {
        // Facade maps to needsAttention.
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<EntitlementToken> ensureFresh() async {
    final cached = current ?? await client.loadCached();
    if (cached != null && !cached.shouldRefresh(skew: refreshSkew)) {
      current = cached;
      return cached;
    }
    final t = await mint();
    start(t);
    return t;
  }
}

/// Wait until [expiresAt] minus [skew], but never fire immediately after mint.
/// Default skew is 5 minutes; agent JWTs default to 5 minutes, which used to
/// schedule `Duration.zero` and restart the agent in a tight loop.
Duration refreshDelay(
  DateTime expiresAt, {
  Duration skew = const Duration(minutes: 5),
  DateTime? now,
}) {
  final n = now ?? DateTime.now().toUtc();
  final ttl = expiresAt.difference(n);
  if (ttl <= Duration.zero) {
    return const Duration(seconds: 15);
  }
  var wait = expiresAt.subtract(skew).difference(n);
  if (wait < const Duration(seconds: 15)) {
    final half = Duration(milliseconds: ttl.inMilliseconds ~/ 2);
    wait = half < const Duration(seconds: 15)
        ? const Duration(seconds: 15)
        : half;
  }
  return wait;
}
