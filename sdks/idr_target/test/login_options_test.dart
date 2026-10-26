import 'package:idr_target/idr_target.dart';
import 'package:test/test.dart';

void main() {
  group('IdrLoginOptions.fromJson', () {
    test('parses providers and email_password', () {
      final options = IdrLoginOptions.fromJson({
        'providers': ['google', 'microsoft'],
        'email_password': false,
      });
      expect(options.providers, [
        IdrAuthProvider.google,
        IdrAuthProvider.microsoft,
      ]);
      expect(options.emailPassword, isFalse);
      expect(options.actionableProviders, [IdrAuthProvider.google]);
      expect(options.hasActionableSignIn, isTrue);
      expect(options.showEmailPassword, isFalse);
    });

    test('ignores unknown provider strings', () {
      final options = IdrLoginOptions.fromJson({
        'providers': ['google', 'saml', 42, null],
      });
      expect(options.providers, [IdrAuthProvider.google]);
    });

    test('treats missing email_password as false', () {
      final options = IdrLoginOptions.fromJson({
        'providers': ['google'],
      });
      expect(options.emailPassword, isFalse);
    });

    test('accepts social_providers alias from well-known shape', () {
      final options = IdrLoginOptions.fromJson({
        'social_providers': ['apple'],
        'email_password': true,
      });
      expect(options.providers, [IdrAuthProvider.apple]);
      expect(options.emailPassword, isTrue);
      expect(options.actionableProviders, isEmpty);
      expect(options.hasActionableSignIn, isFalse);
    });

    test('empty providers isEmpty when email disabled', () {
      final options = IdrLoginOptions.fromJson({'providers': []});
      expect(options.isEmpty, isTrue);
    });
  });
}
