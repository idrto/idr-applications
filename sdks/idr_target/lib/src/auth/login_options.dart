import 'package:two_key_dart_sdk/two_key_headless.dart';

/// Social / password methods advertised by Auth for desktop sign-in.
enum IdrAuthProvider {
  google,
  microsoft,
  apple;

  static IdrAuthProvider? tryParse(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'google':
        return IdrAuthProvider.google;
      case 'microsoft':
        return IdrAuthProvider.microsoft;
      case 'apple':
        return IdrAuthProvider.apple;
      default:
        return null;
    }
  }

  String get wireName => name;
}

/// Login methods currently configured on the Auth server.
class IdrLoginOptions {
  const IdrLoginOptions({
    required this.providers,
    this.emailPassword = false,
  });

  final List<IdrAuthProvider> providers;
  final bool emailPassword;

  /// Providers the SDK can actually start today (Google SSO only for now).
  static const Set<IdrAuthProvider> sdkSupportedSocial = {
    IdrAuthProvider.google,
  };

  /// Social providers that are both server-configured and SDK-executable.
  List<IdrAuthProvider> get actionableProviders =>
      providers.where(sdkSupportedSocial.contains).toList(growable: false);

  bool get hasActionableSignIn => actionableProviders.isNotEmpty;

  /// Email/password UI only when Auth enables it **and** the SDK supports it.
  /// SDK email sign-in is not implemented yet → always false.
  bool get showEmailPassword => false;

  bool get isEmpty => providers.isEmpty && !emailPassword;

  /// From `GET /api/auth/.well-known/oauth-providers` (billing SDK discovery).
  factory IdrLoginOptions.fromDiscovery(BillingOAuthProvidersDocument doc) {
    final enabled = doc.enabledProviders.map((p) => p.id).toList();
    return IdrLoginOptions.fromJson({
      'providers': enabled,
      'email_password': enabled.contains('email'),
    });
  }

  factory IdrLoginOptions.fromJson(Map<String, dynamic> json) {
    final raw = json['providers'] ?? json['social_providers'];
    final providers = <IdrAuthProvider>[];
    if (raw is List) {
      for (final item in raw) {
        if (item is! String) continue;
        final parsed = IdrAuthProvider.tryParse(item);
        if (parsed != null) providers.add(parsed);
      }
    }
    final email = json['email_password'];
    return IdrLoginOptions(
      providers: List.unmodifiable(providers),
      emailPassword: email == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'providers': providers.map((p) => p.wireName).toList(),
        'email_password': emailPassword,
      };
}
