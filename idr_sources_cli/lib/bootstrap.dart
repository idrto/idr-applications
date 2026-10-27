import 'package:idr_cli_core/idr_cli_core.dart';
import 'package:idr_source/idr_source.dart';

import 'prefs/cli_prefs.dart';

const idrVersion = '0.2.0';
const idrSourceVersion = '0.1.0';

/// Restore state, run [body], always dispose (closes any live connection).
Future<T> withSource<T>(Future<T> Function(IdrSource source) body) async {
  final source = IdrSource(
    config: IdrSourceConfig.defaults(IdrSourceMode.development),
    prefs: createCliPrefs(),
  );
  try {
    await source.start();
    return await body(source);
  } finally {
    await source.dispose();
  }
}

/// Fails before any prompt when there is no session to use.
void requireSignedIn(IdrSource source) {
  if (source.state.session == null) {
    throw const CliError(CliExit.auth, 'Not signed in.',
        hint: 'Run `idr login`.', code: 'AUTH_REQUIRED');
  }
}

void writeAttention(IdrSource source) {
  final a = source.state.attention;
  if (a != null) ui.warn(a.message);
}

/// Troubleshooting hints, matched against an error's code and message.
const _hints = <(String, String)>[
  (
    'ENROLLMENT_PENDING',
    'Ask the Target admin to approve it (`idrt <mode> pending` / `approve '
        '<id>`), then rerun `idr enroll`.'
  ),
  ('ENROLLMENT_REJECTED', 'Run `idr enroll` again if that was a mistake.'),
  ('not a member', 'The org owner adds you under Members in the billing portal.'),
  ('NOT_REGISTERED', 'Rerun with --org <slug>.'),
  ('ENTITY_NOT_FOUND', 'The admin runs `idrt <mode> setup --role admin` first.'),
  (
    'only serves verified',
    'You are enrolled, but Presence sent no verified policy for this session. '
        'Operator: Presence needs PRESENCE_SERVICE_TOKEN (same as billing) and '
        '[auth].session_policy_url; its log shows "source_proof received but '
        '... not configured" when it is missing. Then `idr disconnect` and retry.'
  ),
  (
    'policy_denied',
    'Your device or zone was revoked, or your zone allows no services. Ask '
        'the admin.'
  ),
  (
    'service not allowed',
    'Use an allowed service (`idr services`), or ask for a policy change.'
  ),
  (
    'target_not_registered',
    'Check the Target runs `idrt start`, then `idr connect <correct-fqhn>`.'
  ),
  (
    'source_unverified',
    'Rebuild idr_c_api with `--features native`, and sync this machine\'s '
        'clock.'
  ),
  (
    'policy_unavailable',
    'Presence could not reach billing\'s policy check. Ask the admin.'
  ),
  (
    'signaling_failed',
    'Presence is unreachable or refused the session: check IDR_DISCOVERY_URL '
        '(`idr doctor`).'
  ),
  ('LIBRARY_MISSING', 'Run `idr doctor`; build idr_c_api or set IDR_C_API_LIB.'),
  (
    'Failed to load dynamic library',
    'Run `idr doctor`: a native library is missing or cannot be loaded.'
  ),
  ('CRYPTO_UNAVAILABLE', 'Run `idr doctor`; build idr_dp or set IDR_DP_LIB.'),
  ('401', 'Your session expired: run `idr login --force`.'),
  ('AUTH', 'Run `idr login` (or `idr login --force` if it expired).'),
  ('CONNECT_FAILED', 'Run `idr doctor --connect` to see which step fails.'),
];

/// [IdrSourceException] (and unwrapped HTTP errors) → exit code + hint.
CliError? translateSourceError(Object e) {
  if (e is! IdrSourceException) {
    return '$e'.contains('ClientException')
        ? CliError(CliExit.connect, 'Network error: $e',
            hint: 'Run `idr doctor`.', code: 'NETWORK')
        : null;
  }
  final text = '${e.code} ${e.message}';
  final exit = switch (e.code) {
    _ when text.contains('401') || e.code.startsWith('AUTH') => CliExit.auth,
    _ when text.contains('Failed to load dynamic library') => CliExit.config,
    'LIBRARY_MISSING' || 'CRYPTO_UNAVAILABLE' => CliExit.config,
    'SERVICE_REQUIRED' || 'MODEL_REQUIRED' => CliExit.usage,
    _ when text.contains('Cannot derive entity') => CliExit.usage,
    'ACTIVATE_FAILED' ||
    'MODELS_FAILED' ||
    'CHAT_FAILED' ||
    'SERVICE_UNSUPPORTED' =>
      CliExit.failure,
    _ => CliExit.connect,
  };
  final hint = _hints.where((h) => text.contains(h.$1)).firstOrNull?.$2;
  return CliError(exit, e.message, hint: hint, code: e.code);
}
